# Threat model: island fetching

This document sets out what pp trusts when `pp --fetch-islands` or
`pp --update` fetches a `git:` or `github:` island from a remote host.
This is package-procurement trust, the same class of trust a build tool
places in a fetcher such as Bazel's or Nix's.

This threat model is deliberately narrower than
`docs/THREAT-MODEL-cluster.md`, which covers a different surface: trust
between machines in the same pp cluster, not trust in a remote source
host.

## Invariants

Identity is the pinned content, never the ref. The pin in an island form is
the canonical tree hash of the source tree. Once pp has pinned a
dependency, it never trusts the remote host again: a resolve serves only a
cached tree that re-hashes to the pin, checked on every resolve, and a
fetch that produces different content than the pin is a hard error, never
a silent accept. A malicious or compromised host can therefore affect
availability — it can refuse to serve, or serve garbage that fails the
hash check — but it cannot affect the integrity of a dependency that is
already pinned.

The moment of trust-on-first-use is `pp --update`, or the first
`--fetch-islands` run for a new pin. Whatever the ref resolves to at that
moment is what pp hashes and freezes into the source. This moment is
explicit, started by the user, and recorded in the journal (`island fetch
<uri> <pin>` in `~/.pp/store/journal/log`). Reviewing the update diff is
how the user reviews the dependency bump.

## What fetching executes

Fetching runs these steps and applies these limits:

- pp runs `git clone --quiet --template= <url> <tmpdir>`, then, if a ref
  was given, `git -C <tmpdir> checkout --quiet <ref>`
- the empty `--template=` value stops git installing hook files into the
  fresh clone. Git does not execute hooks from the remote repository
  during clone or checkout in any case, since hooks are local files and
  this clone starts with none, so pp never runs any file from the fetched
  tree while fetching
- the clone happens in a temporary directory, `.git` is stripped before
  hashing, and only regular files and directories are copied into the
  cache. Symlinks and other special files are a hard error, so a
  path-escaping link can never confuse the hash
- the fetched tree's code runs only when the program evaluates the
  island, under pp's normal capability rules: there is no ambient
  authority, and any effect needs a `--grant`

Residual risks accepted for v1:

- git itself is trusted, since its parsers see hostile bytes during
  clone. Mitigation: none beyond using the system git, the same posture
  as any fetcher that shells out to git
- DNS and TLS, for `github:` and `https://` URLs, rely on the platform's
  trust store. A network attacker sitting between pp and the host at
  first-pin time can supply malicious content that then gets honestly
  pinned. Mitigation: the update diff shows the pin change, and checking
  where a pin came from is the user's responsibility at update time
- availability and rollback: a host can serve an old commit for a ref at
  update time, since refs are mutable by design. The pin freezes whatever
  the host served at that moment. pp guarantees integrity of the pinned
  content, never freshness

## What fetching is not

Fetching is not:

- a user capability. Fetch authority belongs to the loader (LAW 24),
  granted by the `--fetch-islands` command-line flag, not by
  `--grant net`. User code cannot trigger a fetch — only resolving a form
  the user wrote, under a flag the user passed, can
- ambient. With the flag off, which is the default, resolution never
  touches the network. A missing pin or cache entry is a hard error that
  names the fix. Hermetic builds stay hermetic because pp refuses to
  fetch, not by luck
- evaluation. No fetched code runs as part of fetching

## Cache integrity

pp verifies `~/.pp/islands/src/<pin>/` against its pin on every resolve.
This re-hashes the whole tree each time, a cost pp accepts deliberately in
exchange for catching tampering immediately. Local tampering is a hard
error, never a silent re-fetch, so an attacker with write access to the
cache can break builds but cannot substitute code without detection. An
attacker with write access to `$HOME` already controls the user's account,
so this check's real value is against accidental corruption and casual
tampering, not against a determined attacker with that level of access.
