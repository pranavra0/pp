(() => {
  "use strict";

  const examples = Array.isArray(window.PP_EXAMPLES) ? window.PP_EXAMPLES : [];
  const maxShareBytes = 12000;
  const byId = (id) => document.getElementById(id);
  const preset = byId("preset");
  const scenario = byId("scenario");
  const source = byId("source");
  const runtimeBadge = byId("runtime-badge");
  const runButton = byId("run");
  const resetButton = byId("reset");
  const shareButton = byId("share");
  let selected = examples[0] || null;
  let lastRun = null;

  const whyText = {
    nodes: "Two node forms have equal code and equal inputs. pp can identify them as the same computation, so forcing both produces one shared computation.",
    build: "The compile nodes feed the link node. A future source change can invalidate only the dependent path instead of rebuilding unrelated work.",
    laziness: "delay keeps work suspended until force. The second force observes the already evaluated value rather than evaluating the body again.",
    effects: "The ask effect is handled by the nearest declared handler. No ambient filesystem, process, or network authority is involved."
  };

  function encodeShare(state) {
    if (new TextEncoder().encode(state.source).length > maxShareBytes) {
      throw new Error("source is too large to share");
    }
    const json = JSON.stringify(state);
    if (new TextEncoder().encode(json).length > maxShareBytes) {
      throw new Error("share state is too large");
    }
    let binary = "";
    new TextEncoder().encode(json).forEach((byte) => { binary += String.fromCharCode(byte); });
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function decodeShare(value) {
    if (!value || value.length > maxShareBytes) return null;
    try {
      const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "===";
      const binary = atob(padded);
      const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
      const state = JSON.parse(new TextDecoder().decode(bytes));
      const keys = Object.keys(state || {}).sort().join(",");
      if (keys !== "preset,source,version" || state.version !== 1 ||
          typeof state.source !== "string" || typeof state.preset !== "string" ||
          !examples.some((item) => item.id === state.preset) ||
          new TextEncoder().encode(state.source).length > maxShareBytes) return null;
      return state;
    } catch (_) {
      return null;
    }
  }

  function setRuntimeBadge() {
    if (typeof window.ppBrowserRun === "function") {
      runtimeBadge.textContent = "browser runtime ready";
      runtimeBadge.className = "badge good";
    } else {
      runtimeBadge.textContent = "browser runtime unavailable";
      runtimeBadge.className = "badge warning";
    }
  }

  function selectExample(id) {
    selected = examples.find((item) => item.id === id) || examples[0] || null;
    if (!selected) return;
    preset.value = selected.id;
    source.value = selected.source;
    byId("example-description").textContent = selected.description;
    byId("why-content").textContent = whyText[selected.id] || "Run the program to inspect its result.";
    byId("scenario-note").textContent = scenario.value === "replay"
      ? "Replay fixtures are intentionally separate from browser execution; no fixture is loaded for this preset yet."
      : "This run uses the shared pp semantic boundary with virtual browser host services.";
    clearResult();
  }

  function renderItems(element, values, emptyText, code) {
    element.replaceChildren();
    const items = values.length ? values : [emptyText];
    items.forEach((value) => {
      const li = document.createElement("li");
      if (code) {
        const text = document.createElement("code");
        text.textContent = String(value);
        li.appendChild(text);
      } else {
        li.textContent = String(value);
      }
      element.appendChild(li);
    });
  }

  function clearResult() {
    lastRun = null;
    byId("run-status").textContent = "No run yet.";
    byId("run-kind").textContent = "ready";
    byId("run-kind").className = "badge";
    byId("output").textContent = "Run an example to see its output.";
    byId("value").textContent = "—";
    renderItems(byId("diagnostics"), [], "None", false);
    renderItems(byId("events"), [], "No events recorded yet.", true);
  }

  function renderResult(result) {
    lastRun = result;
    const status = result.status || "error";
    byId("run-status").textContent = status === "ok"
      ? "Completed through the browser boundary."
      : status === "unavailable" ? "The browser runtime is unavailable." : "The program returned an error.";
    byId("run-kind").textContent = status;
    byId("run-kind").className = `badge ${status === "ok" ? "good" : "warning"}`;
    byId("output").textContent = Array.isArray(result.stdout) && result.stdout.length
      ? result.stdout.join("\n") : "(no output)";
    byId("value").textContent = result.value == null ? "—" : result.value;
    const diagnostics = Array.isArray(result.diagnostics) ? result.diagnostics : [];
    renderItems(byId("diagnostics"), diagnostics, "None", false);
    const events = Array.isArray(result.events) ? result.events : [];
    renderItems(byId("events"), events, "No semantic events emitted by this run.", true);
  }

  function run() {
    if (scenario.value === "replay") {
      renderResult({
        status: "unavailable",
        stdout: [],
        value: null,
        diagnostics: ["No replay recording is bundled for this preset."],
        events: [],
        runtime: "replay"
      });
      return;
    }
    if (typeof window.ppBrowserRun !== "function") {
      renderResult({
        status: "unavailable",
        stdout: [],
        value: null,
        diagnostics: ["Browser runtime unavailable. Build or serve pp-browser.js before running source."],
        events: [],
        runtime: "unavailable"
      });
      return;
    }
    runButton.disabled = true;
    try {
      const result = JSON.parse(window.ppBrowserRun(source.value));
      result.preset = selected ? selected.id : "custom";
      result.runtime = "browser";
      renderResult(result);
    } catch (error) {
      renderResult({ status: "error", stdout: [], value: null,
        diagnostics: [String(error)], events: [], runtime: "browser" });
    } finally {
      runButton.disabled = false;
    }
  }

  function share() {
    try {
      const encoded = encodeShare({ version: 1, preset: selected ? selected.id : "custom", source: source.value });
      const url = `${window.location.origin}${window.location.pathname}#share=${encoded}`;
      navigator.clipboard.writeText(url).then(() => {
        shareButton.textContent = "Link copied";
        setTimeout(() => { shareButton.textContent = "Copy share link"; }, 1400);
      }).catch(() => window.prompt("Copy this share link:", url));
    } catch (error) {
      window.alert(String(error));
    }
  }

  examples.forEach((item) => {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = item.title;
    preset.appendChild(option);
  });
  preset.addEventListener("change", () => selectExample(preset.value));
  scenario.addEventListener("change", () => {
    byId("scenario-note").textContent = scenario.value === "replay"
      ? "Replay fixtures are intentionally separate from browser execution; no fixture is loaded for this preset yet."
      : "This run uses the shared pp semantic boundary with virtual browser host services.";
  });
  runButton.addEventListener("click", run);
  resetButton.addEventListener("click", () => selectExample(selected ? selected.id : examples[0].id));
  shareButton.addEventListener("click", share);
  document.querySelectorAll(".tab").forEach((tab) => tab.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((other) => {
      other.classList.toggle("active", other === tab);
      other.setAttribute("aria-selected", other === tab ? "true" : "false");
    });
    document.querySelectorAll(".tab-panel").forEach((panel) => panel.classList.toggle("hidden", panel.id !== tab.dataset.panel));
  }));

  const shareState = decodeShare(new URLSearchParams(window.location.hash.slice(1)).get("share"));
  setRuntimeBadge();
  selectExample(shareState && shareState.preset || (examples[0] && examples[0].id));
  if (shareState) source.value = shareState.source;
})();
