window.PP_EXAMPLES = [
  {
    id: "nodes",
    title: "Same computation once",
    description: "Force two equal persistent nodes and inspect the shared result.",
    source: `# Equal node code and inputs share a cache entry, so the body prints once.
let first = node { print("compute once"); 6 * 7 }
let second = node { print("compute once"); 6 * 7 }
print(force(first))
print(force(second))
`
  },
  {
    id: "build",
    title: "Incremental build",
    description: "A compile/link graph makes dependencies explicit and reusable.",
    source: `# A build graph is ordinary evaluation: nodes cache work and dependencies are
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
`
  },
  {
    id: "laziness",
    title: "Lazy value",
    description: "Delay work, then force it twice while observing memoization.",
    source: `# \`delay\` defers evaluation and \`force\` memoizes it.
let answer = delay(do { print("compute once"); 6 * 7 })
print(force(answer))
print(force(answer))
`
  },
  {
    id: "effects",
    title: "Scoped handler",
    description: "A pure handler supplies an answer without ambient authority.",
    source: `# \`perform\` dispatches an effect to the nearest dynamically scoped handler.
with { handlers: { :ask -> fn(question) { string-append(question, " 42") } } } {
  print(perform ask("answer:"))
}
`
  }
];
