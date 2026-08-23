# pp network simulator plan

Status: approved implementation plan. Delete this file when the work is
complete; durable facts belong in the architecture, specification, tests,
and history.

## 1. Product statement

Build a GNS3-style laboratory for pp in which a user can:

- write or load any pp program and run it through the real reader, macro
  expander, evaluator, node runtime, scheduler, store, transport, and
  reconciler;
- arrange hosts, links, stores, files, processes, domains, and external
  services on a canvas;
- watch evaluation, node forcing, cache verification, builds, artifact
  movement, capability decisions, failures, retries, and reconciliation as a
  time-ordered animation;
- pause, step, seek, filter, inspect causality, compare runs, and ask why an
  event occurred;
- introduce deterministic latency, bandwidth limits, loss, partitions,
  corruption, crashes, drift, and load;
- run the same scenario headlessly in CI and at scale, with machine-readable
  assertions and performance results.

The simulator is not another pp evaluator. The native runtime remains the
semantic authority. Simulation changes placement, time, transport, and the
modeled world; it does not change language meaning.

### 1.1 v1 priorities

Decision: teaching/debugging and protocol development are co-equal,
release-blocking v1 purposes.

- Teaching/debugging makes pp concrete: a user can follow a real program from
  source through identity, traces, cache decisions, placement, artifacts, and
  reconciliation, then inspect the causal answer to “why?”.
- Protocol development makes the simulator dogfoodable: pp developers can
  construct deterministic distributed failures, inspect the real protocol,
  retain a replayable case, and turn it into a regression test.

A feature is not v1-complete if it only produces an attractive animation or
only exposes low-level protocol events. The same recording must support a
progressive explanation: an approachable semantic story by default and exact
protocol evidence on demand.

The performance laboratory remains required, but it does not gate v1.
Deterministic-lab measurements describe simulated behavior; trustworthy OS,
socket, disk, scheduler, and resource claims wait for the live stress suite.

## 2. What exists at the branch point

The branch starts from the current saved-image implementation.

- pp has one Common Lisp tree-walking evaluator and one persistent-node path.
- the runtime classifies first-build, stale, unauthorized, successful, and
  failed-trace outcomes, and exposes them through `pp why`;
- durable traces expose the cell-to-node graph used by inspection;
- the scheduler supports serial, local process parallelism, racing, and
  remote placement;
- remote placement uses typed cache, token, and artifact boundaries, but
  today's member transport is a local-directory/command seam rather than a
  general network fabric;
- domains implement observe, diff, apply, and verify; watch mode adds
  stabilization and repeated passes;
- the website is the generated static Typst reference manual. There is no
  interactive application stack to extend.

These facts rule out deriving animation from log scraping and rule out a
browser-only mock as the primary simulator.

## 3. Non-negotiable properties

### 3.1 Semantic fidelity

Every successful simulated run has the same result hash and desired-state
hash as the corresponding ordinary run when the modeled world and grants are
the same. Instrumentation is observational: disabling it cannot alter keys,
traces, scheduling outcomes, capabilities, or persistent store bytes.

### 3.2 One event vocabulary

Live execution, recorded replay, CLI inspection, browser rendering, and tests
consume one versioned event model. Human text is a projection of typed
events, never the interchange format.

### 3.3 Text-first operation

Everything visible or controllable in the UI has a headless equivalent:

- scenarios are reviewable text files;
- event recordings are canonical JSON Lines;
- snapshots and summaries are deterministic text;
- assertions address stable event ids and semantic ids, not pixels;
- browser tests consume the same recordings as CLI tests;
- a failed visual test retains the scenario, event log, reducer state, and
  optional screenshot.

This is the primary agent interface and the foundation for reproducible bug
reports.

### 3.4 Bounded observation

Event collection is off by default and has explicit detail, sampling, and
retention policies. Stress runs must not require rendering or retaining every
event. Secrets and unauthorized cell identities follow the same redaction
rules as `pp why`; raw capability tokens and secret bytes never enter events.

### 3.6 v1 capacity targets

Decision: accepted.

