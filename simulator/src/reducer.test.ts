import { decodeJsonl, type PpEvent } from "./event.ts";
import { filterEvents, Replay } from "./reducer.ts";

const equal = (actual: unknown, expected: unknown): void => {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
};
const assert: (condition: unknown, message?: string) => asserts condition = (condition, message = "assertion failed") => {
  if (!condition) throw new Error(message);
};
const throws = (body: () => unknown, pattern: RegExp): void => {
  try { body(); } catch (error) { assert(pattern.test((error as Error).message)); return; }
  throw new Error("expected function to throw");
};

const event = (id: number, kind: PpEvent["kind"], category: PpEvent["category"], phase: PpEvent["phase"], payload = {}, parent: number | null = null) => JSON.stringify({
  schema_version: 1, run_id: "run-test", event_id: id, parent_event_id: parent,
  host_id: "local", logical_time: id, wall_time_ns: null, category, kind, phase,
  visibility: "public", payload
});
const recording = decodeJsonl([
  event(1, "run.created", "run", "instant"),
  event(2, "run.started", "run", "started"),
  event(3, "cache.miss", "cache", "instant", { cache_key: "abc", reason: "no_stored_trace" }),
  event(4, "node.rebuild", "node", "started", { node_key: "abc" }),
  event(5, "node.rebuild", "node", "finished", { node_key: "abc", result_hash: "def" }, 4),
  event(6, "run.finished", "run", "finished")
].join("\n"));

Deno.test("seek equals straight replay across checkpoints", () => {
  const replay = new Replay(recording, 2);
  const end = replay.seek(6);
  equal(end.runStatus, "finished");
  equal(end.nodes.get("abc"), { key: "abc", host: "local", status: "finished", cache: "miss", resultHash: "def" });
  equal(replay.seek(3), new Replay(recording).seek(3));
});

Deno.test("filters and causal inspection use stable event ids", () => {
  equal(filterEvents(recording, new Set(["node"]), "def").map((item) => item.event_id), [5]);
  equal(new Replay(recording).causalChain(5).map((item) => item.event_id), [4, 5]);
});

Deno.test("decoder rejects unknown schemas, kinds, and order", () => {
  throws(() => decodeJsonl(event(2, "run.created", "run", "instant")), /non-contiguous/);
  throws(() => decodeJsonl(event(1, "bogus" as PpEvent["kind"], "run", "instant")), /invalid pp event/);
});

Deno.test("recorded local build fixture reaches a completed rebuilt node", () => {
  const fixture = decodeJsonl(Deno.readTextFileSync("fixtures/local-build.jsonl"));
  const state = new Replay(fixture).seek(fixture.length);
  equal(state.runStatus, "finished");
  equal(state.nodes.size, 1);
  equal(state.nodes.first()?.status, "finished");
});

Deno.test("checkpoint seek stays bounded on a million-event recording", { sanitizeResources: true }, () => {
  const base = recording[0]!;
  const events = Array.from({ length: 1_000_000 }, (_, index): PpEvent => ({
    ...base, event_id: index + 1, logical_time: index + 1
  }));
  const replay = new Replay(events, 2_000);
  const before = performance.now();
  equal(replay.seek(events.length).cursor, events.length);
  const firstSeek = performance.now() - before;
  const cachedBefore = performance.now();
  replay.seek(events.length - 1);
  assert(performance.now() - cachedBefore < 250, "cached seek exceeded 250 ms");
  assert(firstSeek < 10_000, "initial million-event reduction exceeded 10 seconds");
});
