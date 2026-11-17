export class ArenaCoordinator {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    if (new URL(request.url).pathname !== "/tick") {
      return new Response("Not found", { status: 404 });
    }
    try {
      const result = await this.tick();
      return Response.json({ ok: true, ...result });
    } catch (error) {
      await this.state.storage.setAlarm(Date.now() + 5000);
      return Response.json(
        { ok: false, error: error instanceof Error ? error.message : "Coordinator failed" },
        { status: 502 },
      );
    }
  }

  async alarm() {
    try {
      await this.tick();
    } catch {
      await this.state.storage.setAlarm(Date.now() + 5000);
    }
  }

  async tick() {
    const response = await fetch(this.env.SUPABASE_URL + "/rest/v1/rpc/worker_tick", {
      method: "POST",
      headers: {
        apikey: this.env.SUPABASE_PUBLISHABLE_KEY,
        "Content-Type": "application/json",
        "x-arena-worker-token": this.env.WORKER_WAKE_SECRET,
      },
      body: "{}",
    });
    const raw = await response.text();
    if (!response.ok) {
      throw new Error("Supabase worker_tick returned " + response.status + ": " + raw.slice(0, 240));
    }
    const result = JSON.parse(raw);
    if (result.next_deadline) {
      const deadline = Date.parse(result.next_deadline);
      if (!Number.isFinite(deadline)) throw new Error("Invalid server deadline returned by Supabase");
      await this.state.storage.setAlarm(Math.max(Date.now() + 250, deadline));
    } else {
      await this.state.storage.deleteAlarm();
    }
    return result;
  }
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Cache-Control": "no-store",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (url.pathname === "/health" && request.method === "GET") {
      return Response.json({ ok: true, service: "face-arena-coordinator" }, { headers: corsHeaders });
    }
    if (url.pathname !== "/wake" || request.method !== "POST") {
      return Response.json({ error: "Not found" }, { status: 404, headers: corsHeaders });
    }
    const authorization = request.headers.get("Authorization");
    if (!authorization || !authorization.startsWith("Bearer ")) {
      return Response.json({ error: "Authentication required" }, { status: 401, headers: corsHeaders });
    }
    const authCheck = await fetch(env.SUPABASE_URL + "/auth/v1/user", {
      headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY, Authorization: authorization },
    });
    if (!authCheck.ok) {
      return Response.json({ error: "Invalid session" }, { status: 401, headers: corsHeaders });
    }
    const id = env.ARENA.idFromName("global-arena");
    const coordinator = env.ARENA.get(id);
    const response = await coordinator.fetch("https://arena-coordinator/tick", { method: "POST" });
    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(corsHeaders)) headers.set(key, value);
    return new Response(response.body, { status: response.status, headers });
  },
};