| Tier | Hosts | Semantic graph | Recording | Required behavior |
|---|---:|---:|---:|---|
| teaching | 8 | 1,000 nodes / 4,000 edges | 100,000 events | smooth animation, labels and links visible, instant ordinary inspection |
| protocol debugging | 32 | 10,000 nodes / 40,000 edges | 1,000,000 events | responsive filtered/collapsed view, seek and causal queries under 250 ms |
| headless regression | 256 | 100,000 nodes / 400,000 edges | 10,000,000 events | no rendering requirement; bounded memory via streaming and aggregation |

The controller accepts 10,000 semantic events/second in the initial live
target. The UI may batch presentation by animation frame. Artifact size and
run duration do not inflate recordings because events retain hashes, byte
counts, and summaries rather than artifact bytes.

These are acceptance budgets, verified with generated fixtures and recorded
with hardware/browser metadata. They do not assert that pp's live network can
sustain the same topology or event scale before the live stress milestone.

### 3.5 Erasure and ownership

Existing `pp why` and graph logic should become projections over shared typed
data rather than parallel implementations. When the structured replacement
is complete, obsolete formatting and test seams are removed. The simulator
must not introduce a second store, node-key algorithm, evaluator, or domain
engine.

## 4. Truth model: real runtime plus controlled world and transport

Decision: accepted.

Run the real pp pipeline. Add typed observation at semantic boundaries and
inject implementations only at existing host-service, scheduler, world, and
transport seams. Use a deterministic virtual clock and network for repeatable
labs, and a socket/process transport for integration and stress runs.

A mock pp evaluator is excluded because it would duplicate and drift from
language semantics. Wall-clock execution remains a live mode, not the only
mode, because deterministic replay and fault injection are required.

This yields three modes over the same scenario and event vocabulary:

| Mode | Runtime | World/transport | Purpose |
|---|---|---|---|
| replay | none | recorded | UI development, debugging, documentation |
| browser lab | shared pp evaluator compiled for the browser | modeled clock/network/world | public playground and teaching |
| deterministic lab | native pp | modeled clock/network/world | CI and fault scenarios |
| live lab | real pp processes | real sockets/files/processes with optional proxy impairments | fidelity and stress |

## 5. System boundaries

```text
scenario.ppsim
      |
      v
scenario decoder ---> lab controller ---> host processes / virtual hosts
                           |                       |
                           |                  real pp runtime
                           |                       |
                           +<--- control ---------+
                           +<--- typed events -----+
                           |
                    append-only recording
                           |
              +------------+-------------+
              |                          |
       CLI reducer/report           web reducer/view
```

The event producer does not know about JSON, WebSockets, graph layout, or UI
state. It calls a narrow sink. Encoding and delivery live at the app edge.
The web app never edits pp runtime state directly; it sends controller
commands such as run, pause, step, inject fault, or change scenario.

## 6. Scenario model: data-only `.ppsim`

Decision: accepted.

Use a small, versioned, declarative text format decoded by the lab controller.
It may use pp's brace lexical conventions, but it is configuration, not a new
pp expression form. It references ordinary `.pp`/`.ppl` entrypoints.

Simulator forms do not enter the pp language: location remains a scheduler
concern. Generic JSON/YAML is not the primary authoring format. Import/export
can be added later if an integration requires it.

Illustrative shape, not final syntax:

```text
scenario v1 {
  seed: 42,
  program: { file: "build.pp", argv: ["out"] },
  hosts: {
    control: { cores: 4, store: "cold" },
    worker:  { cores: 8, store: "cold" }
  },
  links: [
    { from: control, to: worker, latency: "20ms", bandwidth: "100mbit",
      loss: "0%" }
  ],
  grants: ["fs:fixtures:ro", "process"],
  actions: [
    { at: "2s", partition: [control, worker] },
    { after: "node:compile-a:done", restore_link: [control, worker] }
  ],
  expect: [
    { eventually: { event: "run.finished", status: "ok" } },
    { count: { event: "node.rebuild.started", max: 8 } }
  ]
}
```

Before implementation, specify schema evolution, durations/rates, path
resolution, host identity, seeded randomness, action ordering at equal
timestamps, and assertion semantics. Unknown fields fail closed.

### 6.1 v1 generation boundary

Decision: `.ppsim` is finite, declarative, and non-programmable. Every host,
link, fault, and assertion in a consumed scenario is explicit.

Parameterized scale workloads come from a separate seeded headless generator.
Its output is a canonical expanded `.ppsim` artifact, and the generator name,
parameters, seed, and version are recorded with it. Replay consumes the
expanded artifact, not the generator. Do not add templates, loops, scope, or
expressions to `.ppsim`; consider a compact data-level repetition form only
after real scenarios demonstrate unavoidable authoring duplication.

