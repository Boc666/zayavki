// Известия за плащане от Stripe → удължава достъпа на агенцията.
// Адрес в Stripe (Developers → Webhooks → Add destination):
//   https://<проект>.supabase.co/functions/v1/stripe-webhook
// Събития: checkout.session.completed, invoice.paid,
//          customer.subscription.created, customer.subscription.updated, customer.subscription.deleted
//
// Тайни (Supabase → Edge Functions → Secrets), въвеждат се от собственика:
//   STRIPE_WEBHOOK_SECRET — „Signing secret“ (whsec_…) на webhook-а в Stripe (задължително)
//   STRIPE_ALLOW_TEST     — "1", докато се пробва с тестови карти (sandbox); махнете го след това
//
// Сигурност:
//   - подпис Stripe-Signature (HMAC-SHA256 на "t.тяло"), до 5 минути назад; иначе → 400;
//   - базата се вика със service_role ключа на функцията (не е във фронтенда);
//   - billing_apply() пази всяко известие веднъж и само удължава срока.
// Функцията се публикува с verify_jwt = false.

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = (Deno.env.get("STRIPE_WEBHOOK_SECRET") || "").trim(); // интервал/нов ред при поставяне не пречи
const ALLOW_TEST = (Deno.env.get("STRIPE_ALLOW_TEST") || "").trim() === "1";
const TOLERANCE = 300; // секунди

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
function safeEq(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function hmac(msg: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(msg)));
}
// връща "" при валиден подпис, иначе причината (без тайни данни)
async function verify(header: string, body: string) {
  const parts = header.split(",").map((s) => s.trim().split("="));
  const t = parts.find((p) => p[0] === "t")?.[1];
  const sigs = parts.filter((p) => p[0] === "v1").map((p) => p[1]);
  if (!t || !sigs.length) return "no signature header";
  if (Math.abs(Date.now() / 1000 - Number(t)) > TOLERANCE) return "timestamp too old";
  const expected = await hmac(`${t}.${body}`);
  return sigs.some((s) => safeEq(s, expected)) ? "" : "signature mismatch (wrong STRIPE_WEBHOOK_SECRET?)";
}
const reply = (status: number, text: string) => new Response(text, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
const iso = (sec?: number | null) => (sec ? new Date(sec * 1000).toISOString() : "");

async function apply(p: Record<string, unknown>) {
  const r = await fetch(URL_ + "/rest/v1/rpc/billing_apply", {
    method: "POST",
    headers: { apikey: SERVICE, Authorization: "Bearer " + SERVICE, "Content-Type": "application/json" },
    body: JSON.stringify({ p: { provider: "stripe", ...p } }),
  });
  if (!r.ok) throw new Error("db " + r.status + " " + (await r.text()).slice(0, 200));
  return String(await r.json());
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, "POST only");
  if (!SECRET) return reply(500, "STRIPE_WEBHOOK_SECRET is not set");
  const body = await req.text();
  const bad = await verify(req.headers.get("Stripe-Signature") || "", body);
  if (bad) { console.log("stripe-webhook rejected: " + bad + " (secret length " + SECRET.length + ", starts whsec_: " + SECRET.startsWith("whsec_") + ")"); return reply(400, "bad signature: " + bad); }

  let ev: any;
  try { ev = JSON.parse(body); } catch { return reply(400, "bad json"); }
  if (ev.livemode === false && !ALLOW_TEST) return reply(200, "test mode ignored");
  const o = ev?.data?.object || {};
  const raw = { event: ev.type, id: ev.id, object: o.id, live: !!ev.livemode };
  const key = String(ev.id || "");

  try {
    let res = "ignored " + ev.type;
    if (ev.type === "checkout.session.completed" && o.mode === "subscription") {
      res = await apply({
        event_key: key, kind: "checkout", agency_id: o.client_reference_id || "",
        sub_id: typeof o.subscription === "string" ? o.subscription : o.subscription?.id || "",
        customer_id: typeof o.customer === "string" ? o.customer : o.customer?.id || "", raw,
      });
    } else if (ev.type.startsWith("customer.subscription.")) {
      const item = o.items?.data?.[0] || {};
      const periodEnd = o.current_period_end ?? item.current_period_end ?? null;
      const status = ev.type === "customer.subscription.deleted" || o.status === "canceled" ? "expired"
        : o.cancel_at_period_end || o.cancel_at ? "cancelled"
        : o.status === "trialing" ? "on_trial"
        : o.status === "active" ? "active"
        : o.status || "";
      const interval = item.price?.recurring?.interval;
      res = await apply({
        event_key: key, kind: "sub", sub_id: o.id,
        customer_id: typeof o.customer === "string" ? o.customer : o.customer?.id || "",
        status, plan: interval === "year" ? "Годишен" : interval === "month" ? "Месечен" : "",
        renews_at: status === "active" || status === "on_trial" ? iso(periodEnd) : "",
        ends_at: status === "cancelled" ? iso(o.cancel_at || periodEnd) : "", raw,
      });
    } else if (ev.type === "invoice.paid") {
      const sub = o.subscription || o.parent?.subscription_details?.subscription || "";
      const line = o.lines?.data?.[0] || {};
      res = await apply({
        event_key: key, kind: "payment",
        sub_id: typeof sub === "string" ? sub : sub?.id || "",
        customer_id: typeof o.customer === "string" ? o.customer : o.customer?.id || "",
        amount: Number(o.amount_paid || 0) / 100, currency: o.currency || "eur",
        period_end: iso(line.period?.end), plan: o.billing_reason === "subscription_create" ? "първо плащане" : "подновяване", raw,
      });
    }
    // „retry“: още не знаем чия е (известието дойде преди checkout-а) → 500, Stripe опитва пак
    if (res === "retry") return reply(500, "subscription not linked yet, retry");
    return reply(200, res);
  } catch (e) {
    return reply(500, String((e as Error).message || e));
  }
});
