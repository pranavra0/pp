# pp testing

The test suite runs the saved Common Lisp image through two complementary
interfaces: expected-output programs and shell scenarios. Expected-output
files pin stdout, stderr, and the final exit status. Shell scenarios exercise
process boundaries, isolated stores, capabilities, effects, and filesystem
state that a single invocation cannot cover.

This file describes the machinery only. Each test file's own header states
what that test proves; read the file rather than maintaining a second
catalogue here.

## Run the suite

```sh
scripts/build-lisp.sh --output lisp/pp
scripts/run-tests.sh bin/pp
```

`scripts/run-tests.sh` runs every `tests/NNN-*.pp` program against its
`tests/NNN-*.pp.expected` file and then runs each `tests/*.sh` shell suite.
Each case receives an isolated temporary `HOME`; shell cases use
`tests/lib.sh` for the selected `PP`, temporary files, and assertions.

Cases run concurrently by default. Set `TEST_JOBS=1` for deterministic serial
debugging. `TEST_CASE_TIMEOUT` bounds each case and defaults to 120 seconds.
Results are buffered and replayed in enumeration order.

The category counts come from `scripts/test-categories.sh`. The focused shell
suites cover language laws, readers and printers, effects and capabilities,
durable nodes and traces, lifecycle, reconciliation, transport, crash
recovery, and adversarial worlds. `scripts/check-architecture.sh` builds a
fresh saved image and exercises version and pure evaluation before the suite.

## Add a test

A `.pp` test needs no wiring beyond its `.expected` file: add
`tests/NNN-name.pp`, run it once with an isolated home, and save stdout,
stderr, and the exit line as `tests/NNN-name.pp.expected`. A shell scenario
needs only an executable `tests/NNN-name.sh`; the runner discovers it
automatically.

Conventions:

- start each file with a short header comment stating what it proves;
- add a `# pins: LAW-<n>` line when the test pins a SPEC law; the marker is
  machine-parsed by `tests/072-law-pins.sh`, so keep the exact format;
- source `tests/lib.sh` after shell options; it resolves `PP`, creates the
  temporary directory, isolates `HOME`, and initializes assertions;
- use a scratch project and scratch store for external tools or filesystem
  tests; never mutate a developer's checkout.

## Standing gates

These suites attach an obligation to the build:

- `tests/072-law-pins.sh` checks that every SPEC law marked `holds` has a
  matching test marker or an explicit pending entry, and rejects stale law
  ids;
- `tests/089-state-inventory.sh` rejects deleted implementation trees,
  generated images, and stale build metadata;
- `tests/092-dependency-boundaries.sh` checks the saved-image boundary and
  absence of removed native build metadata;
- `tests/094-architecture-gates.sh` runs the architecture checks in a
  controlled temporary copy;
- `tests/071-kernel-props.sh` and `tests/075-cap-props.sh` sweep hash,
  quotation, print-roundtrip, and capability algebra properties;
- `scripts/check-lisp-crash.sh` can inject a kill at each durable-write
  boundary and verify restart leaves only a clean, byte-identical store.

Run the smallest relevant shell suite while iterating, then run the complete
saved-image suite before handoff. Changes to evaluator, identity, or durable
repository code require the corresponding language, node, and store suites.

## Expected-output cases

The worker appends `# exit: N` to captured output before comparing it with the
committed expected file. A missing expected file is a failure, not an implicit
blessing. To bless a deliberately new case:

```sh
tmp=$(mktemp -d)
HOME="$tmp" bin/pp tests/NNN-name.pp >"$tmp/out" 2>&1
status=$?
{ cat "$tmp/out"; printf '\n# exit: %d\n' "$status"; } \
  > tests/NNN-name.pp.expected
rm -rf "$tmp"
```

Review the output and source before committing a blessing. Diagnostics and
source ranges are part of the observable contract.

## Focused commands

```sh
bin/pp --version
bin/pp -e '1 + 2'
scripts/check-architecture.sh
scripts/run-tests.sh bin/pp
scripts/check-lisp-crash.sh --binary bin/pp
```

The crash checker is intentionally separate because it starts and kills
multiple processes. It is a release and store-safety check, not a replacement
for the ordinary suite.
