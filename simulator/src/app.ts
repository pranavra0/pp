import { decodeJsonl, type EventCategory, type PpEvent } from "./event.ts";
import { filterEvents, Replay, type ReplayState } from "./reducer.ts";

const categories: readonly EventCategory[] = ["run", "source", "identity", "cache", "node", "store"];
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

let events: readonly PpEvent[] = [];
let replay = new Replay(events);
let cursor = 0;
let selected: number | null = null;
let timer: number | undefined;

for (const category of categories) {
  const label = document.createElement("label");
  label.innerHTML = `<input type="checkbox" value="${category}" checked> ${category}`;
  filterRoot.append(label);
}

const activeCategories = (): ReadonlySet<string> => new Set(
  [...filterRoot.querySelectorAll<HTMLInputElement>("input:checked")].map((input) => input.value)
);

function short(value: string): string { return value.length > 14 ? `${value.slice(0, 12)}…` : value; }

function renderTopology(state: ReplayState): void {
  topology.replaceChildren();
  const namespace = "http://www.w3.org/2000/svg";
    state.hosts.toArray().forEach((host, hostIndex) => {
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
    inspector.innerHTML = "<p>Select an event to inspect its canonical payload and causal chain.</p>";
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

fileInput.addEventListener("change", async () => { const file = fileInput.files?.[0]; if (file) await load(await file.text()); });
play.addEventListener("click", togglePlay);
step.addEventListener("click", () => { stop(); cursor = Math.min(events.length, cursor + 1); render(); });
stepBack.addEventListener("click", () => { stop(); cursor = Math.max(0, cursor - 1); render(); });
seek.addEventListener("input", () => { stop(); cursor = Number(seek.value); render(); });
query.addEventListener("input", render);
filterRoot.addEventListener("change", render);
document.addEventListener("keydown", (event) => { if (event.code === "Space" && event.target === document.body) { event.preventDefault(); togglePlay(); } });

try { await load(await (await fetch("local-build.jsonl")).text()); }
catch (error) { status.textContent = (error as Error).message; }
