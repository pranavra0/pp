#import "/lib.typ": example

#set document(title: "Using pp", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("../style.css"))
    html.elem("div", attrs: (style: "display: contents;"), {
      html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "")
    })
    html.elem("script", read("../dark-mode.js"))
    html.elem("h1", "Using pp")
    html.elem("nav", attrs: (class: "site-nav"), {
      html.elem("a", attrs: (href: "index.html"), "pp")
      html.elem("a", attrs: (href: "using-pp.html"), "Using pp")
      html.elem("a", attrs: (href: "cookbook.html"), "Cookbook")
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
  }
}

pp is for programs whose inputs, results, and effects should remain visible.
You write a value or a computation. pp gives it an identity, records what it
read, and lets a narrow runtime decide when work must run again.

This is useful in more than one shape. The language is the same in each case:

#table(
  columns: (auto, 1fr),
  stroke: .5pt,
  inset: 6pt,
  [*If you need*], [*Start with*],
  [a reproducible build], [`node`, then the store and traces],
  [a script that may read or write], [capabilities and foreign execution],
  [a service or filesystem kept in sync], [desired state and a domain],
  [work shared across processes or machines], [content identity and scheduling],
)

The short version is: pure code computes a desired value; nodes make safe work
reusable; capabilities make authority explicit; domains apply desired state.

== The same computation at four scales

Start with an ordinary function. It has no authority and no persistent state.

```pp
def compile(source) {
  string-append(source, ".o")
}
```

Wrap the expensive part in a node when its result is worth reusing:

```pp
def compile(source) {
  node { string-append(source, ".o") }
}
```

Force it from a program. The first process computes it; a later process with
the same code and input can use the stored result.

#example("node-reuse", sh: true)

When the result describes a world that should exist, return that value to a
domain. The reconciler observes the world, computes a plan, and applies it.
There is no separate "if missing" branch in the program.

#example("domain-reconcile", sh: true)

The scale changes. The evaluation model does not.

== What pp keeps separate

Three questions that are often mixed together have different answers in pp:

#table(
  columns: (auto, 1fr),
  stroke: .5pt,
  inset: 6pt,
  [*Question*], [*pp's answer*],
  [What is this result?], [A content-addressed value.],
  [Can this work be reused?], [A node, checked against its recorded trace.],
  [What may this code touch?], [The capabilities it holds.],
  [Where should work run?], [A scheduler or provider decision, not program syntax.],
  [How should the world change?], [A domain applying desired state.],
)

This separation is the reason a build can be incremental, a supervisor can
recover from drift, and a program can be moved without adding location forms to
the language. The chapters that follow show each boundary in detail.

== Read the manual by goal

If you are learning the language, read the introduction and the language
chapter. Then use the language reference as a lookup.

If you are building a cacheable computation, read the chapters on nodes, traces,
and foreign execution. `pp why` is the shortest route from a surprising miss
to the input that changed.

If you are writing automation, read capabilities before foreign execution. A
filesystem read is not a special exception to the language; it is an observed
effect with an authority check.

If you are describing a service, deployment, or filesystem tree, jump to the
domains chapter. Start with a pure desired-state value, then add a domain only
at the boundary that writes it.

If you are interested in distribution, read nodes and traces first. Scheduling
does not change a node's identity. The distribution chapter shows how the same
value moves between stores.

== A small gallery

The manual's examples are complete programs, not pseudocode. These are useful
places to begin:

- `node-reuse` shows persistence across processes.
- `caching` shows a cache hit without repeating the node body.
- `cap-read` shows a denied world read when no capability was granted.
- `domain-reconcile` shows drift repaired by a second pass.
- `dist-by-hash` shows two stores exchanging a result by content hash.
- `mod-module` shows a program assembled from a module.

The cookbook later in the manual groups the same examples by the problem they
solve. Every block is run while the manual is built. The output on the page is
the output of the current binary.
