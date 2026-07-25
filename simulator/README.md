# pp simulator

The simulator has two execution paths over one event format:

- The browser playground runs the real pp evaluator in the browser and can
  execute a `.ppsim` scenario over deterministic virtual hosts and links.
  It is safe to try from the public site: filesystem, process, and network
  services are virtual or unavailable.
- The loopback controller runs a trusted workspace program through native pp.
  It is for local builds, real stores, grants, and replayable recordings.

## Browser playground

Build the static site and open `site/index.html` (or serve `site/` from a
static web server):

```sh
deno task build
python3 -m http.server --directory site 8000
```

Choose an example, edit the pp source, and use **Run source** for a single
browser run or **Run scenario** to add virtual hosts, links, latency, loss,
partitions, retries, and assertions. The default scenario shows a control
host and two workers. The timeline, topology, filters, causal inspector,
seek controls, and event export all use the same canonical event recording.

## Native local lab

The controller is loopback-only and prints a one-time session URL:

```sh
deno task controller .. 0
```

Open the printed URL, approve grants when prompted, and run a scenario against
the selected workspace program. Headless runs are useful in CI:

```sh
deno task lab validate fixtures/network.ppsim
deno task lab bundle fixtures/network.ppsim run.bundle.json
```

The native path uses real pp execution and the repository's local cluster
transport. Virtual link events describe the deterministic lab model; they do
not claim to be a physical socket benchmark.

## Checks

```sh
deno task check
```

This builds the browser runtime, regenerates event kinds, runs TypeScript and
runtime smoke tests, bundles the site, and checks the deployment artifact.
