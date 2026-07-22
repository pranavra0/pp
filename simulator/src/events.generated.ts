// Generated from src/runtime/event.ml by deno task generate. Do not edit.
export type EventCategory =
  | "cache"
  | "identity"
  | "node"
  | "run"
  | "source"
  | "store";
export type EventKind =
  | "cache.hit"
  | "cache.miss"
  | "cache.trace.considered"
  | "identity.node_key.computed"
  | "identity.result_hash.computed"
  | "node.rebuild"
  | "run.configured"
  | "run.created"
  | "run.failed"
  | "run.finished"
  | "run.started"
  | "source.error"
  | "source.macro_expanded"
  | "source.parsed"
  | "source.read"
  | "store.object.persisted"
  | "store.trace.persisted";

export const eventCategories = new Set<string>(["cache","identity","node","run","source","store"]);
export const eventKinds = new Set<string>(["cache.hit","cache.miss","cache.trace.considered","identity.node_key.computed","identity.result_hash.computed","node.rebuild","run.configured","run.created","run.failed","run.finished","run.started","source.error","source.macro_expanded","source.parsed","source.read","store.object.persisted","store.trace.persisted"]);
