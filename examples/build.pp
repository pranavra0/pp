# A build graph is ordinary evaluation: nodes cache work and dependencies are
# established by forcing their results.
def compile(source) {
  node { print("compile", source); string-append(source, ".o") }
}

def link(left, right) {
  node { print("link", left, right); string-append(left, "+", right) }
}

let main = compile("main.c")
let util = compile("util.c")
print(force(link(force(main), force(util))))
