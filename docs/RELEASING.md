# Releasing pp

This explains how to cut a tagged release, and how to prove the tarball
builds for a stranger on a clean opam switch.

## Version wiring (how it works)

`pp --version` and the REPL banner both read `Version.string` in
`src/version.ml`. This calls `Build_info.V1.version ()` from the
`dune-build-info` library. Dune embeds the version at build time from the
top-level `(version ...)` field in `dune-project`, because `src/dune` ties
the `main` executable to the `pp` package through `(public_name pp)`.

This works the same way in two cases:

- from a git checkout, where the version is the literal string in
  `dune-project`, not something `git describe` derives
- from an unpacked release tarball with no `.git` present, verified by the
  smoke test below

The `fallback` value in `src/version.ml` only fires if someone builds the
executable outside dune's package machinery, for example by removing
`public_name`. It should track the same string as `(version ...)` in
`dune-project`, but it is not the source of truth.

## Cutting vX.Y.Z

1. Update the version. In `dune-project`, bump `(version ...)` to `X.Y.Z`
   and drop the `-dev` suffix. Then run `dune build` once, so dune
   regenerates `pp.opam` in the repo root (it does this because
   `(generate_opam_files true)` is set) with the new version, and check in
   the regenerated file.
2. Write the release notes from git history. This repo has no CHANGELOG
   file: commits follow Conventional Commits, so `git log --oneline
   <last-tag>..HEAD` grouped by type (`feat:`, `fix:`, and so on) is the
   changelog. Put the result in the tag annotation, and in the GitHub
   release body if you make one.
3. Update `docs/STATUS.md` and `docs/PLAN.md` wherever they reference
   version numbers or open items that this release closes.
4. Run the full local gate before tagging:
   ```sh
   eval "$(opam env)"
   dune build
   dune runtest --force
   dune exec ./tools/fuzz.exe -- --grammar core --count 2000
   dune exec ./tools/fuzz.exe -- --grammar full --count 2000
   scripts/build-self.sh
   scripts/build-lua.sh
   ```
5. Commit your changes: `git commit -am "release vX.Y.Z"`.
6. Tag the release: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
7. Push the commit and the tag: `git push && git push --tags`.
8. Build the release tarball from the tag:
   ```sh
   git archive --format=tar.gz -o pp-X.Y.Z.tar.gz vX.Y.Z
   ```
   You do not need to run `dune subst`. pp does not use the `%%VERSION%%`
   watermarking convention, and no source file contains that placeholder,
   because the version comes directly from the `(version ...)` field in
   `dune-project`. `git archive` on the tag is enough: there is no
   separate subst step, and no `.git` directory needed downstream.

## From-tarball smoke test (do this before every release)

Do this to prove that a stranger can build from the tarball alone, with no
`.git` directory and no opam packages beyond `dune`, `cryptokit`, and
`dune-build-info` already installed:

```sh
# From the tagged commit (or working tree for a dry run):
rm -rf /tmp/pp-release-test && mkdir -p /tmp/pp-release-test
git archive vX.Y.Z | tar -x -C /tmp/pp-release-test   # or HEAD for a dry run
cd /tmp/pp-release-test
test -d .git && echo "FAIL: .git present" || echo "ok: no .git"

# On a clean opam switch:
opam switch create ./_opam --empty   # or any fresh switch
eval "$(opam env)"
opam install dune cryptokit dune-build-info -y
dune build
dune runtest --force
./_build/default/src/main.exe --version   # must print the real version, not 0.1.0/None
```

If `--version` prints the correct `vX.Y.Z` with no `.git` directory
present, and `dune runtest` passes, the release builds from the tarball
alone.

### What this repo's CI proves, and what it does not prove

`.github/workflows/ci.yml` runs `dune build`, `dune runtest --force`, the
fuzzer, and `scripts/build-lua.sh` on Linux and macOS, on every push and
pull request to `master`, from a git checkout using `actions/checkout`. It
does not re-run the from-tarball smoke test above. Do that by hand before
tagging, or add a release workflow that does it for you.
