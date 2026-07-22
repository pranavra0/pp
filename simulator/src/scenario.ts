export interface ProgramSpec { readonly file: string; readonly argv: readonly string[] }
export interface HostSpec { readonly id: string; readonly cores: number; readonly store: "cold" | "warm" }
export interface LinkSpec {
  readonly id: string; readonly from: string; readonly to: string;
  readonly latencyUs: number; readonly bandwidthBytesPerSecond: number;
  readonly lossPpm: number; readonly corruptPpm: number; readonly queueBytes: number;
}
export type ActionSpec =
  | { readonly atUs: number; readonly kind: "partition" | "heal"; readonly link: string }
  | { readonly atUs: number; readonly kind: "crash" | "restart"; readonly host: string };
export type ExpectSpec =
  | { readonly kind: "eventually"; readonly event: string; readonly status?: string }
  | { readonly kind: "count"; readonly event: string; readonly min?: number; readonly max?: number };
export interface Scenario {
  readonly version: 1; readonly seed: number; readonly program: ProgramSpec;
  readonly hosts: readonly HostSpec[]; readonly links: readonly LinkSpec[];
  readonly grants: readonly string[]; readonly actions: readonly ActionSpec[];
  readonly expect: readonly ExpectSpec[];
}

type Value = string | number | boolean | null | Value[] | { [key: string]: Value };

class Decoder {
  private cursor = 0;
  constructor(private readonly text: string) {}
  decode(): Value {
    this.space();
    if (this.word() !== "scenario") this.fail("expected scenario");
    this.space();
    if (this.word() !== "v1") this.fail("expected schema v1");
    const value = this.value(); this.space();
    if (this.cursor !== this.text.length) this.fail("trailing input");
    return value;
  }
  private value(): Value {
    this.space(); const c = this.text[this.cursor];
    if (c === "{") return this.object();
    if (c === "[") return this.array();
    if (c === '"') return this.string();
    if (c === "-" || (c !== undefined && /[0-9]/.test(c))) return this.number();
    const word = this.word();
    if (word === "true") return true; if (word === "false") return false;
    if (word === "null") return null; if (word) return word;
    this.fail("expected value");
  }
  private object(): { [key: string]: Value } {
    this.take("{"); const result: { [key: string]: Value } = {}; this.space();
    while (this.text[this.cursor] !== "}") {
      const key = this.text[this.cursor] === '"' ? this.string() : this.word();
      if (!key || typeof key !== "string") this.fail("expected field name");
      if (Object.hasOwn(result, key)) this.fail(`duplicate field ${key}`);
      this.space(); this.take(":"); result[key] = this.value(); this.space();
      if (this.text[this.cursor] === ",") { this.cursor += 1; this.space(); }
      else if (this.text[this.cursor] !== "}") this.fail("expected , or }");
    }
    this.cursor += 1; return result;
  }
  private array(): Value[] {
    this.take("["); const result: Value[] = []; this.space();
    while (this.text[this.cursor] !== "]") {
      result.push(this.value()); this.space();
      if (this.text[this.cursor] === ",") { this.cursor += 1; this.space(); }
      else if (this.text[this.cursor] !== "]") this.fail("expected , or ]");
    }
    this.cursor += 1; return result;
  }
  private string(): string {
    const start = this.cursor; this.cursor += 1;
    while (this.cursor < this.text.length) {
      if (this.text[this.cursor] === '"') {
        this.cursor += 1;
        try { return JSON.parse(this.text.slice(start, this.cursor)); }
        catch { this.fail("invalid string"); }
      }
      if (this.text[this.cursor] === "\\") this.cursor += 1;
      this.cursor += 1;
    }
    this.fail("unterminated string");
  }
  private number(): number {
    const rest = this.text.slice(this.cursor); const match = /^-?[0-9]+/.exec(rest);
    if (!match) this.fail("invalid integer"); this.cursor += match[0].length;
    const value = Number(match[0]); if (!Number.isSafeInteger(value)) this.fail("integer outside safe range");
    return value;
  }
  private word(): string {
    this.space(); const match = /^[A-Za-z_][A-Za-z0-9_.-]*/.exec(this.text.slice(this.cursor));
    if (!match) return ""; this.cursor += match[0].length; return match[0];
  }
  private space(): void {
    while (this.cursor < this.text.length) {
      if (/\s/.test(this.text[this.cursor]!)) { this.cursor += 1; continue; }
      if (this.text[this.cursor] === "#") {
        while (this.cursor < this.text.length && this.text[this.cursor] !== "\n") this.cursor += 1;
        continue;
      }
      break;
    }
  }
  private take(token: string): void { this.space(); if (this.text[this.cursor] !== token) this.fail(`expected ${token}`); this.cursor += 1; }
  private fail(message: string): never { throw new Error(`scenario:${this.cursor + 1}: ${message}`); }
}

