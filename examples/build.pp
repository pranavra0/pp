# pp example: build system as a Lisp expression
# Demonstrates: the DAG emerges from evaluation — no separate build system

# A "build step" is just a function
def compile-file(source, target) {
  effect(print("compiling", source, "→", target), string-append("object-", source, ".o"))
}
# In a real build, this would call gcc/clang
# For now, just return a string identifier


def link-objects(objects, target) {
  effect(print("linking", objects, "→", target), string-append("binary-", target))
}


# The build is just an expression
def build-project(src-dir, build-dir) {
  let (obj1 = delay(compile-file("main.c", "main.o"))) {
    let (obj2 = delay(compile-file("utils.c", "utils.o"))) {
      let (binary = delay(link-objects(list(force(obj1), force(obj2)), "myapp"))) {
        force(binary)
      }
    }
  } }
# Run the build
build-project("./src", "./build")
