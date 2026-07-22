import { exportBundle, startScenario, type RunningScenario, type RunResult } from "./src/lab.ts";

const workspace = Deno.realPathSync(Deno.args[0] ?? Deno.cwd());
const assets = new URL("./site/", import.meta.url);
const port = Number(Deno.args[1] ?? "0");
const token = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
let current: RunResult | undefined;
let active: RunningScenario | undefined;
let generation = 0;
const approvedGrants = new Set<string>();
const pendingApprovals = new Map<string, string>();
const clients = new Set<WebSocket>();
const headers = { "content-type": "application/json", "cache-control": "no-store" };
const reply = (body: unknown, status = 200): Response => new Response(JSON.stringify(body), { status, headers });
const authorized = (request: Request): boolean => request.headers.get("authorization") === `Bearer ${token}` || new URL(request.url).searchParams.get("session") === token;
const insideWorkspace = async (path: string): Promise<string> => {
  const resolved = await Deno.realPath(new URL(path, `file://${workspace}/`));
  if (!(resolved === workspace || resolved.startsWith(`${workspace}/`))) throw new Error("path outside controller workspace");
  return resolved;
};
const broadcast = (message: unknown): void => {
  const text = JSON.stringify(message);
  for (const client of clients) if (client.readyState === WebSocket.OPEN) {
    if (client.bufferedAmount > 1_048_576) client.close(1013, "resume from last event");
    else client.send(text);
  }
};

const server = Deno.serve({ hostname: "127.0.0.1", port, onListen: () => {} }, async (request) => {
  const url = new URL(request.url);
  if (url.pathname === "/bootstrap" && request.method === "POST") {
    const supplied = (await request.json() as { token?: string }).token;
    return supplied === token ? reply({ accepted: true, session: token }) : reply({ accepted: false }, 403);
  }
  if (request.method === "GET" && !url.pathname.startsWith("/events") && !url.pathname.startsWith("/recording") && !url.pathname.startsWith("/bundle")) {
    const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    if (!name.includes("..") && /^[A-Za-z0-9._/-]+$/.test(name)) {
      try {
        const body = await Deno.readFile(new URL(name, assets));
        const extension = name.split(".").at(-1);
        const contentType = ({ html: "text/html; charset=utf-8", js: "text/javascript; charset=utf-8", css: "text/css; charset=utf-8", jsonl: "application/jsonl" } as Record<string, string>)[extension ?? ""] ?? "application/octet-stream";
        return new Response(body, { headers: { "content-type": contentType, "x-content-type-options": "nosniff" } });
      } catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
    }
  }
  if (!authorized(request)) return reply({ error: "unauthorized" }, 401);
  if (url.pathname === "/events" && request.headers.get("upgrade") === "websocket") {
    const { socket, response } = Deno.upgradeWebSocket(request); clients.add(socket);
    socket.onclose = () => clients.delete(socket);
    socket.onopen = () => {
      const from = Number(url.searchParams.get("from") ?? 1);
      for (const event of current?.events ?? active?.events() ?? []) if (event.event_id >= from) socket.send(JSON.stringify({ type: "event", event }));
    };
    return response;
  }
  if (url.pathname === "/scenario/validate" && request.method === "POST") {
    try { const { decodeScenario } = await import("./src/scenario.ts"); return reply({ accepted: true, scenario: decodeScenario(await request.text()) }); }
    catch (error) { return reply({ accepted: false, error: (error as Error).message }, 400); }
  }
  if (url.pathname === "/run" && request.method === "POST") {
    const requestId = request.headers.get("x-request-id") ?? crypto.randomUUID();
    try {
      const scenarioText = await request.text();
      const parsed = (await import("./src/scenario.ts")).decodeScenario(scenarioText);
      const absolute = await insideWorkspace(parsed.program.file);
      const grantKey = JSON.stringify(parsed.grants);
      const approval = request.headers.get("x-grant-approval");
      if (!approvedGrants.has(grantKey)) {
        if (approval !== null && pendingApprovals.get(approval) === grantKey) {
          approvedGrants.add(grantKey); pendingApprovals.delete(approval);
        } else {
          const approvalToken = crypto.randomUUID(); pendingApprovals.set(approvalToken, grantKey);
          return reply({ request_id: requestId, accepted: false, approval_required: true, approval_token: approvalToken, grants: parsed.grants }, 409);
        }
      }
      active?.stop(); current = undefined;
      const runGeneration = ++generation;
      active = await startScenario(scenarioText, Deno.env.get("PP") ?? "pp", absolute,
        (event) => broadcast({ type: "event", event }));
      active.completion.then((result) => {
        if (runGeneration !== generation) return;
        current = result; active = undefined;
        broadcast({ type: "finished", status: result.status, assertions: result.assertions, metrics: result.metrics });
      }).catch((error) => { active = undefined; broadcast({ type: "failed", error: (error as Error).message }); });
      broadcast({ type: "command", request_id: requestId, accepted: true });
      return reply({ request_id: requestId, accepted: true, running: true }, 202);
    } catch (error) { return reply({ request_id: requestId, accepted: false, error: (error as Error).message }, 400); }
  }
  if (url.pathname === "/recording" && request.method === "GET") {
    if (!current) return active ? reply({ running: true, events: active.events() }, 202) : reply({ error: "no run" }, 404);
    const from = Number(url.searchParams.get("from") ?? 1), to = Number(url.searchParams.get("to") ?? current.events.length);
    return reply({ events: current.events.slice(Math.max(0, from - 1), to), metrics: current.metrics });
  }
  if (url.pathname === "/bundle" && request.method === "GET") {
    if (!current) return reply({ error: "no run" }, 404);
    return new Response(exportBundle(current), { headers: { "content-type": "application/json", "content-disposition": "attachment; filename=run.ppsim-bundle.json" } });
  }
  if (url.pathname === "/pause" && request.method === "POST") { active?.pause(); return reply({ accepted: active !== undefined }); }
  if (url.pathname === "/resume" && request.method === "POST") { active?.resume(); return reply({ accepted: active !== undefined }); }
  if (url.pathname === "/step" && request.method === "POST") { active?.step(); return reply({ accepted: active !== undefined }); }
  if (url.pathname === "/stop" && request.method === "POST") { generation += 1; active?.stop(); active = undefined; return reply({ accepted: true }); }
  return reply({ error: "not found" }, 404);
});

console.log(JSON.stringify({ url: `http://127.0.0.1:${server.addr.port}/#token=${token}`, workspace }));
