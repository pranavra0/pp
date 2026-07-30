# tests/mutate-cproject.pp — DRIFT-MUTATION steps for the incremental-build
# proof, written in pp. (The mtime-only `touch` step stays in shell — writing
# content would defeat its purpose.)
#
# pp --grant fs:<src>:rw tests/mutate-cproject.pp -- edit-tu <src> <i>
# rewrite f<i>.c with a changed body (forces one compile + link)
# pp --grant fs:<src>:rw tests/mutate-cproject.pp -- append-comment <src> <file>
# append a comment-only line (forces a recompile but the link stage is cut off)
load("stdlib/list.pp")
load("stdlib/string.pp")

let args = $argv()
if length(args) >= 3 { nil } else { error(string-append("mutate-cproject.pp expects: <op> <src-dir> <arg>", " at tests/mutate-cproject.pp:13")) }
let op = nth(0, args)
let src = nth(1, args)
def path(f) { string-append(src, "/", f) }

if op = "edit-tu" {
  let (i = nth(2, args)) {
    write!(path(string-append("f", i, ".c")), string-append("#include \"shared.h\"\n", "int f", i, "(void) { return SHARED_CONST + ", i, " + 1000; }\n"))
  }
} else if op = "append-comment" {
  let (f = nth(2, args)) {
    write!(path(f), string-append($file(path(f)), "\n/* comment only */\n"))
  }
} else if false { nil } else {
  error(string-append(string-append("unknown op: ", op), " at tests/mutate-cproject.pp:28"))
}