const object = (value: Value, at: string): { [key: string]: Value } => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${at} must be an object`);
  return value;
};
const array = (value: Value | undefined, at: string): Value[] => {
  if (!Array.isArray(value)) throw new Error(`${at} must be an array`); return value;
};
const string = (value: Value | undefined, at: string): string => {
  if (typeof value !== "string") throw new Error(`${at} must be a string`); return value;
};
const integer = (value: Value | undefined, at: string): number => {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`${at} must be a nonnegative integer`); return value as number;
};
const fields = (value: { [key: string]: Value }, allowed: readonly string[], at: string): void => {
  const unknown = Object.keys(value).find((key) => !allowed.includes(key));
  if (unknown) throw new Error(`${at}.${unknown} is unknown`);
};
export const durationUs = (text: string): number => {
  const match = /^([0-9]+)(us|ms|s)$/.exec(text); if (!match) throw new Error(`invalid duration ${text}`);
  return Number(match[1]) * ({ us: 1, ms: 1_000, s: 1_000_000 }[match[2]!]!);
};
const rate = (text: string): number => {
  const match = /^([0-9]+)(bit|kbit|mbit|gbit)$/.exec(text); if (!match) throw new Error(`invalid bandwidth ${text}`);
  return Math.floor(Number(match[1]) * ({ bit: 1, kbit: 1_000, mbit: 1_000_000, gbit: 1_000_000_000 }[match[2]!]!) / 8);
};
const ppm = (text: string): number => {
  const match = /^(100|[0-9]{1,2})(?:\.([0-9]{1,4}))?%$/.exec(text); if (!match) throw new Error(`invalid percentage ${text}`);
  return Math.round(Number(`${match[1]}.${match[2] ?? "0"}`) * 10_000);
};

export function decodeScenario(text: string): Scenario {
  const root = object(new Decoder(text).decode(), "scenario");
  fields(root, ["seed", "program", "hosts", "links", "grants", "actions", "expect"], "scenario");
  const program = object(root.program!, "program"); fields(program, ["file", "argv"], "program");
  const hostsObject = object(root.hosts!, "hosts");
  const hosts = Object.entries(hostsObject).map(([id, raw]) => {
    const host = object(raw, `hosts.${id}`); fields(host, ["cores", "store"], `hosts.${id}`);
    const store = string(host.store ?? "cold", `hosts.${id}.store`);
    if (store !== "cold" && store !== "warm") throw new Error(`hosts.${id}.store must be cold or warm`);
    return { id, cores: integer(host.cores ?? 1, `hosts.${id}.cores`), store } as HostSpec;
  });
  if (!hosts.length) throw new Error("scenario requires at least one host");
  const hostIds = new Set(hosts.map((host) => host.id));
  const links = array(root.links ?? [], "links").map((raw, index) => {
    const link = object(raw, `links[${index}]`); fields(link, ["id", "from", "to", "latency", "bandwidth", "loss", "corruption", "queue"], `links[${index}]`);
    const from = string(link.from, `links[${index}].from`), to = string(link.to, `links[${index}].to`);
    if (!hostIds.has(from) || !hostIds.has(to)) throw new Error(`links[${index}] references unknown host`);
    return { id: string(link.id ?? `${from}-${to}`, `links[${index}].id`), from, to,
      latencyUs: durationUs(string(link.latency ?? "0ms", `links[${index}].latency`)),
      bandwidthBytesPerSecond: rate(string(link.bandwidth ?? "1gbit", `links[${index}].bandwidth`)),
      lossPpm: ppm(string(link.loss ?? "0%", `links[${index}].loss`)),
      corruptPpm: ppm(string(link.corruption ?? "0%", `links[${index}].corruption`)),
      queueBytes: integer(link.queue ?? 1_048_576, `links[${index}].queue`) };
  });
  const linkIds = new Set(links.map((link) => link.id));
  const actions = array(root.actions ?? [], "actions").map((raw, index): ActionSpec => {
    const action = object(raw, `actions[${index}]`); fields(action, ["at", "partition", "heal", "crash", "restart"], `actions[${index}]`);
    const atUs = durationUs(string(action.at, `actions[${index}].at`));
    for (const kind of ["partition", "heal"] as const) if (action[kind] !== undefined) {
      const link = string(action[kind], `actions[${index}].${kind}`); if (!linkIds.has(link)) throw new Error(`actions[${index}] references unknown link`);
      return { atUs, kind, link };
    }
    for (const kind of ["crash", "restart"] as const) if (action[kind] !== undefined) {
      const host = string(action[kind], `actions[${index}].${kind}`); if (!hostIds.has(host)) throw new Error(`actions[${index}] references unknown host`);
      return { atUs, kind, host };
    }
    throw new Error(`actions[${index}] requires exactly one fault`);
  }).sort((a, b) => a.atUs - b.atUs);
  const expect = array(root.expect ?? [], "expect").map((raw, index): ExpectSpec => {
    const item = object(raw, `expect[${index}]`); fields(item, ["eventually", "count"], `expect[${index}]`);
    if (item.eventually !== undefined) {
      const target = object(item.eventually, `expect[${index}].eventually`); fields(target, ["event", "status"], `expect[${index}].eventually`);
      return { kind: "eventually", event: string(target.event, `expect[${index}].eventually.event`), status: target.status === undefined ? undefined : string(target.status, "status") };
    }
    const target = object(item.count!, `expect[${index}].count`); fields(target, ["event", "min", "max"], `expect[${index}].count`);
    return { kind: "count", event: string(target.event, `expect[${index}].count.event`), min: target.min === undefined ? undefined : integer(target.min, "min"), max: target.max === undefined ? undefined : integer(target.max, "max") };
  });
  return { version: 1, seed: integer(root.seed ?? 0, "seed"),
    program: { file: string(program.file, "program.file"), argv: array(program.argv ?? [], "program.argv").map((value, index) => string(value, `program.argv[${index}]`)) },
    hosts, links, grants: array(root.grants ?? [], "grants").map((value, index) => string(value, `grants[${index}]`)), actions, expect };
}

const quote = (value: string): string => JSON.stringify(value);
const duration = (value: number): string => `${value}us`;
const percent = (value: number): string => `${value / 10_000}%`;
const actionTarget = (action: ActionSpec): string => {
  switch (action.kind) {
    case "partition": case "heal": return action.link;
    case "crash": case "restart": return action.host;
  }
};
export const canonicalScenario = (scenario: Scenario): string => `scenario v1 {
  seed: ${scenario.seed},
  program: { file: ${quote(scenario.program.file)}, argv: [${scenario.program.argv.map(quote).join(", ")}] },
  hosts: {${scenario.hosts.map((host) => `\n    ${quote(host.id)}: { cores: ${host.cores}, store: ${host.store} }`).join(",")}\n  },
  links: [${scenario.links.map((link) => `\n    { id: ${quote(link.id)}, from: ${quote(link.from)}, to: ${quote(link.to)}, latency: ${quote(duration(link.latencyUs))}, bandwidth: ${quote(`${link.bandwidthBytesPerSecond * 8}bit`)}, loss: ${quote(percent(link.lossPpm))}, corruption: ${quote(percent(link.corruptPpm))}, queue: ${link.queueBytes} }`).join(",")}\n  ],
  grants: [${scenario.grants.map(quote).join(", ")}],
  actions: [${scenario.actions.map((action) => `\n    { at: ${quote(duration(action.atUs))}, ${action.kind}: ${quote(actionTarget(action))} }`).join(",")}\n  ],
  expect: [${scenario.expect.map((expectation) => expectation.kind === "eventually" ? `\n    { eventually: { event: ${quote(expectation.event)}${expectation.status === undefined ? "" : `, status: ${quote(expectation.status)}`} } }` : `\n    { count: { event: ${quote(expectation.event)}${expectation.min === undefined ? "" : `, min: ${expectation.min}`}${expectation.max === undefined ? "" : `, max: ${expectation.max}`} } }`).join(",")}\n  ]
}`;
