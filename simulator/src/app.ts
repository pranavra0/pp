import { decodeJsonl, type EventCategory, type PpEvent } from "./event.ts";
import { filterEvents, Replay, type ReplayState } from "./reducer.ts";

declare global {
  var ppBrowser: { run(sourceName: string, source: string): string };
}

const examples = {
  "Cold and warm node": "let answer = force(node { 40 + 2 })\nprint(answer)",
  "Functions and collections": "let twice = fn(x) { x * 2 }\n[twice(2), twice(3), {answer: twice(21)}]",
  "Effects and handlers": "with { handlers: { :ask -> fn(question) { string-append(question, \" 42\") } } } { perform ask(\"answer:\") }",
  "Macro expansion": "defmacro unless(test, body) { quasiquote { if unquote(test) { nil } else { unquote(body) } } }\nunless(false, 42)"
} as const;

const categories: readonly EventCategory[] = ["run", "source", "evaluation", "identity", "cache", "node", "scheduler", "store", "capability", "network", "process", "domain", "reconcile", "watch", "fault", "metric"];
const get = <T extends Element>(selector: string): T => {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`missing ${selector}`);
  return element;
};

const fileInput = get<HTMLInputElement>("#recording");
const play = get<HTMLButtonElement>("#play");
const stepBack = get<HTMLButtonElement>("#step-back");
const step = get<HTMLButtonElement>("#step");
const seek = get<HTMLInputElement>("#seek");
const query = get<HTMLInputElement>("#query");
const eventList = get<HTMLOListElement>("#events");
const inspector = get<HTMLElement>("#inspector");
const topology = get<SVGSVGElement>("#topology");
const status = get<HTMLElement>("#status");
const filterRoot = get<HTMLElement>("#filters");
const runSource = get<HTMLButtonElement>("#run");
const runScenario = get<HTMLButtonElement>("#run-scenario");
const exportRun = get<HTMLButtonElement>("#export");
const nativeControls = ["pause-run", "resume-run", "step-run", "stop-run"].map((id) => get<HTMLButtonElement>(`#${id}`));
const example = get<HTMLSelectElement>("#example");
const surface = get<HTMLSelectElement>("#surface");
const source = get<HTMLTextAreaElement>("#source");
const diagnostics = get<HTMLElement>("#diagnostics");
const scenario = get<HTMLTextAreaElement>("#scenario");

let controllerSession: string | undefined;
let liveEvents: PpEvent[] = [];
let liveSocket: WebSocket | undefined;
let liveFrame: number | undefined;
const controllerRequest = async (path: string, init: RequestInit = {}): Promise<Response> => {
  if (!controllerSession) throw new Error("local controller is not connected");
  const headers = new Headers(init.headers); headers.set("authorization", `Bearer ${controllerSession}`);
  return fetch(path, { ...init, headers });
};

async function bootstrapController(): Promise<void> {
  const token = new URLSearchParams(location.hash.slice(1)).get("token");
  if (!token) return;
  history.replaceState(null, "", location.pathname + location.search);
  const response = await fetch("/bootstrap", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) });
  if (!response.ok) throw new Error("controller bootstrap was rejected");
  controllerSession = (await response.json() as { session: string }).session;
  runScenario.disabled = false; exportRun.disabled = false; nativeControls.forEach((control) => { control.disabled = false; });
  diagnostics.textContent = "Connected to loopback controller. Native scenario execution is available.";
  connectEvents();
}

function connectEvents(): void {
  if (!controllerSession) return;
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  liveSocket = new WebSocket(`${scheme}//${location.host}/events?session=${encodeURIComponent(controllerSession)}&from=${liveEvents.length + 1}`);
  liveSocket.addEventListener("message", (message) => {
    const data = JSON.parse(String(message.data)) as { type: string; event?: PpEvent; status?: number };
    if (data.type === "command") liveEvents = [];
    if (data.type === "event" && data.event) liveEvents.push(data.event);
    if (data.type === "finished") diagnostics.textContent = data.status === 0 ? "Scenario finished." : `Scenario exited ${data.status}`;
    if (liveFrame === undefined) liveFrame = requestAnimationFrame(() => {
      liveFrame = undefined;
      if (liveEvents.length) { events = liveEvents; replay = new Replay(events); cursor = events.length; render(); }
    });
  });
  liveSocket.addEventListener("close", () => { window.setTimeout(connectEvents, 250); });
}

let events: readonly PpEvent[] = [];
let replay = new Replay(events);
let cursor = 0;
let selected: number | null = null;
let explanations: readonly string[] = [];
let timer: number | undefined;

for (const category of categories) {
  const label = document.createElement("label");
  label.innerHTML = `<input type="checkbox" value="${category}" checked> ${category}`;
  filterRoot.append(label);
}

