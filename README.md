# TP (Term Packages)

Build system for the packages and bootstrap archives used by TermOne, TermTwo, TermThree and TermFour.

TP does not reimplement package recipes. It checks out `termux-packages`, switches it to the Term
layout (`/data/data/<applicationId>/files/rootdir/usr`), builds everything from source inside the
official builder image and turns the result into one bootstrap archive per app and architecture.

## Archives

For every release the following files are published:

    bootstrap-<applicationId>-<arch>.zip
    bootstrap-<applicationId>-<arch>.zip.sha256

with `<applicationId>` in `app.term.one`, `app.term.two`, `app.term.three`, `app.term.four` and
`<arch>` in `aarch64`, `x86_64`. An archive only works for the app it was built for, because the
prefix path is compiled into the binaries.

## Releasing

Run the **Build bootstrap archives** workflow with a release tag, or push a tag named
`bootstrap-*`. Pin `termux_packages_ref` to a known good commit for reproducible builds.

## Local build

Needs Linux with Docker, `git`, `zip` and `unzip`:

    bash scripts/build-bootstrap.sh app.term.one aarch64

Builds on a phone are not supported, because `termux-packages` is cross-compiled.

## apt repositories

Every run of the workflow also publishes one signed apt repository per app to GitHub Pages:

    https://term-org.github.io/TP/<applicationId>/

The bootstrap archives already contain the matching `sources.list` and the public signing key
(`keys/term-packages.gpg`), so `tn update` and `tn install` work right after the first start.

One-time setup:

1. Run `bash scripts/make-signing-key.sh`, commit `keys/term-packages.gpg`, store `private-key.asc`
   in the repository secret `TERM_GPG_PRIVATE_KEY` and delete the file.
2. In **Settings > Pages** set the source to **GitHub Actions**.

Edit `packages.toml` to change which extra packages are built. Each deployment replaces the whole
site, and GitHub Pages allows at most 1 GB, so the build stops when the site exceeds 900 MB.
