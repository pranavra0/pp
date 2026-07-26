#set document(title: "pp", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")

#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), {
      html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "")
    })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "pp")
    html.elem("nav", attrs: (class: "site-nav"), {
      html.elem("a", attrs: (href: "index.html"), "pp")
      html.elem("a", attrs: (href: "paths.html"), "Paths")
      html.elem("a", attrs: (href: "models.html"), "Models")
      html.elem("a", attrs: (href: "gallery.html"), "Gallery")
      html.elem("a", attrs: (href: "before-after.html"), "Before/After")
      html.elem("a", attrs: (href: "observability.html"), "Observe")
      html.elem("a", attrs: (href: "constraints.html"), "Constraints")
      html.elem("a", attrs: (href: "cookbook.html"), "Cookbook")
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
  }
}

pp is a content-addressed, capability-scoped language for computations that
should be reusable, inspectable, and safe to move.

== Start here

== Choose a path

#table(
  columns: (auto, 1fr),
  stroke: .5pt,
  inset: 6pt,
  [*You want to*], [*Read*],
  [build incrementally], [#link("paths.html")[Builds]],
  [repair files or services], [#link("paths.html")[Reconciliation and supervision]],
  [understand the vocabulary], [#link("models.html")[Mental models]],
  [see complete programs], [#link("gallery.html")[Examples]],
  [understand a cache miss], [#link("observability.html")[Observability]],
  [understand the boundaries], [#link("constraints.html")[Constraints]],
)

The [cookbook](cookbook.html) starts with small tasks. The [reference
manual](manual.html) is the detailed guide, and the [PDF](pp-manual.pdf) is
published beside it.

== The short version

```text
value → node → desired state → reconciled world
```

Values have content identity. Nodes reuse computations across processes.
Capabilities make authority explicit. Domains apply desired state and repair
drift. Scheduling chooses where a force runs without changing the program's
identity.

== A small example

```pp
def compile(source) {
  node { string-append(source, ".o") }
}

print(force(compile("main.c")))
```

Read the [cookbook](cookbook.html) when you have a task to solve. Read the
[manual](manual.html) when you need a form or flag.