## 7. Event model

### 7.1 Envelope

Every event has:

- schema version;
- run id, event id, parent/causal event id, and host id;
- logical timestamp and optional monotonic wall timestamp;
- category, kind, lifecycle phase, and typed payload;
- stable semantic references where available: node key, cache key, result
  hash, cell id, trace id, domain name, pass id, job id, process id, transfer
  id, and link id;
- visibility/redaction classification.

Event ids are unique within a run. Logical order is deterministic in replay
and deterministic-lab modes. Causality is explicit because timestamp order
alone cannot explain concurrent execution.

### 7.2 Required event families

| Family | Minimum events |
|---|---|
| run | created, configured, started, paused, resumed, finished, failed |
| source | read, parsed, macro-expanded, load/island resolved, error |
| evaluation | expression entered/exited at selectable detail, function applied, thunk forced, effect performed/handled |
| identity | node key computed, value/result hash computed |
| cache | lookup, trace considered, cell verified/stale/unobservable/unauthorized, hit, miss, failure replay |
| node | queued, dispatched, rebuild started/finished/failed, child dependency recorded, cutoff |
| scheduler | handler selected, batch formed, worker spawned/exited/cancelled, race won, fallback |
| store | object/blob/trace read, verified, written, transferred, rejected, marked, collected |
| capability | grant/restrict/check allowed/denied, token minted/verified/expired; always redacted |
| network | connection, request, response, bytes/chunks, latency queue, drop, retry, timeout, corruption detection |
| process | spawn, stdout/stderr summary, exit, kill; payload retention configurable |
| domain | registered, observe, diff, plan hit/miss, apply, verify, drift, stratification failure |
| reconcile | pass started/finished, target planned/applied/verified, fenced intent/done/recovery |
| watch | poll, changed cells, reverse-index traversal, thunk dirtied, stabilization |
| fault | scheduled, injected, cleared, affected operation |
| metric | queue depth, throughput, cache rate, bytes, CPU, memory, store size, event drops |

“Full language coverage” means every surface program runs through the real
frontend/evaluator. It does not mean always emitting an event for every AST
node. Expression-level detail is an opt-in diagnostic level; semantic
boundary events are always sufficient to explain cache, build, distribution,
and reconciliation behavior.

### 7.3 Event levels

- `summary`: run, pass, aggregate metric, and failure events;
- `semantic`: node/cache/scheduler/store/network/domain events (default);
- `evaluation`: expression/thunk/effect detail;
- `transport`: chunk/frame detail for protocol diagnosis.

Filtering happens before allocation where practical. A bounded sink reports
its own dropped-event count rather than silently losing fidelity.

### 7.4 Encoding

Canonical JSON Lines is the first public recording format because it is
streamable, diffable, and easy for agents and browser tooling. The in-process
OCaml type is authoritative. Golden codec tests pin every constructor and
redaction rule. Large binary content is referenced by hash and length, never
embedded. A future compact binary transport may wrap the same schema after
profiling proves JSON is a bottleneck.

### 7.5 v1 recording policy

Decision: accepted.

- The default `semantic` level records complete node, cache, scheduler, store,
  network, process, domain, reconciliation, watch, fault, and aggregate metric
  events. Expression evaluation and transport-frame detail are selected before
  a run.
- The controller writes the selected stream to temporary canonical JSONL. The
  browser holds a bounded window, indexes, and reducer checkpoints and fetches
  ranges for seeking.
- Temporary recordings remain until controller exit. Saving exports a
  portable bundle; discarding removes the temporary recording. A controller
  crash leaves a clearly named incomplete recording.
- Process stdout and stderr retain byte counts, hashes, and a capped 64 KiB
  preview per stream by default. Full output capture is opt-in. Binary
  artifacts are never embedded in events.
- Redaction occurs before the event sink. Secret bytes, raw tokens,
  unauthorized cell identities, and unapproved paths cannot enter any detail
  level.
- A portable bundle contains a versioned manifest, canonical expanded
  `.ppsim`, approved source snapshot, event JSONL, assertion results, metric
  summary, and reproduction metadata. Reducer checkpoints and indexes are
  disposable and rebuilt on import.
