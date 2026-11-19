// Известия за плащане от Lemon Squeezy → удължава достъпа на агенцията.
// Адрес за webhook в Lemon Squeezy: https://<проект>.supabase.co/functions/v1/billing-webhook
//
// Тайни (Supabase → Edge Functions → Secrets), въвеждат се от собственика:
//   LEMON_WEBHOOK_SECRET — „Signing secret“ от настройките на webhook-а в Lemon Squeezy (задължително)
//   LEMON_ALLOW_TEST     — "1" само в тестовия проект: приема плащания с тестови карти
//
// Сигурност:
//   - всяко известие се проверява с HMAC-SHA256 подпис (X-Signature); без валиден подпис → 401;
//   - базата се вика с service_role ключа, който Supabase дава автоматично на функцията (не е във фронтенда);
//   - billing_apply() пази всяко известие веднъж, срокът само се удължава.
// Функцията се публикува с verify_jwt = false (Lemon Squeezy не праща вход в Supabase).

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("LEMON_WEBHOOK_SECRET") || "";
const ALLOW_TEST = Deno.env.get("LEMON_ALLOW_TEST") === "1";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
function safeEq(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function sign(body: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
}
const reply = (status: number, text: string) => new Response(text, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });

async function apply(p: Record<string, unknown>) {
  const r = await fetch(URL_ + "/rest/v1/rpc/billing_apply", {
    method: "POST",
    headers: { apikey: SERVICE, Authorization: "Bearer " + SERVICE, "Content-Type": "application/json" },
    body: JSON.stringify({ p }),
  });
  if (!r.ok) throw new Error("db " + r.status + " " + (await r.text()).slice(0, 200));
  return await r.json();
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, "POST only");
  if (!SECRET) return reply(500, "LEMON_WEBHOOK_SECRET is not set");
  const body = await req.text();
  const got = (req.headers.get("X-Signature") || "").trim().toLowerCase();
  if (!got || !safeEq(got, await sign(body))) return reply(401, "bad signature");

  let ev: any;
  try { ev = JSON.parse(body); } catch { return reply(400, "bad json"); }
  const meta = ev?.meta || {}, data = ev?.data || {}, at = data.attributes || {};
  const name: string = meta.event_name || "";
  if (meta.test_mode && !ALLOW_TEST) return reply(200, "test mode ignored");
  const agency = meta.custom_data?.agency_id || "";
  const raw = { event: name, id: data.id, test: !!meta.test_mode, status: at.status ?? null };

  try {
    if (name.startsWith("subscription_") && data.type === "subscriptions") {
      const res = await apply({
        event_key: `${name}:${data.id}:${at.updated_at || ""}`,
        kind: "sub", agency_id: agency, sub_id: String(data.id),
        status: at.status || "", plan: [at.product_name, at.variant_name].filter(Boolean).join(" · "),
        renews_at: at.renews_at || "", ends_at: at.ends_at || "",
        portal_url: at.urls?.customer_portal || "", raw,
      });
      return reply(200, String(res));
    }
    if (name === "subscription_payment_success" && data.type === "subscription-invoices") {
      const res = await apply({
        event_key: `pay:${data.id}`, kind: "payment", agency_id: agency,
        amount: Number(at.total || 0) / 100, currency: at.currency || "EUR",
        plan: at.billing_reason === "initial" ? "първо плащане" : "подновяване", raw,
      });
      return reply(200, String(res));
    }
    return reply(200, "ignored " + name);
  } catch (e) {
    // 500 → Lemon Squeezy опитва пак по-късно; повторението е безопасно (event_key)
    return reply(500, String((e as Error).message || e));
  }
});
