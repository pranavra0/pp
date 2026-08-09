#import "/lib.typ": example

#set document(title: "pp", author: "Pranav Rao")
#set par(justify: true)
#set raw(syntaxes: "pp.sublime-syntax", theme: "/pp.tmTheme")

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
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
  }
}

pp is a content-addressed, capability-scoped language for computations that
should be reusable, inspectable, and safe to move.

The #link("manual.html")[reference manual] contains the language, runtime, domains, distribution, CLI, standard library,
and tested examples. The #link("pp-manual.pdf")[PDF] is the same manual in a
printable format.

== The short version

```text
value → node → desired state → reconciled world
```

Values have content identity. Nodes reuse computations across processes.
Capabilities make authority explicit. Domains apply desired state and repair
drift. Scheduling chooses where a force runs without changing the program's
identity.

== Programming language as a graph

This is the scale to keep in mind: source files become cached artifacts, the
artifacts become desired state, the filesystem domain deploys them, and the
same graph can be forced again after a source edit or a deleted output.

#example("release-pipeline", sh: true)


== A small example

```pp
def compile(source) {
  node { string-append(source, ".o") }
}

print(force(compile("main.c")))
```

Read the #link("manual.html")[manual] when you need a form, flag, or runtime
API.