- Store objects and blobs are excluded by default. Explicit public-artifact
  export may add hash-verified non-secret artifacts. Tokens, cluster secrets,
  controller credentials, and sealed bytes are never exportable.

### 7.6 reproducibility boundary

Decision: accepted.

Deterministic-lab mode fixes scenario decoding, initial world, virtual time,
network delay/queue/loss/corruption decisions, fault ordering, generated
logical ids, and seeded randomness. Given the same version and inputs it must
produce identical pp semantic results, cache decisions, protocol outcomes,
causal graph, assertions, and metrics derived solely from the modeled world.
Fault triggers use logical time or causal events rather than sleeps.

Independent concurrent actions need not produce a byte-identical total event
order. Events carry a deterministic causal partial order; canonical diffs and
golden summaries use a stable topological ordering. A scenario that requires
ordering introduces an explicit dependency.

Live loopback mode records but does not stabilize wall time, OS scheduling,
PIDs, ports, native process duration or nondeterministic output, CPU/memory
samples, filesystem races outside modeled cells, or completion order between
causally independent work. Such fields are marked `live`, excluded from
canonical diffs, and unavailable to deterministic assertions unless the
assertion explicitly opts into live data.

Replay reproduces its recording without re-executing pp. Native tool results
are real observations when executed; deterministic-lab scenarios may instead
model the tool boundary.

## 8. Instrumentation seams

Add one runtime-owned `Event_sink` abstraction with a no-op default. Pass it
through constructed services/session state rather than a mutable global.
Instrument ownership boundaries, not incidental function bodies:

- frontend/app boundary for source and macro expansion;
- evaluator dispatch only for optional evaluation detail;
- `Node.force`/rebuild and `Cache_policy.lookup` for node/cache truth;
- observation and trace repositories for cell/trace truth;
- scheduler dispatch/reap/cancel for placement and concurrency;
- transport/remote protocol for requests and artifacts;
- process boundary for builds and subprocesses;
- domains/reconciliation/stabilization for desired-state loops;
- store repositories/GC for persistence.

The first refactor extracts the cache decision structure currently implicit in
`Cache_policy.lookup`; `pp why` formats those decisions. Likewise, graph data
becomes a typed query and `pp graph` remains a text formatter. This replaces
duplicated observability rather than layering more print statements on it.

## 9. Network realism: common protocol over virtual and real transports

Decision: accepted.

Preserve the current typed `Remote_protocol` and hash/capability validation.
Define a transport interface that supports request/response streaming,
cancellation, deadlines, and transfer accounting. Implement:

- deterministic in-process virtual links for repeatable scenarios;
- loopback socket transport for integration tests;
- multi-process TCP transport with authenticated cluster messages for live
  labs;
- a fault/traffic-shaping layer shared by virtual and socket transports.

The production security protocol needs its own threat-model amendment before
internet exposure. The lab UI binds to loopback by default and must not turn
internal commands into an unauthenticated remote execution API.

The existing local-directory seam may support an intermediate test, but an
animation of that seam alone does not satisfy the network requirement.

### 9.1 v1 network boundary

Decision: deterministic virtual links plus real loopback sockets and
processes on one physical machine. Multi-machine execution is post-v1.

V1 exercises the real protocol's framing, streaming, cancellation, deadlines,
backpressure, capability tokens, artifact verification, worker crashes, and
reconnects without accepting remote connections. The controller and live
transport bind to loopback. Remote binding, discovery, authentication
deployment, secret distribution, hostile-network hardening, and firewall
behavior remain in the live multi-machine milestone.

### 9.2 Link model

Each directed link has latency distribution, jitter, bandwidth, queue limit,
loss, duplication, reordering, corruption, availability schedule, and seeded
random stream. Routing is explicit in v1; dynamic routing is out of scope
unless a real pp requirement emerges.

Transfer time is derived from bytes and bandwidth. Queueing is observable.
Corruption occurs below hash verification so pp's existing integrity checks
remain the oracle. Partitions and crashes have explicit start/end events.

### 9.3 Stress model

Separate runtime stress from renderer stress:

- controller can run with no UI and aggregate metrics only;
- event sinks support sampling and bounded buffers;
- workload generators create parameterized pp DAGs, artifacts, cells,
  members, and churn from a seed;
