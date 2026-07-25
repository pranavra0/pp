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
  readonly source_snapshot: { readonly name: string; readonly text: string };
  readonly assertions: readonly AssertionResult[]; readonly metrics: Readonly<Record<string, number | boolean>>;
  readonly explanations: readonly string[];
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

export const modeledEvents = (native: readonly PpEvent[], network: readonly NetworkEvent[], metrics: ReturnType<typeof linkMetrics>): readonly PpEvent[] => {
  const runId = native[0]?.run_id ?? "run";
  const events: PpEvent[] = [...native];
  for (const item of network) {
    const category = item.kind.split(".")[0] as PpEvent["category"];
    const payload: Record<string, string | number | null> = category === "network" ?
      { link_id: item.link ?? "", bytes: item.bytes ?? 0, attempt: item.attempt ?? 0 } :
      category === "fault" ? { target: item.target ?? "" } : { link_id: item.link ?? "" };
    events.push({ schema_version: 1, run_id: runId, event_id: events.length + 1,
      parent_event_id: null, host_id: item.host, logical_time: item.timeUs,
      wall_time_ns: null, category, kind: item.kind as PpEvent["kind"], phase: "instant",
      visibility: "public", payload });
  }
  events.push({ schema_version: 1, run_id: runId, event_id: events.length + 1,
    parent_event_id: null, host_id: "control", logical_time: network.at(-1)?.timeUs ?? native.length,
    wall_time_ns: null, category: "metric", kind: "metric.summary", phase: "instant",
    visibility: "public", payload: { requests: metrics.requests, retries: metrics.retries, bytes: metrics.bytes } });
  return events;
};

export interface RunningScenario {
  readonly completion: Promise<RunResult>;
  readonly events: () => readonly PpEvent[];
  pause(): void; resume(): void; step(): void; stop(): void;
}

