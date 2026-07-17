# pp PLAN — the open work, in order

The one plan document. It contains only work that is not done. When an
item lands, it is deleted from this file: git history is the record, and
there is no "done" section. For what works today, see
[STATUS.md](STATUS.md). For why the design is shaped this way, see
[DESIGN.md](DESIGN.md).

This file absorbed FUTURE-ARCHITECTURE.md and the still-open residue of
MASTER-PLAN.md and ROADMAP.md. Those documents, and every item they had
already delivered, live in git history.

---

## 0. The criterion

Rigor by construction, simplicity by subtraction.

A ratchet (a drift test, a CI rule, a coverage check) is scar tissue: it
exists because the design still permits a mistake. The rigorous and
simple system is the one where the mistake is inexpressible, usually
because the thing that could drift no longer has a copy to drift from.
So this plan adds no new kinds of anything. Its one admission rule:

> A change is accepted only if it net-deletes: copies, mechanisms, global
> names, rules someone must remember, or tests that exist only to guard a
> seam. A change that adds a concept must retire at least two.

One corollary:

> A copy is sanctioned only when its divergence is loud and the
> redundancy is itself the verification. Two independent engines whose
> disagreement fails a differential suite are an oracle. Two helpers in
> two files whose disagreement fails silently are a trap. pp keeps
> exactly one copy of the first kind and zero of the second.

Every stage ends green: `dune runtest`, the differential suite, and the
fuzzer. On-disk formats (cell-id strings, journal grammar, codec, store
layout) stay frozen throughout: types and moves wrap representations,
never change them. Any stage that regenerates the store-v1 golden
fixture has violated this plan.

---

## Part 0 — Correctness owed now

Known divergences fixed before, or alongside, the refactor. Correct
doesn't wait for pristine.

*(none — the module-scoping divergence (D23) and the VM dynamic-extent
exception-safety gap (D24) have both been fixed)*


## Loose ends (small, independent, grab-bag)

- SPEC caption re-pass (verified 2026-07-16): 3 of 39 law captions are stale —
  LAW 15 ("reconciler does not exist"), LAW 18 ("reconciled domains absent"),
  LAW 26 ("awaits schedulers"). Each cites a resolved blocker. The 6
  stay-honestly-partial laws (3, 8, 11, 19, 20, 21) remain correctly
  partial. Fix the captions in SPEC.md.
- NFC Unicode normalization for cell-id canonicalization is still
  unimplemented (`runtime.ml` says so): a documented residual until a
  dependency-free path exists.
- Docs into the manual site, considered at the docs sweep: the Typst
  manual is the one doc property that cannot lie (pp runs every
  example), so folding the other docs into that site would give one
  rendered home and let Typst generate what is now hand-maintained —
  for example a dependency DAG of plan items or features, rendered from
  data pp itself emits (`pp graph` already prints the cell-to-node
  graph). Two constraints decide the shape: the doc sources must stay
  greppable plain text, because 3 tests parse them (tests/072 reads
  SPEC.md's law headings, tests/067 its generated block, tests/074
  DESIGN.md's honest edges); and diagrams join as generated artifacts,
  never hand-drawn copies.
- Stretch, explicitly deferred, re-argue before building: map patterns
  in `match`; one-shot resumable effects; tail-call modulo cons; LSP;
  self-hosting.

Releases stay deliberately unplanned: no tags, no CHANGELOG (deleted,
since Conventional Commits make release notes reconstructible from git
log when a release is actually wanted; see RELEASING.md).

---

## Exit criteria (whole plan)

Checked once at the end; none of these becomes standing CI unless it
replaces a bigger mechanism it retired:

- zero `*_ref`/`*_hook` cells outside `backend.ml`; zero set-once-by-main
  refs outside the invocation record.
- `grep` finds one definition each of `force_deep`, the parse
  combinators, the string-coercion, `find_kv`, the tree walk, and one
  construction of the `"node-key"` skeleton, in the kernel.
- one flag table; `pp --help` and the parser cannot disagree.
- `pp.kernel` lists no `unix`; the fuzzer runs at least one in-process
  property through the library.
- no file in the repo is unreachable from the build, test or docs graph;
  every directory named in the README; every doc states its purpose.
- `dune runtest`, `build-self.sh` and `build-lua.sh` green; the store-v1
  golden fixture stays byte-identical to its pre-plan state.

Net expectation: about 19,000 lines down to about 14,000 to 15,000,
fewer global names, strictly fewer mechanisms, one dependency floor
raised in exchange for an entire bug class, and every remaining line
either doing something or explaining something a reader needs.