- scale axes include hosts, node fan-out/depth, trace count, artifact bytes,
  concurrent transfers, cache warmth, invalidation rate, reconciliation
  targets, and fault rate;
- output includes throughput, latency percentiles, hit/miss reasons, transfer
  bytes, redundant computation, queue occupancy, convergence time, memory,
  CPU, store growth, and event overhead;
- every benchmark records commit, binary version, scenario hash, seed,
  machine metadata, event level, and warm/cold state.

Do not claim a stress result from deterministic virtual time alone. Protocol
and algorithmic scaling use virtual mode; scheduler, OS, socket, disk, and
resource results use live mode.

## 10. Web application

### 10.1 User experience

The visual language deliberately follows GNS3: a restrained desktop-tool
layout, plain panels and toolbars, a large functional canvas, conventional
network symbols, compact status indicators, and dense inspectable detail.
Avoid decorative cards, gradients, oversized type, ornamental motion, and
dashboard chrome. Aesthetics serve topology legibility and causal debugging.

The application has four coordinated regions:

1. topology canvas: hosts, links, external systems, stores, and grouped pp
   nodes;
2. source/scenario editor: ordinary pp source plus `.ppsim`, diagnostics,
   run controls, and saved examples;
3. time view: play/pause/step/speed/seek, lanes by host, filters, bookmarks,
   and fault markers;
4. inspector: selected entity state, causal chain, cache decision, trace
   cells, capabilities/redaction, artifacts, metrics, and raw event JSON.

Color never carries meaning alone. Animation can be disabled. Large graphs
collapse by host, build phase, node-key prefix, domain, or event family.
The default view shows semantic events, not every evaluator step.

### 10.2 Topology interaction

Decision: manual placement and explicit automatic layout.

- Users place hosts, links, stores, and external systems directly; coordinates
  persist as presentation data in `.ppsim` but do not affect simulation
  semantics, scenario identity, or event results.
- Auto-layout is an explicit command for new, imported, and generated
  topologies. It never continuously rearranges a diagram during a run.
- Runtime computation nodes use deterministic grouped layout within or beside
  their host. Large groups collapse instead of requiring manual placement of
  every computation node.
- Resetting layout removes presentation coordinates and recomputes them. A
  scenario with presentation data stripped remains semantically equivalent.

### 10.3 Reconciliation views

Decision: coordinated host-centric and domain-centric projections over one
reducer state.

- The topology overlays desired and observed resources, drift, pending plans,
  applies, verification, fenced actions, and watch invalidations on each host.
- The reconciliation panel shows every observe → diff/plan → apply → verify
  pass by domain and target, including plan-cache hits, no-ops, failures,
  recovery, and stratification errors.
- Selection and time focus are shared across topology, panel, inspector, and
  timeline. Reconciliation lanes highlight affected hosts and resources.
- Generic domains expose declared names, targets, summaries, and observed
  cells. The UI does not hard-code filesystem or process semantics; optional
  renderers may enrich known payloads later.

### 10.4 Reactive state shape

Use a pure reducer:

```text
(scenario snapshot, event cursor, event) -> scenario snapshot
```

Live input appends to an immutable recording; seeking restores a checkpoint
and replays forward. Selection, viewport, filters, and playback are local UI
state, separate from semantic state. All reducers run headlessly against
fixtures. The browser renderer is a projection of reducer state.

### 10.5 UI technology

Decision: TypeScript. Do not build competing frontend prototypes.

Use standard browser tooling directly for graph rendering, editing, streaming,
and browser tests while keeping pp's native OCaml dependencies isolated.
Generate TypeScript event types and runtime decoders from the authoritative
OCaml schema; do not maintain parallel handwritten models. The pure reducer
contract remains language-neutral and is tested with shared canonical
fixtures.

The exact reactive view library is an implementation choice constrained to a
small replaceable shell around the reducer. It must not own semantic state.
Choose it during the first UI implementation from build simplicity,
accessibility, maintained TypeScript support, and compatibility with static
GitHub Pages output.

The TypeScript frontend does not implement pp semantics. The portable OCaml
frontend/evaluator is compiled separately for the browser and called through a
small generated interface. TypeScript owns application presentation and the
event reducer; OCaml owns pp parsing, evaluation, identity, traces, and
simulation behavior.

