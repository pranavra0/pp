#import "/lib.typ": example

= Modules and islands

A module is a block of code whose definitions become a value. That is the
whole idea. Packaging is not a separate mechanism layered over the language. It
is what happens when you take the names a block defined and hand them back as
something you can bind, pass, and import. Islands extend the same value across
machines by pinning it to a content hash.

== Modules

`module { … }` evaluates its body in a fresh scope and produces a value carrying
the names it defined. `import(m)` forces that value and merges those names into
the current scope:

#example("mod-module")

The module's body sees only itself, not the scope around it, so a module is a
sealed unit: what escapes is exactly what it defined, and only once you import
it. You can hold a module value, pass it to a function, or import it
conditionally — it is an ordinary value until the moment you pull its names in.

== Loading from files

Two forms bring a file's definitions into a program, and they differ in whether
the file gets its own scope:

- `load("f.pp")` evaluates the file's forms in the current scope — its
  definitions merge in directly, as if you had typed them here.
- `load-module("f.pp")` evaluates the file isolated, in its own fresh scope,
  and returns its exports as a module value — which you then `import`. The
  file's internal scope never leaks into yours.

#example("mod-load-module", sh: true)

Reach for `load` when a file is a fragment of the current program, and
`load-module` when it is a self-contained unit you want to keep at arm's length.
Either way, the read is the loader's own — it runs under the interpreter's
runtime authority, bounded to your source roots, and is exempt from the
capability accounting of the previous chapter. Editing a loaded file still
invalidates the nodes that loaded it: the load is recorded in their traces even
though it costs no user capability.

== Islands

An island is a module that lives elsewhere — another directory, a git repository,
a URL — referenced by URI and pinned inline by the content hash of its source
tree:

```
island("file:./lib", "e5d7b0f8…")
island("github:owner/repo#main", "a1b2c3…")
```

The pin is part of the code. Because it folds into the expression's hash,
island identity is structural: there is no lockfile and no hidden resolution
step — a pinned island form denotes the same bytes wherever you paste it. The
ref after `#` lives in the URI and matters only when fetching; the pin argument
is always the 64-hex content hash of the tree.

Resolution never touches the network. The pin names an immutable tree in the
island cache under `~/.pp/islands/src/<pin>/`, whose `entry.pp` is the module
root. pp verifies the cached tree against the pin on every resolve. A
mismatch is a hard error, not a silent reuse. An unpinned island form is a
hard error too, naming the fix. Deriving the pin, and fetching a `git:` or
`github:` tree the first time, is the one impure step, and it is opt-in.
`pp --update` re-resolves each island and rewrites the pins in your source,
while `git:`/`github:` fetching happens only under `--fetch-islands`. With
neither enabled, evaluation stays hermetic.

The workflow, end to end, on a local `file:` island:

#example("mod-island", sh: true)

`pp island-pins` reports the forms and whether each is unpinned, cached, or
tampered; `pp --update` fills in a missing pin rather than making you compute
the hash by hand, and refuses to touch a form it cannot rewrite unambiguously
rather than half-writing your file. Once the pin is in place, the island is just
another module: `import` its value and call what it exports.
