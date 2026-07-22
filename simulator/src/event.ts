import { eventCategories, eventKinds, type EventCategory, type EventKind } from "./events.generated.ts";

export type { EventCategory } from "./events.generated.ts";

export type EventPhase = "instant" | "started" | "finished" | "failed";
export type Visibility = "public" | "redacted";
export type EventPayload = Readonly<Record<string, string | number | null>>;

export interface PpEvent {
  readonly schema_version: 1;
  readonly run_id: string;
  readonly event_id: number;
  readonly parent_event_id: number | null;
  readonly host_id: string;
  readonly logical_time: number;
  readonly wall_time_ns: number | null;
  readonly category: EventCategory;
  readonly kind: EventKind;
  readonly phase: EventPhase;
  readonly visibility: Visibility;
  readonly payload: EventPayload;
}

const phases = new Set(["instant", "started", "finished", "failed"]);
const visibilities = new Set(["public", "redacted"]);

const object = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export function decodeEvent(value: unknown): PpEvent {
  if (!object(value) || value.schema_version !== 1 ||
      typeof value.run_id !== "string" || !Number.isSafeInteger(value.event_id) ||
      !(value.parent_event_id === null || Number.isSafeInteger(value.parent_event_id)) ||
      typeof value.host_id !== "string" || !Number.isSafeInteger(value.logical_time) ||
      !(value.wall_time_ns === null || Number.isSafeInteger(value.wall_time_ns)) ||
      typeof value.category !== "string" || !eventCategories.has(value.category) ||
      typeof value.kind !== "string" || !eventKinds.has(value.kind) ||
      typeof value.phase !== "string" || !phases.has(value.phase) ||
      typeof value.visibility !== "string" || !visibilities.has(value.visibility) ||
      !object(value.payload)) throw new Error("invalid pp event envelope");
  return value as unknown as PpEvent;
}

export function decodeJsonl(text: string): readonly PpEvent[] {
  const events = text.split(/\r?\n/).filter(Boolean).map((line, index) => {
    try { return decodeEvent(JSON.parse(line)); }
    catch (error) { throw new Error(`event line ${index + 1}: ${(error as Error).message}`); }
  });
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]!;
    if (event.event_id !== index + 1) throw new Error(`event line ${index + 1}: non-contiguous event id`);
    if (event.parent_event_id !== null && event.parent_event_id >= event.event_id)
      throw new Error(`event line ${index + 1}: invalid causal parent`);
  }
  return events;
}
