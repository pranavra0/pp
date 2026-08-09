# Releasing pp

This guide describes the release process and the clean exported-source gate used
by CI.

## Version wiring

`pp --version` and the REPL banner read `Version.string`, which is populated by
`dune-build-info` from the top-level `(version ...)` field in `dune-project`.
That field is the version source of truth in both a checkout and a `.git`-free
archive. The fallback in `src/kernel/version.ml` is only for builds outside
Dune's package machinery and must remain consistent with `dune-project`.

## Cutting vX.Y.Z

1. Change `(version ...)` in `dune-project` from the development value to
   `X.Y.Z`, run `dune build` to regenerate `pp.opam`, and commit both files.
2. Write release notes from the Conventional Commits range since the last tag.
3. Update version references and closed items in `docs/SPEC.md`.
4. Run the local gates: `dune build`, `dune runtest --force`, and the core and
   full fuzzers with count 2000.
5. Commit, tag `vX.Y.Z`, and push the commit and tag.

Do not invent a tag or version: use the value in `dune-project`.

## Clean exported-source gate

The executable gate is one command:

```sh
./scripts/check-clean-export.sh
```

It archives `HEAD` with `git archive`, extracts into a fresh temporary
 directory with no `.git`, then uses the CI opam environment to run `dune build`
and the canonical `dune runtest --force`. It runs the exported
`_build/default/src/app/main.exe --version` and compares its output exactly with
the version parsed from the exported `dune-project`. CI runs this gate on every
push and pull request (in addition to the normal Linux and macOS gates).

The archive gate deliberately reuses `dune runtest --force`; closed-runner
confinement remains covered by `tests/102` in that suite rather than being
copied into the release script.

## CI and unreleased metadata

Pushes and pull requests to `master` run the canonical build, architecture and
unit gates, `dune runtest --force`, core fuzzing at count 2000, full grammar
fuzzing at count 2000, and the clean exported-source gate. A weekly scheduled
Ubuntu workflow runs both grammars for seeds 0, 1, 2, and 3 at count 2000.

The current `0.2.0-dev` value in `dune-project` is unreleased development
metadata, not a release tag or promised release version. A release must replace
it with the intended `X.Y.Z` value before tagging.
