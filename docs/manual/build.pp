# docs/manual/build.pp — pp builds its own reference manual, and RUNS every
# example in it.
#
# Two dogfood claims, both falsifiable:
# 1. The manual is a pp build graph. Typst is invoked as hermetic tool NODES
# (the run-dep! + blob idiom that builds Lua and the M6 greeter); typst's
# --deps depfile refines each node's trace to the exact source files it
# read, so an unchanged manual runs the typesetter ZERO times.
# 2. Every code example is executed BY pp during the build, and its real
# output is embedded (the Zig-reference model). A broken example fails
# the build before a reader ever sees it — the docs cannot drift from the
# language, because the build is the language running them.
#
# Run from the repo root (bin/pp on PATH via direnv), or: scripts/build-manual.sh
# pp docs/manual/build.pp \
# --grant "fs:$PWD/docs/manual:rw" --grant process \
# -- "$PWD/docs/manual" "$PWD/bin/pp"
#
# argv (after --): MANUAL-DIR (absolute)  PP-BIN (absolute path to bin/pp)

load("stdlib/list.pp")

# ---- the examples the manual runs -------------------------------------------
# Each entry is (NAME KIND GRANTS):
# KIND "pp" — examples/NAME.pp, run through pp; GRANTS is the extra flag
# string, shown verbatim in the rendered command (usually "").
# KIND "sh" — examples/NAME.sh, a shell transcript run with $PP bound to the
# pp binary; the script sets its own temp HOME so its store is
# hermetic and its output reproducible. Use for substrate demos
# (caching, rebuilds, deploys) that a single pp run can't show.
# Drop a file in examples/ and add a line here and it goes live: the build runs
# it and embeds its real output; a broken example fails the build.
let examples = list(list("hello", "pp", ""), list("type-error", "pp", ""), list("lang-bindings", "pp", ""), list("lang-functions", "pp", ""), list("lang-laziness", "pp", ""), list("lang-effects", "pp", ""), list("lang-config", "pp", ""), list("node-identity", "pp", ""), list("node-freevars", "pp", ""), list("node-reuse", "sh", ""), list("caching", "sh", ""), list("store-layout", "sh", ""), list("store-rebuild", "sh", ""), list("build-incremental", "sh", ""), list("cap-read", "pp", ""), list("cap-grant", "sh", ""), list("cap-secret", "sh", ""), list("mod-module", "pp", ""), list("mod-load-module", "sh", ""), list("mod-island", "sh", ""), list("domain-reconcile", "sh", ""), list("dist-by-hash", "sh", ""), list("be-bytecode", "sh", ""), list("be-diff", "sh", ""), list("ref-atoms", "pp", ""), list("ref-collections", "pp", ""), list("ref-arith", "pp", ""), list("ref-compare", "pp", ""), list("ref-bool", "pp", ""), list("ref-let", "pp", ""), list("ref-letstar", "pp", ""), list("ref-def", "pp", ""), list("ref-fn", "pp", ""), list("ref-do", "pp", ""), list("ref-if", "pp", ""), list("ref-types", "pp", ""), list("ref-type-error", "pp", ""), list("ref-quote", "pp", ""), list("ref-delay", "pp", ""), list("ref-perform", "pp", ""), list("ref-config", "pp", ""), list("ref-defmacro", "pp", ""), list("ref-module", "pp", ""), list("ref-list-ops", "pp", ""), list("ref-map-ops", "pp", ""), list("ref-string-ops", "pp", ""), list("ref-predicates", "pp", ""), list("ref-list-stdlib", "sh", ""), list("ref-map-stdlib", "sh", ""), list("ref-string-stdlib", "sh", ""), list("ref-list-vec-literals", "pp", ""), list("ref-index-access", "pp", ""), list("ref-map-update", "pp", ""), list("ref-sigils", "pp", ""), list("ref-try", "pp", ""), list("ref-collect", "pp", ""))
# ch 1-2: introduction + the language in brief







# ch 3-4: nodes + store/traces






# ch 5: building

# ch 6-7: capabilities/secrets + modules/islands






# ch 8-9: domains + distribution


# ch 10: back ends


# appendix A: language reference



























# Run ONE example: a cached node slurps its source (recording the dependency),
# runs it, and returns the combined stdout+stderr. The node re-runs only when
# the source (or command) changes. Node bodies cannot write absolute paths
# (LAW 18), so the scripting tier writes captured/ for Typst to read.
def run-one(manual-dir, pp-bin, spec) {
  let (name = car(spec), kind = car(cdr(spec)), grants = car(cdr(cdr(spec))), gflag = if grants = "" {
    ""
  } else { string-append(" ", grants) }, is-sh = kind = "sh", ext = if is-sh {
    ".sh"
  } else { ".pp" }, abs-file = string-append(manual-dir, "/examples/", name, ext), real-cmd = if is-sh {
    string-append("cd ", manual-dir, "/examples && PP=", pp-bin, " sh ", name, ".sh")
  } else {
# cwd = examples/ so pp reports "NAME.pp" (never a machine path); the
# captured output stays reproducible across machines.
    string-append("cd ", manual-dir, "/examples && ", pp-bin, gflag, " ", name, ".pp")
  }, captured = node {
    slurp(abs-file)
    let (r = perform run("sh", "-c", real-cmd)) {
      string-append(hash-map-get(r, "out"), hash-map-get(r, "err"))
    }
  }) {
    if is-sh { nil } else {
      perform materialize-file(string-append(manual-dir, "/captured/", name, ".cmd"), string-append("pp", gflag, " ", name, ".pp"))
    }
    perform materialize-file(string-append(manual-dir, "/captured/", name, ".out"), captured)
  }
}




# ---- typst as hermetic tool nodes -------------------------------------------
def render-pdf(src) {
  node {
    perform run-dep!("pdf.d", "typst", "compile", "--deps", "pdf.d", "--deps-format", "make", src, "pp-manual.pdf")
    blob(slurp("pp-manual.pdf"))
  }
}
def render-html(src) {
  node {
    perform run-dep!("html.d", "typst", "compile", "--features", "html", "--format", "html", "--deps", "html.d", "--deps-format", "make", src, "index.html")
    blob(slurp("index.html"))
  }
}

let (manual-dir = car(argv()), pp-bin = car(cdr(argv())), src = string-append(manual-dir, "/manual.typ")) {
  force-deep(map(


# 1. run every example, writing captured/*.{cmd,out}
fn(s) { run-one(manual-dir, pp-bin, s) }, examples))
# 2. typeset (typst reads captured/* + chapters via read()/include)
  let (pdf-ref = render-pdf(src), html-ref = render-html(src)) {
    perform materialize-file(string-append(manual-dir, "/site/pp-manual.pdf"), blob-get(pdf-ref))
    perform materialize-file(string-append(manual-dir, "/site/index.html"), blob-get(html-ref))
    print("built", string-append(manual-dir, "/site/"))
  }
}
