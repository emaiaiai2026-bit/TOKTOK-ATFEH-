import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// المفتاح السري الجديد (sb_secret) لو موجود، وإلا المفتاح القديم كاحتياطي
function secretKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (keys && typeof keys.default === "string" && keys.default) return keys.default;
  } catch (_) { /* نكمل للمفتاح القديم */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKey(),
  { auth: { persistSession: false } },
);

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT")!,
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

function km(aLat: number, aLng: number, bLat: number, bLng: number) {
  const R = 6371;
  const r = (x: number) => x * Math.PI / 180;
  const dLat = r(bLat - aLat);
  const dLng = r(bLng - aLng);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }

  let body: { ride?: Record<string, any> };
  try {
    body = await req.json();
  } catch {
    return new Response("invalid JSON", { status: 400 });
  }

  const ride = body.ride;
  if (!ride || ride.status !== "requested") {
    return new Response("skip");
  }

  const rejected = new Set<string>(ride.rejected_drivers ?? []);
  const vehicle = ride.vehicle_type ?? "tuktuk";

  const { data: settings, error: settingsError } = await supabase
    .from("settings").select("search_radius_km").eq("id", 1).maybeSingle();
  if (settingsError) {
    console.error("Settings query failed:", settingsError);
    return new Response("settings query failed", { status: 500 });
  }
  const radius = Number(settings?.search_radius_km ?? 3) * 2;

  const { data: drivers, error: driversError } = await supabase
    .from("profiles").select("id,lat,lng")
    .eq("is_driver", true).eq("is_approved", true).eq("is_blocked", false)
    .eq("is_available", true).eq("vehicle_type", vehicle)
    .not("lat", "is", null).not("lng", "is", null);
  if (driversError) {
    console.error("Drivers query failed:", driversError);
    return new Response("drivers query failed", { status: 500 });
  }

  const pickupLat = Number(ride.pickup_lat);
  const pickupLng = Number(ride.pickup_lng);
  if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng)) {
    return new Response("invalid pickup coordinates", { status: 400 });
  }

  const near = (drivers ?? [])
    .filter((d) => d.id !== ride.customer_id)
    .filter((d) => !rejected.has(d.id))
    .filter((d) => Number.isFinite(Number(d.lat)) && Number.isFinite(Number(d.lng)))
    .map((d) => ({ id: d.id, dist: km(Number(d.lat), Number(d.lng), pickupLat, pickupLng) }))
    .filter((d) => d.dist <= radius)
    .sort((a, b) => a.dist - b.dist)
    .slice(0, 20);
  if (!near.length) return new Response("no drivers");

  const { data: busy, error: busyError } = await supabase
    .from("rides").select("driver_id")
    .in("status", ["accepted", "arrived", "started"])
    .in("driver_id", near.map((d) => d.id));
  if (busyError) {
    console.error("Busy drivers query failed:", busyError);
    return new Response("busy drivers query failed", { status: 500 });
  }

  const busyIds = new Set((busy ?? []).map((b) => b.driver_id));
  const free = near.filter((d) => !busyIds.has(d.id));
  if (!free.length) return new Response("no free drivers");

  const distances = new Map(free.map((d) => [d.id, d.dist]));

  const { data: subs, error: subsError } = await supabase
    .from("push_subscriptions").select("id,user_id,endpoint,p256dh,auth_key")
    .in("user_id", free.map((d) => d.id));
  if (subsError) {
    console.error("Subscriptions query failed:", subsError);
    return new Response("subscriptions query failed", { status: 500 });
  }

  let sent = 0;
  await Promise.all((subs ?? []).map(async (sub) => {
    const distance = distances.get(sub.user_id);
    if (distance === undefined) return;

    const payload = JSON.stringify({
      title: "طلب رحلة جديد",
      body: `${ride.price} جنيه تقريباً • يبعد ${distance.toFixed(1)} كم عنك`,
      url: "./driver-v22.html",
      rideId: ride.id,
      event_type: "ride_requested",
      tag: `ride-${ride.id}`,
    });

    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth_key } },
        payload,
        { TTL: 120, urgency: "high" },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      console.error("Push notification failed:", code, e);
      if (code === 404 || code === 410) {
        const { error: deleteError } = await supabase
          .from("push_subscriptions").delete().eq("id", sub.id);
        if (deleteError) console.error("Expired subscription cleanup failed:", deleteError);
      }
    }
  }));

  const { error: updateError } = await supabase
    .from("rides").update({ notified_at: new Date().toISOString() }).eq("id", ride.id);
  if (updateError) console.error("Ride notified_at update failed:", updateError);

  return new Response(JSON.stringify({ sent }), {
    headers: { "Content-Type": "application/json" },
  });
});