for (const [name, text] of Object.entries(examples)) {
  const option = document.createElement("option");
  option.value = text; option.textContent = name; example.append(option);
}
source.value = example.value;

const activeCategories = (): ReadonlySet<string> => new Set(
  [...filterRoot.querySelectorAll<HTMLInputElement>("input:checked")].map((input) => input.value)
);

function short(value: string): string { return value.length > 14 ? `${value.slice(0, 12)}…` : value; }

function renderTopology(state: ReplayState): void {
  topology.replaceChildren();
  const namespace = "http://www.w3.org/2000/svg";
  const hosts = state.hosts.toArray();
  state.links.valueSeq().forEach((link) => {
    const from = hosts.indexOf(link.from ?? ""), to = hosts.indexOf(link.to ?? "");
    if (from < 0 || to < 0) return;
    const line = document.createElementNS(namespace, "line");
    line.setAttribute("x1", String(155 + from * 270)); line.setAttribute("y1", "160");
    line.setAttribute("x2", String(155 + to * 270)); line.setAttribute("y2", "160");
    line.setAttribute("class", `link ${link.status}`); topology.append(line);
  });
  hosts.forEach((host, hostIndex) => {
    const group = document.createElementNS(namespace, "g");
    group.setAttribute("transform", `translate(${40 + hostIndex * 270} 45)`);
    const box = document.createElementNS(namespace, "rect");
    box.setAttribute("width", "230"); box.setAttribute("height", "230"); box.setAttribute("rx", "3");
    const title = document.createElementNS(namespace, "text");
    title.setAttribute("x", "12"); title.setAttribute("y", "24"); title.textContent = host;
    group.append(box, title);
    state.nodes.valueSeq().filter((node) => node.host === host).take(12).forEach((node, index) => {
      const nodeGroup = document.createElementNS(namespace, "g");
      nodeGroup.setAttribute("class", `node ${node.status} ${node.cache}`);
      nodeGroup.setAttribute("transform", `translate(${18 + (index % 3) * 70} ${52 + Math.floor(index / 3) * 42})`);
      const circle = document.createElementNS(namespace, "circle"); circle.setAttribute("r", "10");
      const label = document.createElementNS(namespace, "text"); label.setAttribute("x", "15"); label.setAttribute("y", "4"); label.textContent = short(node.key);
      nodeGroup.append(circle, label); group.append(nodeGroup);
    });
    topology.append(group);
  });
}

function renderInspector(): void {
  const event = selected === null ? undefined : events[selected - 1];
  if (!event) {
    inspector.replaceChildren();
    const prompt = document.createElement("p"); prompt.textContent = "Select an event to inspect its canonical payload and causal chain."; inspector.append(prompt);
    if (explanations.length) {
      const list = document.createElement("ul");
      list.append(...explanations.map((explanation) => { const item = document.createElement("li"); item.textContent = explanation; return item; })); inspector.append(list);
    }
    return;
  }
  const chain = replay.causalChain(event.event_id).map((item) => `#${item.event_id} ${item.kind}`).join(" → ");
  inspector.replaceChildren();
  const heading = document.createElement("h3"); heading.textContent = `#${event.event_id} ${event.kind}`;
  const cause = document.createElement("p"); cause.textContent = `Cause: ${chain}`;
  const raw = document.createElement("pre"); raw.textContent = JSON.stringify(event, null, 2);
  inspector.append(heading, cause, raw);
}

function render(): void {
  const state = replay.seek(cursor);
  seek.value = String(cursor); seek.max = String(events.length);
  status.textContent = `${state.runStatus} · ${cursor}/${events.length} events · ${state.nodes.size} nodes`;
  renderTopology(state);
  const visible = filterEvents(events.slice(0, cursor), activeCategories(), query.value).slice(-500);
  eventList.replaceChildren(...visible.map((event) => {
    const item = document.createElement("li");
    item.className = event.event_id === selected ? "selected" : "";
    item.dataset.category = event.category;
    item.tabIndex = 0;
    item.innerHTML = `<time>${event.logical_time}</time><span>${event.host_id}</span><strong>${event.kind}</strong><small>${event.phase}</small>`;
    item.addEventListener("click", () => { selected = event.event_id; render(); });
    item.addEventListener("keydown", (keyEvent) => { if (keyEvent.key === "Enter") { selected = event.event_id; render(); } });
    return item;
  }));
  renderInspector();
}

function stop(): void { if (timer !== undefined) window.clearInterval(timer); timer = undefined; play.textContent = "Play"; }
function togglePlay(): void {
  if (timer !== undefined) { stop(); return; }
  play.textContent = "Pause";
  timer = window.setInterval(() => {
    if (cursor === events.length) stop(); else { cursor += 1; render(); }
  }, 160);
}

