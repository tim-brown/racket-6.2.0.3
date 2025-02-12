#lang racket/base
(module+ test
  (require rackunit
           racket/tcp
           racket/port
           (for-syntax racket/base)
           racket/list
           (prefix-in hc: net/http-client)
           (prefix-in u: net/url))

  (define-syntax regexp-replace**
    (syntax-rules ()
      [(_ () s)
       s]
      [(_ ([from to] . more) s)
       (regexp-replace* from (regexp-replace** more s) to)]))

  (define (read-request in)
    ;; Simulate HTTP request reading enough to get the right number
    ;; of bytes.
    (define ob (open-output-bytes))
    (regexp-match #rx"\r\n\r\n" in 0 #f ob)
    (write-bytes #"\r\n\r\n" ob)
    (define bstr (get-output-bytes ob))
    (cond
     [(regexp-match #rx"Content-Length: ([0-9]+)" bstr)
      => (lambda (m)
           (bytes-append bstr (read-bytes
                               (string->number (bytes->string/utf-8 (cadr m)))
                               in)))]
     [(regexp-match? #rx"^PUT" bstr)
      (bytes-append bstr (read-request in))]
     [else bstr]))

  (define-syntax (tests stx)
    (syntax-case stx ()
      [(_ t ...)
       (with-syntax
           ([(t.test ...)
             (for/list ([t (in-list (syntax->list #'(t ...)))])
               (quasisyntax/loc t
                 (test . #,t)))])
         (syntax/loc stx
           (begin t.test ...)))]))

  (define-syntax (test-e stx)
    (syntax-case stx ()
      [(_ the-port repeats init-e proc-e raw ereq estatus eheaders econtent)
       (quasisyntax/loc stx
         (let ([v init-e])
           (for ([i repeats])
             (define l (tcp-listen 0 40 #t "127.0.0.1"))
             (define-values (_1 the-port _2 _3)
               (tcp-addresses l #t))
             (define req #f)
             (define lt
               (thread
                (λ ()
                  (define-values (in out) (tcp-accept l))
                  (tcp-close l)
                  (set! req (read-request in))
                  (display raw out)
                  (flush-output out)
                  (close-output-port out)
                  (close-input-port in))))
             (define-values (status headers content-port)
               (proc-e v))
             #,(syntax/loc stx
                 (check-equal? status estatus))
             #,(syntax/loc stx
                 (check-equal? headers eheaders))
             #,(syntax/loc stx
                 (check-equal? (port->bytes content-port) econtent))
             (thread-wait lt)
             #,(syntax/loc stx
                 (check-equal?
                  (regexp-replace** ([(number->string the-port) "REDACTED"]
                                     [(regexp-quote (version)) "REDACTED"])
                                    req)
                  ereq)))))]))

  (define-syntax (test stx)
    (syntax-case stx ()
      [(_ method body raw ereq estatus eheaders econtent)
       (quasisyntax/loc stx
         (begin
           #,(syntax/loc stx
               (test-e the-port
                       1 #f
                       (lambda (ignored)
                         (hc:http-sendrecv "localhost" "/"
                                           #:ssl? #f
                                           #:port the-port
                                           #:method method
                                           #:headers empty
                                           #:data body))
                       raw ereq estatus eheaders econtent))
           #,(syntax/loc stx
               (test-e the-port
                       1 #f
                       (lambda (ignored)
                         (let ([c (hc:http-conn-open "localhost"
                                                     #:port the-port
                                                     #:ssl? #f)])
                           (check-equal? #t (hc:http-conn-live? c))
                           (hc:http-conn-send! c
                                               "/"
                                               #:method method
                                               #:headers empty
                                               #:close? #t
                                               #:data body)
                           (begin0
                            (hc:http-conn-recv! c
                                                #:method method
                                                #:close? #t)
                            (check-equal? #f (hc:http-conn-live? c)))))
                       raw ereq estatus eheaders econtent))
           #,(syntax/loc stx
               (test-e the-port
                       3 (hc:http-conn)
                       (lambda (c)
                         (check-equal? #f (hc:http-conn-live? c))
                         (hc:http-conn-open! c "localhost"
                                             #:port the-port
                                             #:ssl? #f)
                         (check-equal? #t (hc:http-conn-live? c))
                         (hc:http-conn-send! c
                                             "/"
                                             #:method method
                                             #:headers empty
                                             #:close? #t
                                             #:data body)
                         (begin0
                          (hc:http-conn-recv! c
                                              #:method method
                                              #:close? #t)
                          (check-equal? #f (hc:http-conn-live? c))))
                       raw ereq estatus eheaders econtent))
           #,(syntax/loc stx
               (test-e the-port
                       1 #f
                       (lambda (ignored)
                         (u:http-sendrecv/url
                          (u:make-url "http" #f "localhost" the-port #t
                                      (list (u:path/param "" empty)) empty #f)
                          #:method method
                          #:headers empty
                          #:data body))
                       raw ereq estatus eheaders econtent))))]))

  (tests
   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n24\r\nThis is the data in the first chunk \r\n1A\r\nand this is the second one\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\nContent-Type: text/plain\n\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 62\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain" #"Content-Length: 62")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\ncontent-length: 62\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain" #"content-length: 62")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n20\r\nThis is the data in the first ch\r\n21\r\nand this is the second oneXXXXXXX\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chand this is the second oneXXXXXXX"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n24\r\nThis is the data in the first chunk \r\n1A\r\nand this is the second one\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n20\r\nThis is the data in the first ch\r\n21\r\nand this is the second oneXXXXXXX\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chand this is the second oneXXXXXXX"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nThis is the data in the first chunk and this is the second one\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one\r\n"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n24\r\nThis is the data in the first chunk \r\n1A\r\nand this is the second one\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nThis is the data in the first chunk and this is the second one"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.0 200 OK"
    '(#"Content-Type: text/plain")
    #"This is the data in the first chunk and this is the second one"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n20\r\nThis is the data in the first ch\r\n21\r\nand this is the second oneXXXXXXX\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked")
    #"This is the data in the first chand this is the second oneXXXXXXX"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nAnother-Header: ta-daa\r\n\r\n20\r\nThis is the data in the first ch\r\n21\r\nand this is the second oneXXXXXXX\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked" #"Another-Header: ta-daa")
    #"This is the data in the first chand this is the second oneXXXXXXX"]

   ["GET" #f "HTTP/1.1 301 Moved Permanently\r\nLocation: http://localhost:9002/whatever\r\n\r\nstuff"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 301 Moved Permanently"
    '(#"Location: http://localhost:9002/whatever")
    #"stuff"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nAnother-Header: ta-daa\r\n\r\n20\r\nThis is the data in the first ch\r\n21\r\nand this is the second oneXXXXXXX\r\n0\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked" #"Another-Header: ta-daa")
    #"This is the data in the first chand this is the second oneXXXXXXX"]

   ["GET" #f "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nAnother-Header: ta-daa\r\n\r\nbb \r\n<HTML>\n\t\t\t\t\t  <HEAD>\n\t\t\t\t\t  <TITLE>ABCNANOTECH Co., LTD.</TITLE>\n\t\t\t\t\t  </HEAD>\n\t\t\t\t\t  <FRAMESET ROWS=\"100%,*\" border=0>\n\t\t\t\t\t  <FRAME src=http://nanotech.co.kr></FRAMESET>\n\t\t\t\t\t  </HTML>\r\n0\r\n\r\n"
    #"GET / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '(#"Content-Type: text/plain" #"Transfer-Encoding: chunked" #"Another-Header: ta-daa")
    #"<HTML>\n\t\t\t\t\t  <HEAD>\n\t\t\t\t\t  <TITLE>ABCNANOTECH Co., LTD.</TITLE>\n\t\t\t\t\t  </HEAD>\n\t\t\t\t\t  <FRAMESET ROWS=\"100%,*\" border=0>\n\t\t\t\t\t  <FRAME src=http://nanotech.co.kr></FRAMESET>\n\t\t\t\t\t  </HTML>"]

   ["PUT" #f "HTTP/1.1 200 OK\r\n\r\n"
    #"PUT / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '()
    #""]

   ["PUT" #"frob" "HTTP/1.1 200 OK\r\n\r\n"
    #"PUT / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 4\r\nConnection: close\r\n\r\nfrob"
    #"HTTP/1.1 200 OK"
    '()
    #""]

   ["PUT" "frob" "HTTP/1.1 200 OK\r\n\r\n"
    #"PUT / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 4\r\nConnection: close\r\n\r\nfrob"
    #"HTTP/1.1 200 OK"
    '()
    #""]

   ["PUT"
    (λ (w) (w "fr") (w "ob"))
    "HTTP/1.1 200 OK\r\n\r\n"
    #"PUT / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nfr\r\n2\r\nob\r\n0\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '()
    #""]

   ["PUT"
    (λ (w) (void))
    "HTTP/1.1 200 OK\r\n\r\n"
    #"PUT / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '()
    #""]

   ["HEAD" #f "HTTP/1.1 200 OK\r\n\r\n"
    #"HEAD / HTTP/1.1\r\nHost: localhost:REDACTED\r\nUser-Agent: Racket/REDACTED (net/http-client)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    #"HTTP/1.1 200 OK"
    '()
    #""]))
