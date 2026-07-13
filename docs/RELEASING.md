# Releasing pp

How to cut a tagged release, and how to prove the tarball actually builds
for a stranger on a clean opam switch.

## Version wiring (how it works)

`pp --version` and the REPL banner both read `Version.string`
(`src/version.ml`), which calls `Build_info.V1.version ()` from the
`dune-build-info` library. Dune embeds the version at build time from
`dune-project`'s top-level `(version ...)` field, because `src/dune` ties
the `main` executable to the `pp` package via `(public_name pp)`. This
works identically:

- from a git checkout (no `git describe` involved — the version is the
  literal string in `dune-project`, not VCS-derived), and
- from an unpacked release tarball with **no `.git` present** (verified
  below).

`src/version.ml`'s `fallback` value only fires if the executable is ever
built outside dune's package machinery (e.g. `public_name` removed); it
should track the same string as `dune-project`'s `(version ...)` but is not
itself the source of truth.

## Cutting vX.Y.Z

1. Update the version:
   - `dune-project`: bump `(version ...)` to `X.Y.Z` (drop `-dev`).
   - Run `dune build` once so the generated `pp.opam` (dune writes it into
     the repo root because `(generate_opam_files true)` is set) picks up
     the new version; check in the regenerated `pp.opam`.
2. Update `CHANGELOG.md`: rename the `[Unreleased]` section to
   `[X.Y.Z] — YYYY-MM-DD`, start a fresh empty `[Unreleased]` above it.
3. Update `docs/ROADMAP.md` / `docs/STATUS.md` where
   they reference version numbers or unchecked exit criteria that this
   release closes.
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
5. Commit: `git commit -am "release vX.Y.Z"`.
6. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
7. Push: `git push && git push --tags`.
8. Build the release tarball from the tag:
   ```sh
   git archive --format=tar.gz -o pp-X.Y.Z.tar.gz vX.Y.Z
   ```
   `dune subst` is unnecessary here: pp does not use the `%%VERSION%%`
   watermarking convention (source files never contain that placeholder),
   because the version comes from `dune-project`'s `(version ...)` field
   directly. `git archive` on the tag is sufficient — no separate subst
   step, no `.git` needed downstream.

## From-tarball smoke test (do this before every release)

Prove a stranger can build from the tarball alone, with no `.git` and no
pre-existing opam packages beyond `dune`/`cryptokit`/`dune-build-info`:

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

If `--version` prints the correct `vX.Y.Z` with no `.git` directory present
and `dune runtest` passes, the release is buildable from the tarball alone
(ROADMAP maturity §4).

### What this repo's CI proves vs. what it doesn't

`.github/workflows/ci.yml` runs `dune build` / `dune runtest --force` / the
fuzzer / `scripts/build-lua.sh` on Linux and macOS on every push and PR to
`master`, from a **git checkout** (via `actions/checkout`). It does not, by
itself, re-run the from-tarball smoke test above — do that by hand (or add
a release workflow) before tagging.
