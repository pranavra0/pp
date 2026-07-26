#import "/lib.typ": example

#set document(title: "pp — paths", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Paths through pp")
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

pp has one evaluator, but you can meet it from several directions. Pick the
job you need to do. The examples on each path are complete programs or
transcripts, and the reference manual remains the lookup for every form.

== Builds

Make expensive steps nodes. Force dependencies before the next step. Equal
code and inputs share a result, even in another process.

#example("node-reuse", sh: true)

Continue with [the cookbook](cookbook.html), then read nodes and traces in the
[manual](manual.html).

== Reconciliation

Return the tree or map that should exist. A domain observes reality, diffs it
against that value, and applies the plan. Drift is an input to the next pass.

#example("domain-reconcile", sh: true)

Continue with [the before/after guide](before-after.html) and the domains
chapter in the [manual](manual.html).

== Supervision

Describe services as a desired map. `--supervise` keeps the process domain
matching it; `--watch` repeats the pass when observation changes. A changed
specification restarts a service. A killed service is started again.

The process-domain section of the [manual](manual.html) shows the full
observe / diff / apply protocol. The [gallery](gallery.html) collects the
complete reconciliation examples.

== Capabilities

World access is authority, not an ambient convenience. A program can use only
the capabilities it was given, and it can narrow a held capability before
passing it on.

#link("cookbook.html")[The cookbook] starts with a denied read. The
[constraints](constraints.html) page explains why the restriction is part of
the programming model.

== Distribution

Location is a scheduler decision. Content identity is the boundary: machines
derive the same node key, exchange the result by hash, and verify its trace.

#example("dist-by-hash", sh: true)

Continue with the distribution chapter in the [manual](manual.html), then use
[observability](observability.html) to inspect what crossed the boundary.

== Next

Read [mental models](models.html) before the reference chapters if the terms
value, node, trace, and domain are new to you.
