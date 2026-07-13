# build.pp — build the pp project with pp itself
# v1: aspirational (process effects not yet wired to ocamlc)
# Concept: the build system IS the language — no Makefile needed

# A compilation unit is a pure function of its source and flags
def compile-ocaml(source, flags) {
  effect(print("compiling", source, "..."), string-append(source(source, 0, string-length(source) - 3), ".cmo"))
}
# (perform ProcessSpawn "ocamlc" (concat flags source))
# For now, just return the expected .cmo path


# The full build DAG — just a Lisp expression
def build-pp() {
  let (types_cmo = delay(compile-ocaml("src/types.ml", "-c")), hasher_cmo = delay(compile-ocaml("src/hasher.ml", "-c")), reader_cmo = delay(compile-ocaml("src/reader.ml", "-c")), caps_cmo = delay(compile-ocaml("src/capabilities.ml", "-c")), prims_cmo = delay(compile-ocaml("src/primitives.ml", "-c")), eval_cmo = delay(compile-ocaml("src/evaluator.ml", "-c")), cache_cmo = delay(compile-ocaml("src/cache.ml", "-c")), repl_cmo = delay(compile-ocaml("src/repl.ml", "-c")), main_cmo = delay(compile-ocaml("src/main.ml", "-c"))) {
    let (binary = delay(effect(print("linking..."), "pp"))) { force(binary) }
  }
}





# Link step depends on all compilations



# (perform ProcessSpawn "ocamlc"
# (list "-o" "pp" types_cmo hasher_cmo ...))

# Force the final binary — transitively forces everything in the DAG


# Incrementality is free: if a source file hasn't changed, its hash
# matches the cached thunk, and compilation is skipped.
# This is the same DAG model that Make/Nix/Bazel reimplement poorly.
build-pp()
