#set document(title: "pp — constraints", author: "the pp project")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), { html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "") })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "Constraints")
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

pp refuses a few convenient shortcuts. Each refusal protects one of the
identities the rest of the system relies on.

== No ambient authority

A function cannot read a file, inspect an environment variable, or start a
process because the host happens to provide it. The root must grant the
capability, and a callee can receive only a narrower one.

== No unsound cache

A node cannot hide an input from its key or trace. Ambient subprocesses and
unaccounted nondeterminism are scripting-tier. A trusted provider may classify
an immutable request as cacheable only after accounting for its semantic input.

== No mutation inside a node

Nodes are replayable values. An irreversible action cannot be smuggled into a
cached body. Convergent writes belong to a domain; one-shot actions belong to a
journalled fenced effect.

== No location syntax

There is no `remote-eval`, placement annotation, or host-specific node form.
`force` is the execution primitive. The scheduler can choose serial, parallel,
race, or remote execution without changing program identity.

== No hidden ordering from authority

Capabilities grant access; they do not establish sequence. Ordering comes from
value dependencies, explicit `do` blocks, or a domain's apply protocol.

== No magical reconciler

The reconciler is not a second language hidden behind the CLI. A domain is
ordinary pp policy over observe, diff, and apply, with a small trusted runtime
boundary for journalling and verification.

== No silent recovery of ambiguous effects

After a crash, a convergent write can be observed again. An irreversible action
may have unknown status, so pp requires an explicit retry, abort, or ask policy.

These constraints are the design bargain. In return, a result can carry its
identity, authority boundary, and evidence. Read [observability](observability.html)
to see what that evidence looks like, or [the manual](manual.html) for the
semantic laws.
