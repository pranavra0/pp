# Authoring the pp manual

The manual is Typst source. Every retained pp example is exercised by
`tests/086-manual-examples.sh`, and `scripts/build-manual.sh` executes every
example referenced by a chapter or the landing page before rendering the site
and PDF. Read `chapters/01-introduction.typ` and
`chapters/02-language.typ` first; they set the voice and the example
conventions. Match them.

## Voice (copy the Zig language reference)

- Second person, present tense, direct. "You wrap a computation in `node`…",
  not "One may wish to…".
- Terse. Lead with the point. A sentence or two of motivation, then show it.
- Example-first. Prefer provoking behaviour to describing it — including
  errors: show the real error message, don't paraphrase it.
- No marketing, no filler, no "powerful"/"seamless"/"simply". Plain technical
  prose. If a paragraph doesn't earn its place, cut it.

## Chapter files

- One file per chapter: `chapters/NN-slug.typ`. Start it with
  `#import "/lib.typ": example`.
- Use `=` for the chapter heading, `==` / `===` for sections. Numbering and the
  table of contents are automatic. Do **not** hand-number.
- Do not use `@label` cross-references yet (they break the build until every
  label exists). Refer to other chapters in prose.
- Keep project explanations and reference material in the manual. The landing
  page is `website.typ`; do not create standalone pages for new topics.

## Examples — the core rule

Examples are real files in `examples/`, run for real. **Never invent output.**
If you can't make an example run and produce the output you want, change the
example — do not fake it. Three manifest kinds are available:

- **`examples/<name>.pp`** — a pp program. Render it with `#example("<name>")`.
  The build runs `pp <name>.pp` and shows the source, the command, and the
  output. The manifest marks ordinary programs `pp`; examples intentionally
  demonstrating a failure use `pp-error` and must exit nonzero.
- **`examples/<name>.sh`** — a shell transcript, for anything one `pp` run can't
  show (caching across runs, incremental rebuilds, reconcile loops, deploys).
  Render it with `#example("<name>", sh: true)`. The script is run with `$PP`
  bound to the pp binary. It **must** set its own throwaway store so it is
  hermetic and reproducible:

  ```sh
  #!/bin/sh
  export HOME=$(mktemp -d)
  # ... use "$PP" ..., print deterministic output ...
  rm -rf "$HOME"
  ```

  See `examples/caching.sh`.

Conventions:
- Prefix example filenames with your chapter's area (`node-…`, `store-…`,
  `build-…`, `cap-…`, `mod-…`, `domain-…`, `dist-…`) so parallel chapters never
  collide.
- Output must read cleanly. `print` shows strings quoted and does not space
  multiple arguments (`(print "x:" 1)` → `"x:"1`). Print bare values and let the
  prose supply the label.
- Reproducible only: no timestamps, no wall-clock timings, no absolute paths, no
  random data in output. Run sh examples with `cd examples` semantics in mind —
  pp reports source locations relative to its working directory.
- Verify every primitive/form against the binary before using it (`bin/pp -e
  '…'`, `lisp/runtime/language.lisp`, the `tests/` and `examples/` trees).
  This codebase has a history of docs claiming things that aren't true; that's
  the whole reason the examples run.

## Build

Run the complete manual build after changing chapters, examples, styles, or
rendering helpers:

```sh
scripts/build-manual.sh
```

It refreshes the ignored `docs/manual/captured/` directory, then writes the
tracked `docs/manual/site/index.html`, `manual.html`, and `pp-manual.pdf`. Do not hand-edit
captured output or rendered files. A broken example or Typst error fails the
build.
