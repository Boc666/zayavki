// Команди към бота в Telegram (/stats, /trials, /paid, /help) → отговор в същия чат.
// Адрес (задава се с setWebhook, заедно със secret_token):
//   https://<проект>.supabase.co/functions/v1/tg-bot
//
// Сигурност:
//   - Telegram праща заглавка X-Telegram-Bot-Api-Secret-Token; проверява се в базата
//     срещу тайната telegram_hook_secret във Vault (функцията не я знае и не я пази);
//   - отговаря се само на чата на собственика (telegram_chat_id) — чужди хора не получават нищо;
//   - базата се вика със service_role ключа на функцията; цялата логика е в _tg_command().
// Функцията се публикува с verify_jwt = false. Винаги връща 200, за да не повтаря Telegram.

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const secret = req.headers.get("x-telegram-bot-api-secret-token") || "";
  if (!secret) return new Response("ok");
  let u: any;
  try { u = await req.json(); } catch { return new Response("ok"); }
  const m = u?.message || u?.edited_message;
  if (!m || typeof m.text !== "string" || !m.chat) return new Response("ok");
  try {
    const r = await fetch(URL_ + "/rest/v1/rpc/_tg_command", {
      method: "POST",
      headers: { apikey: SERVICE, Authorization: "Bearer " + SERVICE, "Content-Type": "application/json" },
      body: JSON.stringify({ p_secret: secret, p_chat: String(m.chat.id), p_text: m.text.slice(0, 200) }),
    });
    if (!r.ok) console.error("db", r.status, (await r.text()).slice(0, 200));
  } catch (e) {
    console.error("tg-bot", String(e).slice(0, 200));
  }
  return new Response("ok");
});
