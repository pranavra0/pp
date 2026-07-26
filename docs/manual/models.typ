#set document(title: "pp — mental models", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Mental models")
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

The names in pp describe different parts of one evaluation story. Keep them
separate and the rest of the system becomes predictable.

#table(
  columns: (auto, 1fr, 1fr),
  stroke: .5pt,
  inset: 6pt,
  [*Thing*], [*It is*], [*It answers*],
  [Value], [content-addressed data], [What is the result?],
  [Node], [a persistent computation], [Can this work be reused?],
  [Trace], [evidence of reads and child results], [Why is a reuse valid?],
  [Capability], [unforgeable authority], [What may this code touch?],
  [Handler], [a dynamic interpretation of an effect], [How is this effect handled?],
  [Domain], [observe / diff / apply policy], [How does the world converge?],
)

== Value

Every value has a content hash. Equal values have equal identity. A map's
binding order is not part of its meaning, and a closure includes the values it
captures. This is the base that makes comparison and storage honest.

== Node

A node packages reusable work. Its key includes its code and the values of its
free variables. `delay` shares work in one process; `node` can share it across
processes and stores.

```text
code + input values → node key → result
```

== Trace

A key alone does not prove that a stored result is still usable. A trace records
the cells observed while producing it. pp verifies those observations before
serving a hit. The trace is the reason a cache can account for the world it
read.

== Capability

A capability is authority, not information. It enters at the root, can be
narrowed, and cannot be widened by user code. A filesystem observation without
the matching capability is refused before the read.

== Handler

`perform` finds the nearest handler in dynamic extent. A result-transparent
handler can change scheduling or interpretation without changing identity. A
semantic handler is part of the computation's meaning and is recorded in its
trace.

== Domain

A domain is a single writer for a namespace:

```text
observe world → diff observed desired → apply plan
```

The desired value is ordinary pp data. The domain owns the narrow trusted
boundary that changes the world. Filesystems and processes use the same
protocol.

== The whole picture

```text
value
  ↓ force
node + trace
  ↓ desired state
domain
  ↓ apply
world
```

Read [the paths](paths.html) for applications, or the [manual](manual.html) for
the laws behind each arrow.
