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
      html.elem("a", attrs: (href: "using-pp.html"), "Using pp")
      html.elem("a", attrs: (href: "cookbook.html"), "Cookbook")
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
  }
}

pp is a content-addressed, capability-scoped language for computations that
should be reusable, inspectable, and safe to move.

== Start here

#link("using-pp.html")[Using pp] explains what pp is for and how one evaluation
model grows from a pure function into a cached computation, a reconciler, or a
distributed job.

#link("cookbook.html")[The cookbook] starts with problems: cache a build step,
inspect a miss, grant authority, repair drift, supervise a service, and share a
result between stores.

#link("manual.html")[The reference manual] is the detailed guide. Every example
on it is run by the build. The [PDF](pp-manual.pdf) is published beside it.

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

Read the [manual](manual.html) when you need a form or flag. Read the
[cookbook](cookbook.html) when you have a task to solve.
