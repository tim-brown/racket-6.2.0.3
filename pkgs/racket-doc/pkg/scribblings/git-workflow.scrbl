#lang scribble/manual
@(require "common.rkt"
          scribble/bnf)

@title[#:tag "git-workflow"]{Developing Packages with Git}

When a Git repository is specified as a package source, then a copy of
the repository content is installed as the package
implementation. That installation mode is designed for package
consumers, who normally use a package without modifying it. The
installed copy of the package is unsuitable for development by the
package author, however, since the installation is not a full clone of
the Git repository. The Racket package manager provides different
installation modes to support package authors who work with Git
repository clones.


@section{Linking a Git Checkout as a Directory}

Since a Git repository checkout is a directory, it can be linked as a
package as described in @secref["working-new-pkgs"]. In that case, any
modifications made locally take effect immediately for the package
installation, including any updates from a @exec{git pull}. The
developer must explicitly pull any remote updates to the repository,
however, including when the updates are needed to satisfy the
requirements of dependent packages.

In the following section, we describe an alternative that makes
@command-ref{update} aware of the checkout directory's status as a
repository clone. Furthermore, a directory-linked package can be
promoted to a clone-linked package with @command-ref{update}.


@section[#:tag "clone-link"]{Linking a Git Checkout as a Clone}

When a package is installed with

@commandline{@command{install} --clone @nonterm{dir} @nonterm{git-pkg-source}}

then instead of installing the package as a mere copy of the
repository source, the package is installed by creating a Git clone of
@nonterm{git-pkg-source} as @nonterm{dir}. The clone's checkout is
linked in the same way as a directory, but unlike a plain directory
link, the Racket package manager keeps track of the repository
connection.

When the repository at @nonterm{git-pkg-source} is changed so that the
source has a new checksum, then @command-ref{update} for the package pulls
commits from the repository to the local clone. In other words,
@command-ref{update} works as an alternative to @exec{git pull --ff-only}
to pull updates for the package. Furthermore, @command-ref{update} can
pull updates to local package repositories when checking dependencies.
For example, @exec{@command{update} --all} pulls updates for all
linked package repositories.

Suppose that a developer works with a large number of packages and
develops only a few of them. The intended workflow is as follows:

@itemlist[

 @item{Install all the relevant packages with @command-ref{install}.}

 @item{For each package to be developed out of a particular Git
  repository named by @nonterm{pkg-name}, update the installation with

  @commandline{@command{update} --clone @nonterm{dir} @nonterm{pkg-name}}

  which discards the original installation of the package and replaces
  it with a local clone as @nonterm{dir}.

  As a convenience, when @nonterm{git-pkg-source} and the last element
  of @nonterm{dir} are the same, then @nonterm{pkg-name} can be
  omitted. Put another way, the argument to @DFlag{clone} can be a
  path to @nonterm{pkg-name}:

  @commandline{@command{update} --clone @nonterm{path-to}/@nonterm{pkg-name}}}

 @item{If a package's current installation is not drawn from a Git
  repository (e.g., it's drawn from a catalog of built packages for a
  distribution or snapshot), but @nonterm{catalog} maps the package
  name to the right Git repository, then combine @DFlag{clone} with
  @DFlag{lookup} and @DFlag{catalog}:

  @commandline{@command{update} --lookup --catalog @nonterm{catalog} --clone @nonterm{path-to}/@nonterm{pkg-name}}

  A suitable @nonterm{catalog} might be @url{http://pkgs.racket-lang.org}.}

 @item{Manage changes to each of the developed packages in the usual
  way with @exec{git} tools, but @command-ref{update} is also available
  for updates, including mass updates.}

]

A @tech{package source} provided with @DFlag{clone} can include a
branch and/or path into the repository. The branch specification
affects the branch used for the initial checkout, while a non-empty
path causes a subdirectory of the checkout to be linked for the
package.

The @exec{git} and @exec{raco pkg} tools interact in specific
ways:

@itemlist[

 @item{With the link-establishing

       @commandline{@command{install} --clone @nonterm{dir} @nonterm{git-pkg-source}}

       or the same for @command-ref{update}, if a local repository exists
       already as @nonterm{dir}, then it is left in place and any new
       commits are fetched from @nonterm{git-pkg-source}. The package
       manager does not attempt to check whether a pre-existing
       @nonterm{dir} is consistent with @nonterm{git-pkg-source}; it
       simply starts fetching new commits to @nonterm{dir}, and a
       later @exec{git pull --ff-only} will detect any mismatch.

       Multiple @nonterm{git-pkg-source}s can be provided to
       @command-ref{install}, which makes sense when multiple packages
       are sourced from the same repository and can therefore share
       @nonterm{dir}.  Whether through a single @exec{raco pkg} use or
       multiple uses with the same @exec{--clone @nonterm{dir}},
       packages from the same repository should be linked from the
       same local clone (assuming that they are in the same repository
       because they should be modified together). The package system
       does not inherently require clone sharing among the packages,
       but since non-sharing or inconsistent installation modes could
       be confusing, @command-ref{install} and @command-ref{update}
       report non-sharing or inconsistent installations. In typical cases,
       the default @exec{@DFlag{multi-clone} ask} mode can automatically
       fix inconsistencies.}

 @item{When pulling changes to repositories that have local copies,
       @command-ref{update} pulls changes with the equivalent of @exec{git
       pull --ff-only}.}

 @item{When @command-ref{update} is given a specific commit as the target
       of the update, it uses the equivalent of @exec{git merge --ff-only
       @nonterm{checksum}}. This approach is intended to preserve any
       changes to the package made locally, but it implies that the
       package cannot be ``downgraded'' to a older commit simply by
       specifying the commit for @command-ref{update}; any newer commits
       that are already in the local repository will be preserved.}

 @item{The installed-package database records the most recent commit
       pulled from the source repository after each installation or
       update. The current commit in the repository checkout is
       consulted only for the purposes of merging onto pulled
       commits. Thus, after pushing repository changes with @exec{git
       push}, a @command-ref{update} makes sense to synchronize the
       package-installation database with the remote repository state
       (which is then the same as the local repository state).}

 @item{When checking a @command-ref{install} or @command-ref{update}
       request for dependencies and collisions, the clone directory's
       content is used directly only if the current checkout includes
       the target commit.

       Otherwise, commits are first fetched with @exec{git fetch}, and
       an additional local clone is created in a temporary directory.
       If the overall installation or update is deemed to be
       successful with respect to remote commits (not necessarily the
       current commit in each local repository) in that copy, then an
       update to the linked repository checkout proceeds. Finally,
       after all checkouts succeed, other package installations and
       updates are completed and recorded. If a checkout fails (e.g.,
       due to a conflict or uncommitted change), then the repository
       checkout is left in a failed state, but all package actions are
       otherwise canceled.}

 @item{Removing a package with @command-ref{remove} leaves the
       repository checkout intact while removing the package link.}

]
