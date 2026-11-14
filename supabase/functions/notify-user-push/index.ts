import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const webhookSecret = Deno.env.get("WEBHOOK_SECRET");
  if (!webhookSecret || request.headers.get("x-webhook-secret") !== webhookSecret) {
    return json({ error: "unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY");
  const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@khadamatna.app";
  if (!supabaseUrl || !serviceKey || !vapidPublic || !vapidPrivate) {
    return json({ error: "missing_server_configuration" }, 500);
  }

  let payload: any;
  try { payload = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const row = payload?.record || payload?.data?.record || payload;
  const userId = row?.user_id;
  if (!userId || !row?.id) return json({ skipped: true, reason: "notification_record_missing" });

  const client = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const { data: subscriptions, error } = await client
    .from("push_subscriptions")
    .select("id,endpoint,p256dh,auth_key")
    .eq("user_id", userId);
  if (error) return json({ error: "subscription_lookup_failed", detail: error.message }, 500);
  if (!subscriptions?.length) return json({ sent: 0, reason: "no_subscriptions" });

  webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
  const message = JSON.stringify({
    title: row.title || "خدماتنا",
    body: row.body || "",
    url: row.target_url || "./",
    event_type: row.event_type || "notification",
    tag: row.dedupe_key || row.id,
  });

  let sent = 0, expired = 0, failed = 0;
  await Promise.all(subscriptions.map(async (sub: any) => {
    try {
      await webpush.sendNotification({
        endpoint: sub.endpoint,
        keys: { p256dh: sub.p256dh, auth: sub.auth_key },
      }, message, { TTL: 60 * 60 * 24 });
      sent++;
    } catch (err: any) {
      if (err?.statusCode === 404 || err?.statusCode === 410) {
        await client.from("push_subscriptions").delete().eq("id", sub.id);
        expired++;
      } else {
        failed++;
        console.error("Push delivery failed:", err?.statusCode || err?.message || err);
      }
    }
  }));
  return json({ sent, expired, failed });
});

function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
