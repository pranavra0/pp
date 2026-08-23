# pp

A build is a DAG: this artifact depends on those inputs. Most tools encode
it as a sequence anyway. A Dockerfile is a linked list of snapshots, so
touching one file early invalidates every layer below it. A Terraform plan
goes stale the moment the world drifts under it, and nothing rechecks. pp
takes the dependency graph as the semantics of the language itself, so
incremental reuse, parallelism, and distribution fall out of evaluation
instead of being bolted on by a wrapper tool.

pp is a content-addressed, capability-scoped language implemented in Common
Lisp. Every value has a content hash, and two computations with the same
code and inputs are the same computation wherever they run. Caching,
deduplication, and early cutoff are consequences of that identity, not
separate mechanisms.

## Getting started

```sh
scripts/build-lisp.sh --output lisp/pp
bin/pp file.pp
```

The build requires SBCL and creates a saved executable image. Ordinary
invocations run that image; pp never asks the host reader to parse source.

Run `scripts/run-tests.sh bin/pp` for the test suite, or `bin/pp --help`
for all flags.

## A tour

One program, a service release: sources compile into cached artifacts, a
sealed token becomes an auth header, config names the environment, and the
program's final value is the desired state of the deploy directory.

```pp
def compile(src) {
  node {
    print(f"compile {src}")
    blob(string-append(slurp(src), "; built\n"))
  }
}

let api = compile("src/api.src")
let web = compile("src/web.src")

let api-again = compile("src/api.src")   # same key, so this shares the
                                         # cache entry: the body runs once

# Sealed until forced. The bytes never reach the terminal or the store,
# but their hash rides in the trace, so rotating the token invalidates
# exactly the nodes that used it.
let auth = node {
  print("mint auth header")
  string-append("Bearer ",
                ->string(string-length(unseal(slurp("vault/token")))))
}

with-config({:env -> "prod"}) {
  {:tree -> {
    "bin/api"          -> {:kind -> :file, :mode -> 420, :blob -> api},
    "bin/web"          -> {:kind -> :file, :mode -> 420, :blob -> web},
    "conf/auth.header" -> {:kind -> :file, :mode -> 420, :blob -> auth},
    "conf/env"         -> {:kind -> :file, :mode -> 420,
                           :blob -> blob($config(:env))},
  }}
}
```

Run it through the reconciler, which grants exactly three authorities:
read the sources, read the secret, write the deploy directory.

```sh
$ pp --grant fs:src:ro --grant secret:vault --grant fs:release:rw \
+     --reconcile release service.pp
compile src/api.src
compile src/web.src
mint auth header
create=4 update=0 delete=0

$ pp --grant fs:src:ro --grant secret:vault --grant fs:release:rw \
+     --reconcile release service.pp     # world unchanged: everything hits
create=0 update=0 delete=0

$ cp vault/token.new vault/token       # rotate the secret
$ pp --grant fs:src:ro --grant secret:vault --grant fs:release:rw \
+     --reconcile release service.pp
mint auth header                       # one observer reruns; builds stay cold
update=1 delete=0
```

Touch one source and only its artifact recomputes. Delete the whole
`release/` directory and it comes back from the store without rerunning a
tool. Build and deploy are one graph over one store, and every reuse
decision is checked against what the world actually looks like now.


## How it works

A program has two tiers. Nodes are pure, persistent computations: the key
hashes the code and argument values, the result lands in a store beside a
trace of everything the node read from the world, and a later run reuses
it only when those reads still hash the same.

Effects need authority. Each one requires a capability token minted at the
root, narrowable by composition, and checked again when a cached result is
served to a caller.

Scheduling is policy. One evaluator serves a serial run,
`--schedule parallel:4` worker forks, and remote placement across a
cluster of signed-token nodes.

Deployment rides the same machinery. `pp --reconcile DIR prog.pp` diffs
the program's desired tree against observed reality, applies, and journals
each pass; when reality already matches, the pass writes nothing. Delete
the output directory and rerun, and the artifacts return from the store
without rerunning any tools. `--watch --supervise` holds long-running
services to their specs and restarts them on change.

Source comes in two spellings: `.pp`, braces and infix notation, and
`.ppl`, the same AST written as s-expressions so macros can manipulate it.
`pp fmt` converts between them.

Foreign execution is provider-owned. The bundled Linux executor closes the
filesystem, environment, loader, and network but reports its remaining ambient
inputs, so it is scripting-only. A trusted provider may classify an immutable
request as cacheable when it can guarantee that the request accounts for every
semantic input. Toolchain and execution-policy schemas remain ordinary pp
libraries; the optional `:policy` field is canonical pp data that only the
provider interprets.

The package is authored by Pranav Rao and distributed under the MIT License;
see [LICENSE](LICENSE).
