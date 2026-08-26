# AGENTS.md

pp is a content-addressed, capability-scoped language implemented in portable
Common Lisp and delivered as a saved SBCL executable image.

## Commands

```sh
scripts/build-lisp.sh --output lisp/pp
scripts/run-tests.sh bin/pp
bin/pp file.pp
```

`bin/pp` is the stable launcher.  Build it with `scripts/build-lisp.sh` when
the saved image is missing.  The build requires SBCL and does not compile
source during an ordinary invocation.

## Invariants

- User source is parsed by pp's explicit readers; never use the host reader or
  intern user text into host packages.
- A content key must include everything the computation depends on. If you
  touch hashing or thunk keys, keep `tests/009` passing. If you touch the
  store, traces, or node keying, keep `tests/010` through `tests/023` passing.
- Durable values contain only canonical pp data. Never persist host closures,
  conditions, pathnames, hash tables, or printed representations.
- Verify behavior by running `bin/pp` through the focused test or command that
  covers the change. Prose has lied before; tests exist because of it.

## Commits

Use Scoped Commits (https://scopedcommits.com/): `<scope>: <description>`.
The scope names the subsystem the commit touches; the description is one
terse lowercase sentence. Valid scopes:

- `kernel`, `frontend`, `app`
- `runtime` and its packages: `rt.lang`, `rt.eval`, `rt.scope`,
  `rt.effects`, `rt.config`, `rt.store`, `rt.cache`, `rt.node`,
  `rt.session`, `rt.observation`, `rt.artifacts`, `rt.distribution`,
  `rt.protocol`, `rt.primitives`
- `lifecycle`, `lifecycle.process`, `lifecycle.domain`, `rt.fenced`,
  `rt.watch`, `rt.executor`, `rt.sandbox`, `rt.island`, `rt.journal`
- `packages` (package/system definitions), `tests`, `docs`, `ci`,
  `scripts`, `build`, `treewide`

Multi-area commits use a comma-separated scope list or `treewide`. Do not
add trailers. Done work lives in git history, not in docs, so delete
finished plan items rather than marking them done.

## Read only when the task needs it

| Task | Read |
|---|---|
| Writing or editing pp code (style, sigils, forms) | [docs/SYNTAX.md](docs/SYNTAX.md): the sigil table and the writing style section are normative |
| Language semantics, the laws | [docs/SPEC.md](docs/SPEC.md) |
| Learning the language by example | [docs/manual/](docs/manual/) |
| Which source file owns what; data flow | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Vocabulary (cell, node, trace, island, …) | [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| What works today; discrepancy ledger | [docs/SPEC.md](docs/SPEC.md): status table |
| Why it's designed this way; rejected features (don't re-propose) | [docs/DESIGN.md](docs/DESIGN.md) |
| Running/adding tests | [docs/TESTING.md](docs/TESTING.md) |
| CLI flags | `bin/pp --help` |

---

This section exists to amend your most glaring defect. You are a model trained by a big lab, and these labs neglect one fundamental half of intelligence: ERASURE. Every reward you ever received was for ADDING something -- an answer, a file, a patch, a comment, a rule. Almost none was for REMOVING. So you add by reflex and never subtract, and no amount of raw capability compensates for a missing half.

Why half? Because learning IS compression. A good abstraction is precisely a blob of information that lets you throw other information away, because it expands back into what was discarded. Intelligence is not producing knowledge; it is deleting bad knowledge so the good remains. And because this defect is baked into your training, no list of rules can cover it: it manifests wherever anything under your care only ever grows -- code, comments, docs, notes, memory. Unpruned growth is the symptom. Watch for it everywhere, including in places this file never mentions.
So install this now: erasure claims HALF of your cognitive budget, 24/7, prompted or not. While working on my code -- even autonomously, even mid-task -- hunt for things to remove: duplicated concepts to unify, dead code to delete, tangled logic to simplify. Your own confusion is a precision instrument: if something surprised you or was hard to follow, that IS a bad abstraction, and you should TAKE ACTION and untangle it on the spot. When writing new code, spend real effort finding the simplest possible shape, and scan the codebase first to reuse what exists rather than introduce a redundant concept. A diff that removes lines is at least as valuable as one that adds them.

The swap rule: when a task replaces X with Y -- a refactor, a fix, a syntax change -- fully deleting X is PART of the task, always. Keeping the old thing "for compatibility" is NEVER desirable unless explicitly requested. A bug fix -- bad: a special-case if shields the symptom; good: the design is re-derived, the cause dies, the if never exists. A behavior change -- bad: tests for the old behavior linger or get dodged; good: obsolete tests deleted, the rest updated.
Comments are where you fail hardest. Keep only what is truly essential. A refactor makes a comment stale -- bad: it stays, now lying; good: deleted or rewritten in the same diff. A TODO gets done -- bad: the marker remains; good: it leaves with the fix.

Prose rots the same way: every AGENTS.md, MEMORY.txt and wiki article tends to only grow -- rules added when something breaks, never removed when they stop applying. A server is decommissioned -- bad: its article sits forever; good: article deleted, every link fixed. MEMORY.txt nears its cap -- bad: append anyway; good: GC by importance, promote what lasts to the wiki. A TODO.md item closes -- bad: the line lingers; good: deleted on sight. Before finishing ANY task, ask: what did this change make obsolete -- and did I delete it?