export async function startScenario(text: string, pp = "pp", programFile?: string, onEvent?: (event: PpEvent) => void): Promise<RunningScenario> {
  const scenario = decodeScenario(text);
  const sourcePath = programFile ?? scenario.program.file;
  const sourceSnapshot = { name: sourcePath.split(/[\\/]/).at(-1) ?? "program.pp", text: await Deno.readTextFile(sourcePath) };
  const transferBytes = new TextEncoder().encode(sourceSnapshot.text).byteLength;
  const network = new VirtualNetwork(scenario); const networkEvents: NetworkEvent[] = [];
  const linkResults = new Map<string, "delivered" | "fallback">();
  for (const link of scenario.links) {
    const result = network.transfer(link.id, transferBytes);
    linkResults.set(link.id, result.status); networkEvents.push(...result.events);
  }
  const recording = await Deno.makeTempFile({ suffix: ".jsonl" });
  const control = scenario.hosts.find((host) => host.id === "control") ?? scenario.hosts[0]!;
  const workers = scenario.hosts.filter((host) => host.id !== control.id);
  const workerAvailable = (worker: Scenario["hosts"][number]): boolean => {
    if (scenario.actions.some((action) => action.atUs === 0 && action.kind === "crash" && action.host === worker.id)) return false;
    return !scenario.links.some((link) => link.to === worker.id && linkResults.get(link.id) === "fallback");
  };
  const controlHome = control.store === "cold" || workers.length ? await Deno.makeTempDir({ prefix: "pp-sim-home-" }) : undefined;
  const workerHomes = new Map<string, string>();
  if (workers.length && controlHome) {
    const initialized = await new Deno.Command(pp, { args: ["cluster-init"], env: { HOME: controlHome }, stdout: "null", stderr: "piped" }).output();
    if (!initialized.success) throw new Error(new TextDecoder().decode(initialized.stderr));
    for (const worker of workers) {
      const home = await Deno.makeTempDir({ prefix: `pp-sim-${worker.id}-` }); workerHomes.set(worker.id, home);
      await Deno.mkdir(`${home}/.pp/cluster`, { recursive: true });
      await Deno.copyFile(`${controlHome}/.pp/cluster/secret`, `${home}/.pp/cluster/secret`);
      await Deno.copyFile(`${controlHome}/.pp/cluster/id`, `${home}/.pp/cluster/id`);
    }
    await Deno.writeTextFile(`${controlHome}/.pp/cluster/members`, workers.filter(workerAvailable).map((worker) => `${worker.id} ${workerHomes.get(worker.id)}/.pp/store\n`).join(""));
  }
  const args = ["simulate", "--record", recording];
  if (workers.length) args.push("--schedule", `remote:${workers[0]!.id}`);
  for (const grant of scenario.grants) args.push("--grant", grant);
  args.push(programFile ?? scenario.program.file, "--", ...scenario.program.argv);
  const child = new Deno.Command(pp, { args, stdout: "piped", stderr: "piped", env: controlHome ? { HOME: controlHome } : undefined }).spawn();
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
    const nativeEvents = decodeJsonl(await Deno.readTextFile(recording));
    const links = linkMetrics(networkEvents);
    const events = modeledEvents(nativeEvents, networkEvents, links);
    const assertions = checkExpectations(scenario.expect, events, []);
    const metrics = { semantic_events: events.length, logical_duration_us: networkEvents.at(-1)?.timeUs ?? 0, ...links };
    await Deno.remove(recording); if (controlHome) await Deno.remove(controlHome, { recursive: true });
    for (const home of workerHomes.values()) await Deno.remove(home, { recursive: true });
    return { scenario, sourceSnapshot, stdout: decoder.decode(output.stdout), stderr: decoder.decode(output.stderr), status: output.code, events, networkEvents, assertions, metrics };
  }, async (error) => {
    clearInterval(watcher); await Deno.remove(recording);
    if (controlHome) await Deno.remove(controlHome, { recursive: true });
    for (const home of workerHomes.values()) await Deno.remove(home, { recursive: true });
    throw error;
  });
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
  const explanations = result.events.flatMap((event): string[] => {
    const link = event.payload.link_id;
    if (event.kind === "cache.hit") return [`Event ${event.event_id}: a stored trace was verified and its result was reused.`];
    if (event.kind === "fault.partition") return [`Event ${event.event_id}: link ${event.payload.target} was partitioned by the scenario.`];
    if (event.kind === "network.retry") return [`Event ${event.event_id}: transfer attempt ${event.payload.attempt} on ${link} was retried.`];
    if (event.kind === "network.corruption_detected") return [`Event ${event.event_id}: content verification rejected corrupted bytes on ${link}.`];
    if (event.kind === "scheduler.fallback") return [`Event ${event.event_id}: remote work on ${link} was unavailable, so the scheduler fell back locally.`];
    if (event.kind === "network.response") return [`Event ${event.event_id}: ${event.payload.bytes} verified bytes crossed ${link}.`];
    return [];
  });
  const bundle: RunBundle = { bundle_version: 1, scenario: canonicalScenario(result.scenario),
    events_jsonl: result.events.map((event) => JSON.stringify(event)).join("\n") + "\n",
    source_snapshot: result.sourceSnapshot,
    assertions: result.assertions, metrics: result.metrics, explanations,
    reproduction: { simulator: "pp", schema: 1, seed: result.scenario.seed } };
  return JSON.stringify(bundle, null, 2) + "\n";
}

export function importBundle(text: string): RunBundle {
  const value: unknown = JSON.parse(text);
  if (typeof value !== "object" || value === null || (value as { bundle_version?: unknown }).bundle_version !== 1) throw new Error("unsupported run bundle");
  const bundle = value as RunBundle; decodeJsonl(bundle.events_jsonl);
  if (typeof bundle.scenario !== "string" || typeof bundle.source_snapshot?.text !== "string" || !Array.isArray(bundle.explanations) || typeof bundle.reproduction?.seed !== "number") throw new Error("invalid run bundle");
  decodeScenario(bundle.scenario);
  return bundle;
}
