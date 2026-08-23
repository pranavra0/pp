#import "/lib.typ": example

= Modules and islands

A module is a block of code whose definitions become a value — packaging is
not layered over the language; it is what happens when you take the names a
block defined and hand them back as something you can bind, pass, and import.
Islands extend that value across machines by pinning it to a content hash.

== Modules

`module { … }` evaluates its body in a fresh scope and produces a value carrying
the names it defined. `import(m)` forces that value and merges those names into
the current scope:

#example("mod-module")

The body sees only itself, not the surrounding scope: what escapes is exactly
what it defined, and only on import. A module value can be held, passed,
conditionally imported — ordinary until you pull its names in.

== Loading from files

Two forms bring a file's definitions in; they differ in whether the file gets
its own scope:

- `load("f.pp")` evaluates the file's forms in the current scope — its
  definitions merge in directly, as if you had typed them here.
- `load-module("f.pp")` evaluates the file isolated, in its own fresh scope,
  and returns its exports as a module value — which you then `import`. The
  file's internal scope never leaks into yours.

#example("mod-load-module", sh: true)

Reach for `load` when the file is a fragment of your program, `load-module`
when it is a self-contained unit. Either way the read is the loader's own:
runtime authority, bounded to source roots, exempt from user capability
accounting. Editing a loaded file still invalidates the nodes that loaded it —
the load is recorded in their traces even though it costs no capability.

== Islands

An island is a module that lives elsewhere — another directory, a git repository,
a URL — referenced by URI and pinned inline by the content hash of its source
tree:

```
island("file:./lib", "e5d7b0f8…")
island("github:owner/repo#main", "a1b2c3…")
```

The pin is part of the code: folding into the expression's hash makes island
identity structural — no lockfile, no hidden resolution step; a pinned island
form denotes the same bytes wherever pasted. The `#ref` matters only when
fetching; the pin argument is always the 64-hex tree hash.

Resolution never touches the network: the pin names an immutable tree under
`~/.pp/islands/src/<pin>/` (`entry.pp` is the module root), verified against
the pin on every resolve; mismatch is a hard error, as is an unpinned form.
Deriving a pin and fetching `git:`/`github:` trees the first time is the one
impure step, opt-in: `pp --update` re-resolves and rewrites pins;
`git:`/`github:` fetching needs `--fetch-islands`. With neither, evaluation
stays hermetic.

The workflow, end to end, on a local `file:` island:

#example("mod-island", sh: true)

`pp island-pins` reports each form unpinned, cached, or tampered;
`pp --update` fills in a missing pin and refuses to half-rewrite a form it
cannot rewrite unambiguously. Once pinned, an island is just another module.
