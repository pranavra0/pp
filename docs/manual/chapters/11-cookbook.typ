#import "/lib.typ": example

#set document(title: "pp cookbook", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("../style.css"))
    html.elem("div", attrs: (style: "display: contents;"), {
      html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "")
    })
    html.elem("script", read("../dark-mode.js"))
    html.elem("h1", "pp cookbook")
    html.elem("nav", attrs: (class: "site-nav"), {
      html.elem("a", attrs: (href: "index.html"), "pp")
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
  }
}

These recipes start from a task rather than a language form. Each one points
to the smallest existing example that demonstrates the idea. Run the command
shown in the example block, then change one input and run it again.

== Cache an expensive computation

Put only the reusable computation in a node. Keep the call site ordinary:

#example("caching", sh: true)

The first run prints from inside the node. The second run prints only the final
value. If the code or a value it reads changes, pp derives a new key.

Use `delay` when sharing should last only for the current process. Use `node`
when the result should survive the process.

== Find out why work ran again

Run the program with the store enabled, then inspect the node's explanation:

```sh
pp why program.pp
```

The explanation names hits, misses, and the cells in the trace. A content key
is not a timestamp or a best guess about dependencies. A hit is allowed only
after pp verifies the trace against the current world.

The store chapter explains the output and the CLI reference lists the audit
flags. Start there when a cache result surprises you.

== Read the world with explicit authority

Observation sigils make a world read visible at the call site:

#example("cap-read")

This example is expected to fail. Granting a capability is a command-line
decision, not something the program can manufacture. Narrow a held capability
before passing it to a helper when the helper needs less authority than its
caller.

== Build an artifact graph

Represent each expensive step as a node and force dependencies before the next
step:

#example("node-freevars")

The node key includes the code and the values of its free variables. That lets
pp reuse an unchanged compile step while rebuilding a changed link step. The
node chapter's `node-identity` example shows the same key being shared twice in
one run.

== Turn a script into desired state

Return the complete tree that should exist. Do not encode creation, update,
and deletion branches in the program:

#example("domain-reconcile", sh: true)

The filesystem domain computes those operations from observation and desired
state. A hand edit, a deleted file, and a fresh directory are all ordinary
differences. `--watch --reconcile` repeats the same pass when observation
changes.

== Keep a service running

The process domain consumes a map from service names to specifications. Run it
with `--supervise`, and add `--watch` when it should repair drift continuously.
Changing a specification produces a restart; killing a tracked process
produces a start. The domain chapter describes the observe / diff / apply
protocol shared by filesystem and process state.

== Make an external request cacheable

Do not put an ambient process call in a node. Build an immutable request with
its tool, inputs, arguments, environment, platform, and selected outputs, then
let a trusted provider classify it. A provider that cannot account for every
semantic input must return scripting-only.

```pp
run-closed!({
  :tool -> tool-tree,
  :tool-path -> "bin/tool",
  :args -> ["build"],
  :inputs -> source-tree,
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> ["result"]
})
```

The foreign execution chapter covers this boundary. The rule is short: a
cache is only as sound as its account of inputs.

== Share work between stores

Content identity lets two stores derive the same key independently. Publish
the result by that key and let the receiving store verify it:

#example("dist-by-hash", sh: true)

The scheduler chooses where a force runs. The program still describes the same
computation, and the result still carries the trace that justifies reuse.

== Compose a program from a module

Use a module when a group of definitions should be evaluated in its own scope
and exported deliberately:

#example("mod-module")

Modules are values. Load them from a file when the boundary should be a source
file; use islands when the boundary also needs an isolated store and authority
ceiling.

== Choose the next chapter

The language chapter explains the surface. Nodes explain reuse. Capabilities
explain authority. Domains explain convergence. Distribution explains moving
the same content-addressed work. The reference appendices are indexed by form,
flag, and library rather than by use case.
