import { decodeEvent, decodeJsonl, type PpEvent } from "./event.ts";
import { VirtualNetwork, linkMetrics, type NetworkEvent } from "./network.ts";
import { canonicalScenario, decodeScenario, type ExpectSpec, type Scenario } from "./scenario.ts";

export interface AssertionResult { readonly expectation: ExpectSpec; readonly passed: boolean; readonly actual: number }
export interface RunResult {
  readonly scenario: Scenario; readonly stdout: string; readonly stderr: string; readonly status: number;
  readonly sourceSnapshot: { readonly name: string; readonly text: string };
  readonly events: readonly PpEvent[]; readonly networkEvents: readonly NetworkEvent[];
  readonly assertions: readonly AssertionResult[]; readonly metrics: Readonly<Record<string, number | boolean>>;
}
export interface RunBundle {
  readonly bundle_version: 1; readonly scenario: string; readonly events_jsonl: string;
  readonly network_events: readonly NetworkEvent[];
  readonly source_snapshot: { readonly name: string; readonly text: string };
  readonly assertions: readonly AssertionResult[]; readonly metrics: Readonly<Record<string, number | boolean>>;
  readonly reproduction: { readonly simulator: "pp"; readonly schema: 1; readonly seed: number };
}

const eventStatus = (event: PpEvent): string | undefined => {
  const status = event.payload.status ?? event.payload.outcome;
  return typeof status === "string" ? status : undefined;
};
export function checkExpectations(expect: readonly ExpectSpec[], events: readonly PpEvent[], network: readonly NetworkEvent[]): readonly AssertionResult[] {
  return expect.map((expectation) => {
    const matching = events.filter((event) => event.kind === expectation.event &&
      (expectation.kind !== "eventually" || expectation.status === undefined || eventStatus(event) === expectation.status)).length
      + network.filter((event) => event.kind === expectation.event).length;
    return { expectation, actual: matching, passed: expectation.kind === "eventually" ? matching > 0 :
      matching >= (expectation.min ?? 0) && matching <= (expectation.max ?? Number.MAX_SAFE_INTEGER) };
  });
}

export interface RunningScenario {
  readonly completion: Promise<RunResult>;
  readonly events: () => readonly PpEvent[];
  pause(): void; resume(): void; step(): void; stop(): void;
}

export async function startScenario(text: string, pp = "pp", programFile?: string, onEvent?: (event: PpEvent) => void): Promise<RunningScenario> {
  const scenario = decodeScenario(text);
  const sourcePath = programFile ?? scenario.program.file;
  const sourceSnapshot = { name: sourcePath.split(/[\\/]/).at(-1) ?? "program.pp", text: await Deno.readTextFile(sourcePath) };
  const recording = await Deno.makeTempFile({ suffix: ".jsonl" });
  const control = scenario.hosts.find((host) => host.id === "control") ?? scenario.hosts[0]!;
  const coldHome = control.store === "cold" ? await Deno.makeTempDir({ prefix: "pp-sim-home-" }) : undefined;
  const args = ["simulate", "--record", recording];
  for (const grant of scenario.grants) args.push("--grant", grant);
  args.push(programFile ?? scenario.program.file, "--", ...scenario.program.argv);
  const child = new Deno.Command(pp, { args, stdout: "piped", stderr: "piped", env: coldHome ? { HOME: coldHome } : undefined }).spawn();
  let streamed: PpEvent[] = [], completeLines = 0, paused = false, stopped = false;
  const collect = async (): Promise<void> => {
    const lines = (await Deno.readTextFile(recording)).split(/\r?\n/).filter(Boolean);
    for (let index = completeLines; index < lines.length; index += 1) {
      const event = decodeEvent(JSON.parse(lines[index]!)); streamed = [...streamed, event]; onEvent?.(event);
    }
    completeLines = lines.length;
  };
  const watcher = setInterval(() => { collect().catch(() => {}); }, 25);
  const completion = child.output().then(async (output): Promise<RunResult> => {
    clearInterval(watcher); await collect();
    const decoder = new TextDecoder();
    const events = decodeJsonl(await Deno.readTextFile(recording));
    const network = new VirtualNetwork(scenario); const networkEvents: NetworkEvent[] = [];
    for (const link of scenario.links) networkEvents.push(...network.transfer(link.id, Math.min(link.queueBytes, 65_536)).events);
    const assertions = checkExpectations(scenario.expect, events, networkEvents);
    const metrics = { semantic_events: events.length, logical_duration_us: networkEvents.at(-1)?.timeUs ?? 0, ...linkMetrics(networkEvents) };
    await Deno.remove(recording); if (coldHome) await Deno.remove(coldHome, { recursive: true });
    return { scenario, sourceSnapshot, stdout: decoder.decode(output.stdout), stderr: decoder.decode(output.stderr), status: output.code, events, networkEvents, assertions, metrics };
  }, async (error) => { clearInterval(watcher); await Deno.remove(recording); if (coldHome) await Deno.remove(coldHome, { recursive: true }); throw error; });
  return { completion, events: () => streamed,
    pause: () => { if (!paused && !stopped) { child.kill("SIGSTOP"); paused = true; } },
    resume: () => { if (paused && !stopped) { child.kill("SIGCONT"); paused = false; } },
    step: () => { if (paused && !stopped) { child.kill("SIGCONT"); setTimeout(() => { if (!stopped) child.kill("SIGSTOP"); }, 1); } },
    stop: () => { if (!stopped) { child.kill("SIGTERM"); stopped = true; } }
  };
}

export async function runScenario(text: string, pp = "pp", programFile?: string): Promise<RunResult> {
  return (await startScenario(text, pp, programFile)).completion;
}

export function exportBundle(result: RunResult): string {
  const bundle: RunBundle = { bundle_version: 1, scenario: canonicalScenario(result.scenario),
    events_jsonl: result.events.map((event) => JSON.stringify(event)).join("\n") + "\n",
    network_events: result.networkEvents,
    source_snapshot: result.sourceSnapshot,
    assertions: result.assertions, metrics: result.metrics,
    reproduction: { simulator: "pp", schema: 1, seed: result.scenario.seed } };
  return JSON.stringify(bundle, null, 2) + "\n";
}

export function importBundle(text: string): RunBundle {
  const value: unknown = JSON.parse(text);
  if (typeof value !== "object" || value === null || (value as { bundle_version?: unknown }).bundle_version !== 1) throw new Error("unsupported run bundle");
  const bundle = value as RunBundle; decodeJsonl(bundle.events_jsonl);
  if (typeof bundle.scenario !== "string" || !Array.isArray(bundle.network_events) || typeof bundle.source_snapshot?.text !== "string" || typeof bundle.reproduction?.seed !== "number") throw new Error("invalid run bundle");
  decodeScenario(bundle.scenario);
  return bundle;
}
