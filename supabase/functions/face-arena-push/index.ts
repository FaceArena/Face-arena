import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { buildPushPayload } from "npm:@block65/webcrypto-web-push@2.0.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://face-arena-cloudflare.pages.dev",
  "Access-Control-Allow-Headers": "content-type, x-face-arena-push-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) throw new Error("Push sender is not configured");

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: configRows, error: configError } = await admin.rpc("get_face_arena_push_config");
    if (configError) throw configError;
    const config = Array.isArray(configRows) ? configRows[0] : configRows;
    if (!config?.public_key || !config?.private_key || !config?.hook_secret) {
      throw new Error("Push credentials are incomplete");
    }

    const suppliedSecret = req.headers.get("x-face-arena-push-secret") || "";
    if (!constantTimeEqual(suppliedSecret, config.hook_secret)) {
      return Response.json({ error: "Unauthorized" }, { status: 401, headers: corsHeaders });
    }

    const body = await req.json();
    const notificationId = String(body?.notification_id || "");
    const userId = String(body?.user_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(notificationId) || !/^[0-9a-f-]{36}$/i.test(userId)) {
      return Response.json({ error: "Invalid notification reference" }, { status: 400, headers: corsHeaders });
    }

    const { data: notification, error: notificationError } = await admin
      .from("arena_notifications")
      .select("id,user_id,kind,title,body,payload")
      .eq("id", notificationId)
      .eq("user_id", userId)
      .maybeSingle();
    if (notificationError) throw notificationError;
    if (!notification) return Response.json({ ok: true, skipped: "notification_missing" }, { headers: corsHeaders });

    const { data: subscriptions, error: subscriptionsError } = await admin
      .from("arena_push_subscriptions")
      .select("id,endpoint,p256dh,auth,expiration_time")
      .eq("user_id", userId);
    if (subscriptionsError) throw subscriptionsError;
    if (!subscriptions?.length) return Response.json({ ok: true, sent: 0, skipped: "no_subscriptions" }, { headers: corsHeaders });

    const vapid = {
      subject: "https://face-arena-cloudflare.pages.dev",
      publicKey: config.public_key,
      privateKey: config.private_key,
    };
    const payloadData = JSON.stringify({
      title: notification.title || "FACE ARENA",
      body: notification.body || "У тебя новое событие на арене.",
      url: "/#notifications",
      tag: "face-arena-" + notification.id,
    });

    let sent = 0;
    let removed = 0;
    const failures: string[] = [];

    for (const subscription of subscriptions) {
      try {
        const request = await buildPushPayload(
          {
            data: payloadData,
            options: { ttl: 60, urgency: "high" },
          },
          {
            endpoint: subscription.endpoint,
            expirationTime: subscription.expiration_time ?? null,
            keys: { p256dh: subscription.p256dh, auth: subscription.auth },
          },
          vapid,
        );
        const response = await fetch(subscription.endpoint, request);
        if (response.status === 404 || response.status === 410) {
          await admin.from("arena_push_subscriptions").delete().eq("id", subscription.id);
          removed++;
          continue;
        }
        if (!response.ok) {
          const detail = await response.text().catch(() => "");
          failures.push(response.status + (detail ? ": " + detail.slice(0, 120) : ""));
          continue;
        }
        sent++;
      } catch (error) {
        failures.push(error instanceof Error ? error.message.slice(0, 160) : "Push delivery failed");
      }
    }

    return Response.json(
      { ok: true, sent, removed, failed: failures.length },
      { headers: corsHeaders },
    );
  } catch (error) {
    console.error("[FACE ARENA push]", error);
    return Response.json(
      { error: "Push delivery failed" },
      { status: 500, headers: corsHeaders },
    );
  }
});
