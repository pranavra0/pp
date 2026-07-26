#set document(title: "pp — before and after", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Before and after")
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

The point of pp is easiest to see beside the scripts it replaces. The syntax is
not the important part. The ownership of identity, authority, and change is.

== Shell build → pp build

A shell build usually repeats every command and relies on timestamps or a
hand-written dependency graph:

```sh
cc -c main.c -o main.o
cc -c util.c -o util.o
cc main.o util.o -o app
```

In pp, each expensive step is a node and the link step receives the compiled
values:

```pp
def compile(source) {
  node { print("compile", source); string-append(source, ".o") }
}

def link(left, right) {
  node { print("link", left, right); string-append(left, "+", right) }
}

print(force(link(force(compile("main.c")), force(compile("util.c")))))
```

The dependency graph is the value flow. The store can reuse either compile
step independently. [The gallery](gallery.html) shows the cross-process
transcript.

== Deployment script → reconciler

An imperative deployment script describes transitions:

```sh
if test ! -f site/index.html; then
  cp build/index.html site/index.html
fi
rm -f site/old.html
```

That script grows a new branch for every drift case. A pp program returns the
complete tree:

```pp
reconcile {
  "index.html" -> $file("build/index.html"),
  "app.css" -> $file("build/app.css")
}
```

The filesystem domain computes create, update, and delete operations from the
observed tree. Run the same pass again and it is a no-op. [The paths](paths.html)
and [gallery](gallery.html) show the real transcript.

== Restart loop → supervisor

A restart loop owns timing, process IDs, and special cases:

```sh
while true; do
  ./worker || true
  sleep 1
done
```

The process domain instead consumes desired service specifications:

```pp
{
  "worker" -> {
    :cmd -> "./worker",
    :args -> [],
    :env -> {},
    :cwd -> "."
  }
}
```

`--supervise --watch` observes the process table and converges it to that map.
A changed spec restarts the named service; a killed service is started again.
The same observe / diff / apply protocol handles files and processes.

== Next

Read [mental models](models.html) to name the pieces, then use
[observability](observability.html) to see why pp can make these changes
without hiding them.
