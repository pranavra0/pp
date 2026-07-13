# tests/gen-cproject.pp — ROADMAP §2 milestone: the Phase-1 proof's C-project
# FIXTURE GENERATOR, written in pp. Generates the N-TU project that
# tests/024-phase1-exit.sh builds (shared.h, f0..f{N-1}.c, main.c,
# sources.txt). The top-level pass/fail oracle deliberately stays in shell —
# a test written in pp inherits the bugs it hunts.
#
# pp --grant fs:<src>:rw tests/gen-cproject.pp -- <N> <src-dir>
load("stdlib/list.pp")
load("stdlib/string.pp")

let args = argv()
if length(args) = 2 { nil } else { error(string-append("gen-cproject.pp expects: <N> <src-dir>", " at tests/gen-cproject.pp:12")) }
let n = string->number(nth(0, args))
let src = nth(1, args)
def path(f) { string-append(src, "/", f) }

let names = map(fn(i) { string-append("f", number->string(i)) }, range(0, n))

perform write-file(path("shared.h"), "#ifndef SHARED_H\n#define SHARED_H\n#define SHARED_CONST 7\n#endif\n")


each(fn(i) {
  perform write-file(path(string-append("f", number->string(i), ".c")), string-append("#include \"shared.h\"\n", "int f", number->string(i), "(void) { return SHARED_CONST + ", number->string(i), "; }\n"))
}, range(0, n))





perform write-file(path("sources.txt"), string-append(string-join("\n", names), "\nmain\n"))


perform write-file(path("main.c"), string-append("#include \"shared.h\"\n", string-join("\n", map(


fn(nm) { string-append("int ", nm, "(void);") }, names)), "\nint main(void) { int s = 0;\n", string-join("\n", map(

fn(nm) { string-append("  s += ", nm, "();") }, names)), "\n  return s == 0 ? 1 : 0; }\n"))
