import { checkExpectations, importBundle } from "./lab.ts";
import { VirtualNetwork } from "./network.ts";
import { canonicalScenario, decodeScenario, durationUs } from "./scenario.ts";

const base = `scenario v1 {
  seed: 42,
  program: { file: "build.pp", argv: ["out"] },
  hosts: { control: { cores: 4, store: cold }, worker: { cores: 8, store: cold } },
  links: [{ id: work, from: control, to: worker, latency: "20ms", bandwidth: "100mbit", loss: "0%" }],
  grants: [], actions: [], expect: [{ eventually: { event: "network.response" } }]
}`;

const assertEquals = (actual: unknown, expected: unknown): void => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
};
const assertThrows = (f: () => unknown, includes: string): void => {
  try { f(); } catch (error) { if ((error as Error).message.includes(includes)) return; throw error; }
  throw new Error("expected function to throw");
};

Deno.test("scenario decoding is closed and canonical", () => {
  const scenario = decodeScenario(base); assertEquals(scenario.seed, 42); assertEquals(scenario.links[0]?.latencyUs, 20_000);
  assertEquals(decodeScenario(canonicalScenario(scenario)), scenario);
  assertThrows(() => decodeScenario(base.replace("seed: 42", "seed: 42, mystery: true")), "unknown");
  assertEquals(durationUs("2s"), 2_000_000);
});

Deno.test("virtual transfers are deterministic", () => {
  const scenario = decodeScenario(base); const first = new VirtualNetwork(scenario).transfer("work", 1000);
  const second = new VirtualNetwork(scenario).transfer("work", 1000);
  assertEquals(first, second); assertEquals(first.status, "delivered");
  assertEquals(checkExpectations(scenario.expect, [], first.events)[0]?.passed, true);
});

Deno.test("partitions cause deterministic fallback", () => {
  const text = base.replace("actions: []", 'actions: [{ at: "0ms", partition: work }]');
  const result = new VirtualNetwork(decodeScenario(text)).transfer("work", 1000);
  assertEquals(result.status, "fallback"); assertEquals(result.attempts, 3);
});

Deno.test("loss, corruption, and heal exercise retry and verification", () => {
  const loss = decodeScenario(base.replace('loss: "0%"', 'loss: "100%"'));
  assertEquals(new VirtualNetwork(loss).transfer("work", 1000).status, "fallback");
  const corruption = decodeScenario(base.replace('loss: "0%"', 'loss: "0%", corruption: "100%"'));
  assertEquals(new VirtualNetwork(corruption).transfer("work", 1000).events.filter((event) => event.kind === "network.corruption_detected").length, 3);
  const healed = decodeScenario(base.replace("actions: []", 'actions: [{ at: "0ms", partition: work }, { at: "25ms", heal: work }]'));
  const result = new VirtualNetwork(healed).transfer("work", 1000);
  assertEquals(result.status, "delivered"); assertEquals(result.attempts, 2);
});

Deno.test("bundle decoder rejects incompatible versions", () => {
  assertThrows(() => importBundle('{"bundle_version":2}'), "unsupported");
});
