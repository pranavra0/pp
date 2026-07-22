import type { ActionSpec, LinkSpec, Scenario } from "./scenario.ts";

export interface NetworkEvent { readonly timeUs: number; readonly kind: string; readonly host: string; readonly link?: string; readonly target?: string; readonly bytes?: number; readonly attempt?: number }
export interface TransferResult { readonly status: "delivered" | "fallback"; readonly attempts: number; readonly events: readonly NetworkEvent[]; readonly finishedUs: number }

class Random {
  constructor(private state: number) { this.state >>>= 0; }
  next(): number { this.state = (Math.imul(this.state, 1664525) + 1013904223) >>> 0; return this.state; }
  ppm(limit: number): boolean { return this.next() % 1_000_000 < limit; }
}

export class VirtualNetwork {
  private readonly random: Random;
  private readonly available = new Map<string, boolean>();
  private readonly alive = new Map<string, boolean>();
  private actionCursor = 0;
  private timeUs = 0;
  private readonly events: NetworkEvent[] = [];
  constructor(private readonly scenario: Scenario) {
    this.random = new Random(scenario.seed);
    for (const link of scenario.links) this.available.set(link.id, true);
    for (const host of scenario.hosts) this.alive.set(host.id, true);
  }
  private applyActions(untilUs: number): void {
    while (this.actionCursor < this.scenario.actions.length && this.scenario.actions[this.actionCursor]!.atUs <= untilUs) {
      const action = this.scenario.actions[this.actionCursor++]!; this.timeUs = Math.max(this.timeUs, action.atUs);
      switch (action.kind) {
        case "partition": this.available.set(action.link, false); break;
        case "heal": this.available.set(action.link, true); break;
        case "crash": this.alive.set(action.host, false); break;
        case "restart": this.alive.set(action.host, true); break;
      }
      this.events.push({ timeUs: this.timeUs, kind: `fault.${action.kind}`, host: "control", target: target(action) });
    }
  }
  transfer(linkId: string, bytes: number, retries = 2): TransferResult {
    const link = this.scenario.links.find((candidate) => candidate.id === linkId);
    if (!link) throw new Error(`unknown link ${linkId}`); if (bytes < 0 || !Number.isSafeInteger(bytes)) throw new Error("invalid transfer size");
    const start = this.events.length;
    for (let attempt = 1; attempt <= retries + 1; attempt += 1) {
      this.applyActions(this.timeUs);
      this.events.push({ timeUs: this.timeUs, kind: "network.request", host: link.from, link: link.id, bytes, attempt });
      const duration = link.latencyUs + Math.ceil(bytes * 1_000_000 / link.bandwidthBytesPerSecond);
      const finish = this.timeUs + duration; this.applyActions(finish); this.timeUs = finish;
      const unavailable = !this.available.get(link.id) || !this.alive.get(link.from) || !this.alive.get(link.to) || bytes > link.queueBytes;
      const lost = !unavailable && this.random.ppm(link.lossPpm);
      if (unavailable || lost) {
        this.events.push({ timeUs: this.timeUs, kind: unavailable ? "network.unreachable" : "network.drop", host: link.to, link: link.id, bytes, attempt });
        if (attempt <= retries) { this.events.push({ timeUs: this.timeUs, kind: "network.retry", host: link.from, link: link.id, attempt }); continue; }
        this.events.push({ timeUs: this.timeUs, kind: "scheduler.fallback", host: link.from, link: link.id });
        return { status: "fallback", attempts: attempt, events: this.events.slice(start), finishedUs: this.timeUs };
      }
      if (this.random.ppm(link.corruptPpm)) {
        this.events.push({ timeUs: this.timeUs, kind: "network.corruption_detected", host: link.to, link: link.id, bytes, attempt });
        if (attempt <= retries) continue;
        this.events.push({ timeUs: this.timeUs, kind: "scheduler.fallback", host: link.from, link: link.id });
        return { status: "fallback", attempts: attempt, events: this.events.slice(start), finishedUs: this.timeUs };
      }
      this.events.push({ timeUs: this.timeUs, kind: "network.response", host: link.to, link: link.id, bytes, attempt });
      return { status: "delivered", attempts: attempt, events: this.events.slice(start), finishedUs: this.timeUs };
    }
    throw new Error("unreachable transfer state");
  }
}

const target = (action: ActionSpec): string => {
  switch (action.kind) {
    case "partition": case "heal": return action.link;
    case "crash": case "restart": return action.host;
  }
};

export const linkMetrics = (events: readonly NetworkEvent[]) => ({
  requests: events.filter((event) => event.kind === "network.request").length,
  retries: events.filter((event) => event.kind === "network.retry").length,
  bytes: events.filter((event) => event.kind === "network.response").reduce((sum, event) => sum + (event.bytes ?? 0), 0),
  fallback: events.some((event) => event.kind === "scheduler.fallback")
});
