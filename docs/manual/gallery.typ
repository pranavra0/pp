#import "/lib.typ": example

#set document(title: "pp — examples", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Examples")
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

These are small, complete programs. The source and output below are generated
from the current pp binary during the site build.

== A release graph

This one transcript crosses the boundaries that usually belong to separate
tools. Nodes build two artifacts. The desired tree deploys them. A second pass
is a full graph hit. Editing one source rebuilds one artifact. Deleting a
deployed file restores it without rebuilding either artifact.

#example("release-pipeline", sh: true)

== A self-healing service

The process domain consumes a service specification. The supervisor notices a
process killed outside pp and starts it again within the polling interval.

#example("supervise-release", sh: true)

== A cached computation

This is the smallest example that crosses a process boundary without changing
the program.

#example("caching", sh: true)

== A dependency graph

Equal node inputs share a result. A changed free variable changes the key.

#example("node-freevars")

== A capability boundary

The denied read is intentional. The program cannot create authority from a
string or from the fact that a path exists.

#example("cap-read")

== A reconciled filesystem

The transcript creates a tree, introduces drift, and repairs it. The program
returns the desired tree; it does not contain file-operation branches.

#example("domain-reconcile", sh: true)

== A module

Modules are values with a deliberate export boundary.

#example("mod-module")

== A result moved by hash

Two stores derive the same identity independently, then exchange the result
and verify it on receipt.

#example("dist-by-hash", sh: true)

== More examples

The [cookbook](cookbook.html) groups these by task. The [manual](manual.html)
contains the complete language and CLI reference.
