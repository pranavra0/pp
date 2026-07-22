const source = await Deno.readTextFile(new URL("../../src/runtime/event.ml", import.meta.url));
const values = (start: string, finish: string): string[] => {
  const section = source.slice(source.indexOf(start), source.indexOf(finish));
  return [...new Set([...section.matchAll(/"([a-z][a-z_.]+)"/g)].map((match) => match[1]!))].sort();
};
const categories = values("let category =", "let kind =");
const kinds = values("let kind =", "let phase =");
if (categories.length < 5 || kinds.length < 10) throw new Error("event schema extraction failed");
const union = (items: string[]) => items.map((item) => `  | ${JSON.stringify(item)}`).join("\n");
const output = `// Generated from src/runtime/event.ml by deno task generate. Do not edit.
export type EventCategory =\n${union(categories)};
export type EventKind =\n${union(kinds)};

export const eventCategories = new Set<string>(${JSON.stringify(categories)});
export const eventKinds = new Set<string>(${JSON.stringify(kinds)});
`;
await Deno.writeTextFile(new URL("../src/events.generated.ts", import.meta.url), output);