For the canvas, evaluate a graph library rather than hand-writing layout.
Cytoscape.js is a candidate because it supports headless graph analysis and
documents concrete large-graph performance tradeoffs. It is not selected
until the first UI implementation tests compound hosts, many edges,
incremental updates, and layout stability.

Current primary graph reference:

- [Cytoscape.js documentation](https://js.cytoscape.org/)

### 10.6 Website integration

Keep the generated manual and simulator application as separate build
artifacts under one site shell. The manual build should not acquire the UI's
npm/OCaml-browser dependency graph. Add a visible “Simulator” link to the
manual and a “Manual” link to the app.

Decision: deploy the manual and an executable browser playground with GitHub
Pages.

The hosted playground edits `.pp`, `.ppl`, and `.ppsim`; runs the shared real
pp reader, macro expander, evaluator, identity/cache/trace logic, virtual
network, and reconciler compiled for the browser; and emits the same event
schema as native modes. It needs no local controller or credentials.

Browser host services are explicitly virtual. The playground cannot launch
native tools, inspect the user's real filesystem, or open arbitrary raw
sockets. Process, filesystem, clock, and network effects use declared virtual
implementations or report a clear unavailable-effect error. The UI labels the
mode and never presents a modeled compiler or network result as a live
measurement.

`pp sim` serves the same content-hashed frontend locally and adds native host
services, real loopback processes/sockets, and the fixed workspace/grant
boundary. Saved scenarios and recordings move between hosted and local modes;
a scenario declares required host services so incompatibility is known before
run.

GitHub Actions builds one Pages artifact containing the manual, TypeScript
application, portable pp runtime, and versioned examples without committing
generated bundles to the source tree.

### 10.7 Portable pp runtime

Decision: the browser target shares the pp semantic implementation; it is not
a JavaScript reimplementation or reduced grammar.

Refactor browser-compatible runtime ownership away from Unix adapters without
creating a second evaluator path. Kernel and frontend already have no Unix
dependency. The portable slice must include both readers, macro expansion,
the sole evaluator, values/types, capabilities, node identity, in-memory
objects/traces/cache, domains, reconciliation, stabilization, and the virtual
scheduler/world/transport.

Native-only adapters retain real files, processes, stores, fork scheduling,
and sockets. Compile the portable OCaml entrypoint with js_of_ocaml first;
its supported effect-handler transformation matches pp's OCaml 5 effects.
wasm_of_ocaml remains a later optimization only if profiling justifies another
artifact. Missing browser primitives fail the build or return a typed
unavailable-host-service result; they never silently fall back to different
semantics.

Parity gates run the existing language corpus and generated semantic cases
through native and browser targets, comparing results, errors, hashes, cache
decisions, and canonical events. Native-only effect cases assert the explicit
boundary instead of being skipped invisibly.

### 10.8 v1 trust boundary

Decision: local, single-user, loopback-only, and session-authenticated.

The hosted playground has no native controller connection and therefore needs
no native execution credential. Starting the local controller creates an
ephemeral high-entropy session token and opens its same-origin local app with
a one-time bootstrap fragment. The app exchanges it for an in-memory session
and removes it from browser history. Every command and event connection
requires that session.

There are no accounts, roles, collaboration semantics, remote binding, or
durable credentials in v1. This boundary prevents an unrelated webpage from
driving native pp through a localhost listener. Multi-user and remote
authentication are post-v1.

### 10.9 v1 execution boundary

Decision: native execution of trusted code with pp capabilities and explicit
controller scope. V1 is not a hostile-code sandbox.

- The controller is started with one canonical workspace root and cannot
  switch roots during its session.
- Scenario grants are normalized and shown for approval before the first live
  run. Any widening requires approval again.
- Process authority is separate and conspicuous because native tools execute
  with the user's OS identity; the UI never adds it implicitly.
- Paths outside the workspace are rejected unless the controller was started
  with an explicit additional root.
- Deterministic virtual effects replace real external effects only where the
  scenario declares them. Virtual mode does not claim to contain native
  process effects.

A container or OS-namespace runner may later be a selectable backend. It does
not replace native execution, whose parity with ordinary pp is part of v1.

### 10.10 v1 browser boundary

Decision: accepted.

- Desktop Chromium and Firefox current and previous major versions are
  release-blocking for playground, replay, and the local controller UI.
- Safari works where the portable runtime and required standards pass, but is
  not release-blocking until automated coverage exists. Do not add a separate
  Safari controller path.
- Mobile supports the manual, small examples, and recording inspection;
  topology authoring and large simulations target desktop pointer/keyboard
  interaction.
- V1 has no installable PWA or service-worker cache. Pages requires a network
  load; controller-served assets are the guaranteed offline mode.
- One content-hashed frontend/runtime artifact feeds Pages, the controller,
  and browser tests. Bundles record schema/runtime versions and reject
  incompatible imports with an actionable migration error.

## 11. Control protocol

The controller serves static app assets and a loopback API:

- create/load/validate scenario;
- start, pause, resume, step, stop, and reset run;
- subscribe from event id with backpressure;
- fetch recording ranges/checkpoints and aggregate metrics;
- inject/clear declared faults;
- inspect redacted objects, traces, and source locations;
- export/import a portable run bundle.

Prefer HTTP for commands and WebSocket for ordered live events unless the UI
implementation demonstrates a simpler transport. Commands carry request ids and return
accepted/rejected events; the UI does not assume success before acknowledgement.
Reconnect resumes from the last event id.

The controller executes only scenario-declared entrypoints inside a selected
workspace and explicit grants. Default binding is loopback. Remote access,
authentication, CSRF, origin policy, resource quotas, and multi-user isolation
are a separate security milestone, not implicit v1 behavior.

## 12. Testing strategy

### 12.1 Contract and unit tests

- event constructors, canonical encoding/decoding, schema rejection, and
  redaction;
- pure reducer transitions, causal indexing, checkpoint/seek equivalence,
  filters, aggregation, and out-of-order rejection;
- scenario decoder, canonicalization, seeded action order, and assertions;
- virtual clock, link queues, bandwidth arithmetic, loss/corruption seeds,
  partitions, cancellation, and deadlines;
- transport conformance: local-directory compatibility, virtual, loopback,
  and socket implementations pass the same suite.

### 12.2 Semantic parity

For the complete existing language corpus and metamorphic fuzzer:

- instrumentation off versus semantic events versus evaluation events yields
  identical stdout/stderr contract, exit status, result hashes, desired-state
  hashes, and store artifacts;
- serial, parallel, race, virtual-remote, and live-remote preserve schedule
  transparency where the specification requires it;
- both `.pp` and `.ppl`, macros, modules, islands, effects/handlers, config,
  types, errors, all values, persistent and volatile nodes, probes, domains,
  fenced recovery, watch, and GC have at least one event fixture.

This is the full-language coverage matrix; generate it from the normative
surface/law tables where possible so additions cannot silently escape.

### 12.3 Golden scenarios

Minimum scenarios:

1. cold build, warm build, one source edit, revert to an older trace;
2. unauthorized cached result, then sufficient authority, with redaction;
3. local parallel build and race winner/cancellation;
4. remote cold build, cross-member hit, unreachable-member local fallback;
5. latency/bandwidth queue, loss/retry, partition/heal, corrupted artifact;
6. worker crash during rebuild and during transfer;
7. filesystem/process reconciliation, no-op pass, drift, verify failure;
8. watch stabilization with precise reverse-index invalidation;
9. fenced intent, crash, and each recovery policy;
10. failing trace replay and invalidation;
11. secret rotation without secret disclosure;
12. store GC with live and unreachable artifacts;
13. mixed `.pp`/`.ppl`, macro, island, module, handler, probe, and volatile
    node coverage.

Each fixture contains scenario text, pp source, canonical events or semantic
summary, assertions, and a reducer snapshot. UI end-to-end tests reuse these
fixtures rather than building private browser-only worlds.

### 12.4 UI tests

- component/reducer tests without a browser;
- browser tests for canvas selection, keyboard control, playback, seek,
  filters, inspector causality, responsive layout, and reconnect;
- accessibility checks and reduced-motion behavior;
- screenshot tests only for a few stable layouts, never as the semantic
  oracle;
- performance budgets at 1k, 10k, and 100k visible/recorded node-event scales,
  with aggregation expected at the largest scale.

### 12.5 Stress and soak gates

- deterministic seeded matrix in ordinary CI;
- bounded nightly/opt-in live socket stress;
- long-running reconcile/watch soak with churn and partitions;
- event-disabled baseline versus each event level to quantify overhead;
- leak checks for controller buffers, browser state, worker processes,
  temporary sandboxes, sockets, and store growth.

After changes to evaluator, core types, or store code, run the repository's
required full fuzzer and suite. Each milestone also runs architecture gates
and the smallest relevant existing tests, especially `009` and `010`–`024`
for identity/store/trace changes and `038`, `045`, `047`–`052` for scheduling,
network, cluster, and reconciliation behavior.

## 13. Delivery sequence and exit gates

Milestones 1–6 collectively define public v1. Development previews may deploy
earlier but are visibly marked and carry no v1 compatibility promise.
Milestone 7 is post-v1: remote multi-machine transport and trustworthy live
network performance work do not block the accepted single-machine release.

### Milestone 1: typed observability, no web UI

- event type, sink, levels, redaction, JSONL codec;
- structured cache decisions and graph query;
- semantic events for one local cold/warm/invalidate build;
- `pp simulate --record` (working name) or equivalent headless command;
- parity and overhead tests.

Exit: the recording alone explains every hit/miss/rebuild in the slice;
`pp why` and `pp graph` use the shared structured source; normal execution is
unchanged.

### Milestone 2: deterministic replay UI

- pure reducer, checkpoints, playback, seek, filters, inspector;
- topology canvas with the recorded local build;
- TypeScript frontend with generated event types and decoders;
- GNS3-style shell built as static GitHub Pages assets.

Exit: the frontend meets agreed performance and testability budgets without
duplicating the semantic model.

### Milestone 3: executable browser playground

- portable runtime boundary and browser host-service implementations;
- js_of_ocaml build of the shared frontend/evaluator;
- source/scenario editor, diagnostics, examples, and in-browser execution;
- native/browser parity matrix and unavailable-host-service tests;
- GitHub Pages artifact and deployment smoke test.

Exit: the public site runs the initial vertical slice through the actual pp
semantic implementation using virtual services, and every language form has
a native/browser parity case.

### Milestone 4: controller and live local execution

- loopback controller, command acknowledgements, streaming/backpressure,
  reconnect, portable run bundle;
- source/scenario diagnostics and run controls;
- end-to-end browser and CLI tests.

Exit: the same local build passes headless, replay, and live UI modes.

### Milestone 5: deterministic network lab

- `.ppsim` schema, virtual clock, virtual hosts/links, fault actions;
- remote protocol over the virtual transport;
- seeded assertions and golden network scenarios;
- aggregate metrics and headless workload generation.

Exit: partition/heal, loss/retry, corruption detection, remote fallback, and
cross-member cache hits are deterministic and replay identically. Each case
has both a plain-language causal explanation and inspectable protocol events;
the exported run bundle can become a headless regression fixture.

### Milestone 6: full coverage and v1 release hardening

- generated language/law coverage matrix is complete;
- all golden scenarios and UI accessibility/performance gates pass;
- simulator artifact integrated with the deployed site;
- manual teaches one verified scenario and links to the lab;
- remove prototypes, compatibility adapters, completed plan material, and
  obsolete observability paths.

Exit: clean build, architecture gates, 2,000-case full fuzzer, full suite,
browser suite, loopback stress smoke, and deployment smoke all pass.

### Milestone 7: post-v1 remote transport and stress

- remote-capable authenticated multi-process transport and threat-model
  update; the loopback form already exists in v1;
- traffic shaping/fault proxy at the same transport boundary;
- stress CLI, benchmark metadata, reports, soak tests;
- live topology metrics without unbounded event retention.

Exit: measured targets hold on documented hardware; failures retain a
reproducible run bundle; simulated and live protocol outcomes agree.

## 14. Initial vertical slice

Use one three-node C build derived from the existing remote-placement tests:

1. control host and two workers, initially cold;
2. compile nodes scheduled across workers over links with visible latency and
   bandwidth;
3. link result materialized on control;
4. second run shows verified trace hits and zero compiler execution;
5. edit one header, showing precise stale-cell causality and rebuild;
6. partition one worker mid-transfer, showing failure/fallback;
7. restore the link and revert the header, showing reuse of the older trace;
8. export recording, replay it, and assert result equality headlessly.

This slice touches source observation, DAG identity, builds, cache hits and
misses, scheduling, artifacts, network failure, fallback, and replay without
requiring reconciliation in the first implementation. The next slice adds a
two-host filesystem/process desired state and drift reconciliation.
