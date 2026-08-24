# Releasing pp

This guide describes the release process for the saved Common Lisp image and
the clean exported-source gate used by CI.

## Version wiring

`bin/pp --version` and the REPL banner read `+version+` in
`lisp/app/main.lisp`. Change that value for a release and rebuild the saved
image with `scripts/build-lisp.sh`.

## Cutting vX.Y.Z

1. Change `+version+` to `X.Y.Z` in `lisp/app/main.lisp`.
2. Review the Conventional Commits range since the previous release and write
   release notes.
3. Update version references and closed items in `docs/SPEC.md`.
4. Run `scripts/build-lisp.sh --output lisp/pp`.
5. Run `scripts/check-architecture.sh`, `scripts/run-tests.sh bin/pp`, and
   `scripts/check-lisp-crash.sh --binary bin/pp`.
6. Run `scripts/check-clean-export.sh`.
7. Commit, tag `vX.Y.Z`, and push the commit and tag.

Do not invent a tag or version: use the value printed by `bin/pp --version`.

## Clean exported-source gate

The executable gate is one command:

```sh
./scripts/check-clean-export.sh
```

It archives `HEAD` with `git archive`, extracts into a fresh directory with no
`.git`, builds a new saved image, and runs the complete shell suite against
that image. It also checks that the exported executable reports a non-empty
version. The gate catches untracked source, generated-image, and local-path
dependencies that a checkout build can hide.

## CI and unreleased metadata

Pushes and pull requests run on Linux with SBCL installed. CI builds the saved
image, runs the architecture checks and shell suite, and then runs the clean
exported-source gate. The test runner uses an isolated `HOME` for every case;
no daemon or pre-existing store is part of release validation.

Keep generated `lisp/pp`, `lisp/pp.sbcl-image`, and build-id files out of
source commits. The release artifact is produced by the build script from
tracked Lisp sources.
