import type { PpEvent } from "./event.ts";
import { Map, Set } from "immutable";

export interface NodeState {
  readonly key: string;
  readonly host: string;
  readonly status: "known" | "rebuilding" | "finished" | "failed";
  readonly cache: "unknown" | "hit" | "miss";
  readonly resultHash?: string;
}

export interface ReplayState {
  readonly cursor: number;
  readonly runStatus: "idle" | "running" | "finished" | "failed";
  readonly hosts: Set<string>;
  readonly nodes: Map<string, NodeState>;
  readonly links: Map<string, { readonly id: string; readonly from?: string; readonly to?: string; readonly status: "active" | "dropped" | "partitioned" | "corrupt" }>;
  readonly counts: Map<string, number>;
}

export const initialState = (): ReplayState => ({
  cursor: 0, runStatus: "idle", hosts: Set(), nodes: Map(), links: Map(), counts: Map()
});

const text = (event: PpEvent, field: string): string | undefined => {
  const value = event.payload[field];
  return typeof value === "string" ? value : undefined;
};

export function reduceEvent(state: ReplayState, event: PpEvent): ReplayState {
  if (event.event_id !== state.cursor + 1) throw new Error("events must be reduced in event-id order");
  const hosts = state.hosts.add(event.host_id);
  const counts = state.counts.set(event.category, (state.counts.get(event.category) ?? 0) + 1);
  let nodes = state.nodes;
  let links = state.links;
  const key = text(event, "node_key") ?? text(event, "cache_key");
  if (key) {
    const previous = nodes.get(key) ?? { key, host: event.host_id, status: "known", cache: "unknown" };
    let next: NodeState = previous;
    if (event.kind === "cache.hit") next = { ...previous, cache: "hit", resultHash: text(event, "result_hash") };
    if (event.kind === "cache.miss") next = { ...previous, cache: "miss" };
    if (event.kind === "node.rebuild" && event.phase === "started") next = { ...previous, status: "rebuilding" };
    if (event.kind === "node.rebuild" && event.phase === "finished") next = { ...previous, status: "finished", resultHash: text(event, "result_hash") };
    if (event.kind === "node.rebuild" && event.phase === "failed") next = { ...previous, status: "failed" };
    nodes = nodes.set(key, next);
  }
  let runStatus = state.runStatus;
  if (event.kind === "run.started") runStatus = "running";
  if (event.kind === "run.finished") runStatus = "finished";
  if (event.kind === "run.failed") runStatus = "failed";
  const linkId = text(event, "link_id") ?? (event.category === "fault" ? text(event, "target") : undefined);
  if (linkId) {
    const previous = links.get(linkId) ?? { id: linkId, status: "active" as const };
    let status = previous.status;
    if (event.kind === "network.drop" || event.kind === "network.unreachable") status = "dropped";
    if (event.kind === "network.corruption_detected") status = "corrupt";
    if (event.kind === "fault.partition") status = "partitioned";
    if (event.kind === "fault.heal" || event.kind === "network.response") status = "active";
    const from = event.kind === "network.request" ? event.host_id : previous.from;
    const to = event.kind === "network.response" ? event.host_id : previous.to;
    links = links.set(linkId, { ...previous, from, to, status });
  }
  return { cursor: event.event_id, runStatus, hosts, nodes, links, counts };
}

export class Replay {
  readonly events: readonly PpEvent[];
  readonly checkpointEvery: number;
  private readonly checkpoints = Map<number, ReplayState>([[0, initialState()]]);
  private readonly byId: ReadonlyMap<number, PpEvent>;

  constructor(events: readonly PpEvent[], checkpointEvery = 256) {
    if (checkpointEvery < 1) throw new Error("checkpoint interval must be positive");
    this.events = events;
    this.checkpointEvery = checkpointEvery;
    this.byId = new globalThis.Map(events.map((event) => [event.event_id, event]));
  }

  seek(cursor: number): ReplayState {
    if (!Number.isInteger(cursor) || cursor < 0 || cursor > this.events.length)
      throw new Error("cursor outside recording");
    const base = Math.floor(cursor / this.checkpointEvery) * this.checkpointEvery;
    let state = this.checkpoints.get(base);
    if (!state) {
      let checkpoint = 0;
      for (const existing of this.checkpoints.keys()) if (existing <= base && existing > checkpoint) checkpoint = existing;
      state = this.checkpoints.get(checkpoint)!;
      while (checkpoint < base) {
        const next = Math.min(base, checkpoint + this.checkpointEvery);
        for (let index = checkpoint; index < next; index += 1) state = reduceEvent(state, this.events[index]!);
        checkpoint = next; this.checkpoints.set(checkpoint, state);
      }
    }
    for (let index = state.cursor; index < cursor; index += 1) state = reduceEvent(state, this.events[index]!);
    if (cursor % this.checkpointEvery === 0) this.checkpoints.set(cursor, state);
    return state;
  }

  causalChain(eventId: number): readonly PpEvent[] {
    const chain: PpEvent[] = [];
    const seen = new globalThis.Set<number>();
    let event = this.byId.get(eventId);
    while (event) {
      if (seen.has(event.event_id)) throw new Error("causal cycle");
      seen.add(event.event_id); chain.unshift(event);
      event = event.parent_event_id === null ? undefined : this.byId.get(event.parent_event_id);
    }
    return chain;
  }
}

export function filterEvents(events: readonly PpEvent[], categories: ReadonlySet<string>, query: string): readonly PpEvent[] {
  const needle = query.trim().toLowerCase();
  return events.filter((event) => categories.has(event.category) &&
    (!needle || JSON.stringify(event).toLowerCase().includes(needle)));
}
