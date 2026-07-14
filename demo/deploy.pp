# demo/deploy.pp — M6 devops-complete demo: the dispatcher.
#
# ONE pure function from input cells — the greeter C source (`file:`),
# each host's greeting fixture (`file:`), each host's secret key
# (`sealed:`) — to a `{host -> {domain -> desired}}` value (M5 stage C's
# host-qualified shape). Registers NO domains itself: it is run only via
# `--publish-object`, so it never holds write authority — a pure plan
# step, published by hash for every host's agent.pp to pull
# (`--desired-object`, the tests/051 dispatcher/agent split).
#
# argv (after `--`): GREETER-C FIXTURES-ROOT SECRETS-ROOT HOSTS-ROOT
# RUN-ROOT HOST...
# GREETER-C     — path to demo/src/greeter.c                 (fs:ro)
# FIXTURES-ROOT — FIXTURES-ROOT/<host>/greeting.txt          (fs:ro)
# SECRETS-ROOT  — SECRETS-ROOT/<host>/secret.key             (secret:ro
# — deliberately NEVER also fs:-granted on the same
# path: M4's "both grants -> plain fs wins" rule would
# silently un-seal it, tests/044 clause 6)
# HOSTS-ROOT    — HOSTS-ROOT/<host>/ is that host's fs-domain-managed
# root (bin/, etc/) — deploy.pp never writes there
# itself, only computes strings naming it
# RUN-ROOT      — RUN-ROOT/<host>/ is that host's UNMANAGED run
# directory (status file) — deliberately NOT nested
# under HOSTS-ROOT/<host>, so the fs domain's
# tree-observe never sees the live process's own
# heartbeat writes and never tries to delete them

load("stdlib/list.pp")

# Pair two same-length lists in order — a plain local helper
# (tests/024/048's own pattern), not stdlib: the only two lists deploy.pp
# ever zips are hostnames and their rendered configs, built in lockstep
# below.
def zip2(a, b) {
  if nil?(a) { nil } else { cons(cons(car(a), car(b)), zip2(cdr(a), cdr(b))) }
}
# Build the greeter binary — ONE node, shared by every host. `run-dep!`
# compiles+links greeter.c straight to an executable (a single
# translation unit needs no separate link step); `blob` ingests the
# result into the CAS so every host materializes the exact same bytes
# from the exact same ref — one compile, byte-identical binaries.
def greeter-build-node(greeter-c) {
  node {
    perform run-dep!("greeter.d", "cc", "-O2", "-MD", "-MF", "greeter.d", greeter-c, "-o", "greeter")
    blob(slurp("greeter"))
  }
}
# Render one host's config — its own node: free vars (host name,
# greeting bytes, the SEALED secret cell) differ per host, so each
# host's render is a genuinely separate, independently cacheable node
# (parallel/remote placement can force every host's render concurrently
# alongside the build above).
#
# `unseal(slurp(key))` happens INSIDE this node — the node's RESULT is
# a plain string (unseal already converted it, so the sealed-result ban
# never fires) — but the render never returns the raw secret BYTES
# themselves, only `hash-string` of them: a rotation-sensitive
# credential tag. That is what keeps the real key bytes out of every
# node result, every published object, and everything ever materialized
# to disk — they only ever exist as VSealed bytes pinned in-memory
# (Runtime.sealed_pins, cleared every pass) and on the original secret
# fixture file itself. Rotating the secret changes the `sealed:<path>`
# cell's hash, which is what invalidates exactly THIS node's trace
# (LAW 23b) — never another host's, whose sealed cell is a different
# path entirely.
def config-node(host, fixtures-root, secrets-root) {
  node {
    let (greeting = string-trim(slurp(string-append(fixtures-root, "/", host, "/greeting.txt"))), secret = slurp(string-append(secrets-root, "/", host, "/secret.key")), key-tag = hash-string(unseal(secret))) {
      string-append("host=", host, "\n", "greeting=", greeting, "\n", "key-tag=", key-tag, "\n")
    }
  }
}



# One host's desired slice: an fs file pair (the shared binary + this
# host's rendered config) and a proc entry whose spec's CONFIG_HASH env
# binds config-content and process identity together in ONE value —
# they cannot drift apart (the secret-rotation causality chain's last
# link: a config change is ALWAYS also a spec change).
def host-desired(host, bin-ref, config, hosts-root, run-root) {
  let (root = string-append(hosts-root, "/", host), rundir = string-append(run-root, "/", host)) {
    {"fs" -> {"bin/greeter" -> string-append(bin-ref, ":x"), "etc/greeter.conf" -> (config)}, "proc" -> {"greeter" -> {"cmd" -> string-append(root, "/bin/greeter"), "args" -> [string-append(root, "/etc/greeter.conf"), string-append(rundir, "/status")], "cwd" -> rundir, "env" -> {"CONFIG_HASH" -> hash-string((config))}}}}
  }
}






let (greeter-c = nth(0, argv()), fixtures-root = nth(1, argv()), secrets-root = nth(2, argv()), hosts-root = nth(3, argv()), run-root = nth(4, argv()), hostnames = drop(5, argv()), batch = force-deep(cons(greeter-build-node(greeter-c), map(





# Fan out: the shared build + every host's render, batched via the
# batching-aware `map` BUILTIN (never list.pp's — it deliberately
# does not shadow it, D26) so a non-serial --schedule forces them
# all together instead of one at a time.


fn(h) { config-node(h, fixtures-root, secrets-root) }, hostnames))), bin-ref = car(batch), configs = cdr(batch)) {
  foldl(

fn(acc, pair) {
    map-insert(acc, car(pair), host-desired(car(pair), bin-ref, cdr(pair), hosts-root, run-root))
  }, {}, zip2(hostnames, configs))
}
