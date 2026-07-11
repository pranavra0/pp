# Threat model: island fetching (D2, network half)

Scope: what running `pp --fetch-islands` / `pp --update` trusts when it
procures a `git:`/`github:` island. This is **package-procurement trust**
(the Bazel/Nix-fetcher class), deliberately narrower than the Phase-4
cluster-forcing threat model (SPEC LAW 34/35), which remains unwritten and
gating for that feature.

## The invariant that carries everything

**Identity is the pinned content, never the ref.** The pin in the island
form is the canonical tree hash of the source tree. After first pin, pp
never trusts the remote again: a resolve serves only a cached tree that
re-hashes to the pin (verified on every resolve), and a fetch that produces
different content than the pin is a hard error, never a silent accept. A
malicious or compromised host can therefore affect *availability* (refuse to
serve, serve garbage that fails the hash) but not *integrity* of an
already-pinned dependency.

The trust-on-first-use moment is `pp --update` (or the first
`--fetch-islands` for a new pin): whatever the ref resolves to *then* is
what gets hashed and frozen into the source. That moment is explicit,
user-initiated, and journaled (`island fetch <uri> <pin>` in
`~/.pp/store/journal/log`); review of the update diff is review of the
dependency bump.

## What fetching executes

- `git clone --quiet --template= <url> <tmpdir>`, then (if a ref was given)
  `git -C <tmpdir> checkout --quiet <ref>`.
- `--template=` (empty template) ensures no hook files are installed into
  the fresh clone; git does not execute hooks from the *remote* repository
  during clone/checkout — hooks are local files, and this clone starts with
  none. pp never runs any file from the fetched tree during fetch.
- The clone happens in a temp directory; `.git` is stripped before hashing;
  only regular files and directories are copied into the cache (symlinks and
  special files are a hard error, so the hash cannot be confused by
  path-escaping links).
- The fetched tree's code runs only when the *program* evaluates the island
  — under pp's normal capability regime (no ambient authority; effects need
  `--grant`).

Residual risks accepted for v1:

- **git itself** is trusted (its parsers see hostile bytes during clone).
  Mitigation: none beyond using the system git; same posture as every
  fetcher that shells out to git.
- **DNS/TLS** for `github:`/`https://` URLs is the platform's trust store;
  a network MITM at first-pin time can supply malicious content that then
  gets honestly pinned. Mitigation: the update diff shows the pin change;
  pin provenance is the user's review responsibility at update time.
- **Availability/rollback**: a host can serve an *old* commit for a ref at
  update time (refs are mutable by design). The pin freezes whatever was
  served; there is no freshness guarantee, only integrity.

## What fetching is not

- Not a user capability: fetch authority is the loader's (LAW 24), granted
  by the CLI flag, not by `--grant net`. User code cannot trigger a fetch;
  only resolution of a form the user wrote, under a flag the user passed.
- Not ambient: with the flag off (default), resolution never touches the
  network — a missing pin or cache entry is a hard error naming the fix.
  Hermetic builds stay hermetic by refusal, not by luck.
- Not evaluation: no fetched code runs as part of fetch.

## Cache integrity

`~/.pp/islands/src/<pin>/` is verified against `pin` on **every** resolve
(O(tree) re-hash; see PLAN §9 for the accepted cost). Local tampering is
detected and is a hard error — never a silent re-fetch, so an attacker with
write access to the cache can break builds but cannot substitute code
undetected. (An attacker with write access to `$HOME` owns the user anyway;
the check's value is against accidental corruption and casual tampering.)