async function load(text: string): Promise<void> {
  stop(); events = decodeJsonl(text); replay = new Replay(events); cursor = 0; selected = null; render();
}

async function loadRecording(text: string): Promise<void> {
  if (text.trimStart().startsWith("{")) {
    const bundle = JSON.parse(text) as { bundle_version?: number; scenario?: string; events_jsonl?: string; source_snapshot?: { name: string; text: string }; assertions?: readonly { passed: boolean }[]; explanations?: readonly string[] };
    if (bundle.bundle_version !== 1 || typeof bundle.scenario !== "string" || typeof bundle.events_jsonl !== "string") throw new Error("unsupported run bundle");
    scenario.value = bundle.scenario;
    explanations = bundle.explanations ?? [];
    if (bundle.source_snapshot) { source.value = bundle.source_snapshot.text; surface.value = bundle.source_snapshot.name.endsWith(".ppl") ? "playground.ppl" : "playground.pp"; }
    diagnostics.textContent = `Imported bundle: ${bundle.assertions?.filter((assertion) => assertion.passed).length ?? 0}/${bundle.assertions?.length ?? 0} assertions passed.`;
    await load(bundle.events_jsonl); return;
  }
  explanations = [];
  await load(text);
}

fileInput.addEventListener("change", async () => { const file = fileInput.files?.[0]; if (file) await loadRecording(await file.text()); });
play.addEventListener("click", togglePlay);
step.addEventListener("click", () => { stop(); cursor = Math.min(events.length, cursor + 1); render(); });
stepBack.addEventListener("click", () => { stop(); cursor = Math.max(0, cursor - 1); render(); });
seek.addEventListener("input", () => { stop(); cursor = Number(seek.value); render(); });
query.addEventListener("input", render);
filterRoot.addEventListener("change", render);
example.addEventListener("change", () => { source.value = example.value; });
runSource.addEventListener("click", async () => {
  stop(); diagnostics.textContent = "Running shared pp runtime…";
  await new Promise((resolve) => window.setTimeout(resolve, 0));
  const result = JSON.parse(globalThis.ppBrowser.run(surface.value, source.value)) as
    { ok: boolean; output?: string; error?: string; events: string };
  diagnostics.textContent = result.ok ? (result.output || "(no output)") : (result.error || "Evaluation failed");
  await load(result.events);
  cursor = events.length; render();
});
runScenario.addEventListener("click", async () => {
  diagnostics.textContent = "Running native scenario…";
  const requestId = crypto.randomUUID();
  let response = await controllerRequest("/run", { method: "POST", headers: { "x-request-id": requestId }, body: scenario.value });
  let result = await response.json() as { accepted: boolean; error?: string; status?: number; approval_required?: boolean; approval_token?: string; grants?: readonly string[] };
  if (result.approval_required && result.approval_token) {
    const description = result.grants?.length ? result.grants.join("\n") : "No capabilities";
    if (!window.confirm(`Allow this scenario's native grants?\n\n${description}`)) { diagnostics.textContent = "Scenario grants were not approved."; return; }
    response = await controllerRequest("/run", { method: "POST", headers: { "x-request-id": requestId, "x-grant-approval": result.approval_token }, body: scenario.value });
    result = await response.json();
  }
  if (!result.accepted) { diagnostics.textContent = result.error ?? "Scenario rejected"; return; }
  let recording = await controllerRequest("/recording");
  while (recording.status === 202) { await new Promise((resolve) => window.setTimeout(resolve, 50)); recording = await controllerRequest("/recording"); }
  const body = await recording.json() as { events: readonly PpEvent[] };
  await load(body.events.map((event) => JSON.stringify(event)).join("\n")); cursor = events.length; render();
  diagnostics.textContent = "Scenario finished.";
});
exportRun.addEventListener("click", async () => {
  const response = await controllerRequest("/bundle"); if (!response.ok) throw new Error("run export failed");
  const link = document.createElement("a"); link.href = URL.createObjectURL(await response.blob()); link.download = "run.ppsim-bundle.json"; link.click(); URL.revokeObjectURL(link.href);
});
nativeControls.forEach((control) => control.addEventListener("click", async () => {
  const command = control.id.replace("-run", "");
  const response = await controllerRequest(`/${command}`, { method: "POST" });
  const result = await response.json() as { accepted: boolean };
  diagnostics.textContent = result.accepted ? `Native run ${command} accepted.` : "No native run is active.";
}));
document.addEventListener("keydown", (event) => { if (event.code === "Space" && event.target === document.body) { event.preventDefault(); togglePlay(); } });

try { await bootstrapController(); await load(await (await fetch("local-build.jsonl")).text()); }
catch (error) { status.textContent = (error as Error).message; }
