#import "/lib.typ": example

#set document(title: "pp — observability", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Observability")
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

Caching is only useful when you can explain it. pp exposes the identity and the
evidence instead of reducing a miss to "the build was confused."

== See a hit

Run the same program twice. The first process enters the node body. The second
process finds the stored result and does not replay the body's print:

#example("caching", sh: true)

== See the node identity

Within one run, equal code and inputs produce one node result:

#example("node-identity")

The key is derived from code and input values. It does not include unrelated
bindings, ambient authority, or a machine location.

== Ask why

For a stored program, ask the CLI for the decision and its evidence:

```sh
pp why build.pp
```

The explanation names the node key, hit or miss, and the trace cells checked on
the way. A changed file, configuration cell, handler, probe, or child result
appears as a changed observation rather than an unexplained rebuild.

== Watch drift disappear

A reconciler makes observation visible in a different way. Delete or edit a
file under the managed root, then run the pass again:

#example("domain-reconcile", sh: true)

The second pass reports the create and update operations needed to restore the
desired tree. With `--watch`, the same observation loop repeats automatically.

== Recovery is part of the record

Domain writes use journalled intent and completion. A restart after an
interrupted apply re-observes the world instead of trusting an old success
flag. Fenced actions expose their unknown-status policy because retrying an
email or a payment is not the same as restoring a file.

The [mental models](models.html) page explains value, node, and trace. The
[manual](manual.html) contains the store, trace, and reconciler laws.
