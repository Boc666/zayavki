// Линк за календара (Google / Apple / Outlook): https://<проект>.supabase.co/functions/v1/ical?t=<token>
// Без вход — достъпът е по тайния линк на служителя (нов линк от програмата спира стария).
// Данните идват от функцията calendar_feed в базата (с публичния ключ).
const URL_ = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const esc = (s: string) => String(s ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
const fold = (line: string) => { // RFC 5545: редове до 75 байта
  const out: string[] = []; let cur = ""; let bytes = 0;
  for (const ch of line) { const b = new TextEncoder().encode(ch).length; if (bytes + b > 73) { out.push(cur); cur = " " + ch; bytes = 1 + b; } else { cur += ch; bytes += b; } }
  out.push(cur); return out.join("\r\n");
};
const pad = (n: number) => String(n).padStart(2, "0");
const ymd = (d: string) => d.replace(/-/g, "");
function parseTime(t: string): [number, number] | null {
  const m = String(t || "").trim().match(/^(\d{1,2})[.:,](\d{2})$|^(\d{1,2})$/);
  if (!m) return null; const h = Number(m[1] ?? m[3]), mi = Number(m[2] ?? 0);
  return h < 24 && mi < 60 ? [h, mi] : null;
}

Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get("t") || "";
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(token)) return new Response("Not found", { status: 404 });
  const r = await fetch(`${URL_}/rest/v1/rpc/calendar_feed`, {
    method: "POST", headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: token }),
  });
  const feed = r.ok ? await r.json() : null;
  if (!feed) return new Response("Not found", { status: 404 });

  const now = new Date(), stamp = `${now.getUTCFullYear()}${pad(now.getUTCMonth() + 1)}${pad(now.getUTCDate())}T${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}00Z`;
  const L = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Zayavki//BG", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    fold("X-WR-CALNAME:" + esc("Ритуали — " + (feed.agency || ""))), "X-WR-TIMEZONE:Europe/Sofia", "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
    "BEGIN:VTIMEZONE", "TZID:Europe/Sofia",
    "BEGIN:DAYLIGHT", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0300", "TZNAME:EEST", "DTSTART:19700329T030000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU", "END:DAYLIGHT",
    "BEGIN:STANDARD", "TZOFFSETFROM:+0300", "TZOFFSETTO:+0200", "TZNAME:EET", "DTSTART:19701025T040000", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU", "END:STANDARD",
    "END:VTIMEZONE"];
  for (const it of (feed.items || [])) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(it.date || "")) continue;
    L.push("BEGIN:VEVENT", `UID:${it.id}@zayavki`, `DTSTAMP:${stamp}`);
    const t = parseTime(it.time);
    if (t) {
      const end = t[0] * 60 + t[1] + (it.kind === "ritual" ? 90 : 60), eh = Math.min(23, Math.floor(end / 60)), em = end >= 24 * 60 ? 59 : end % 60;
      L.push(`DTSTART;TZID=Europe/Sofia:${ymd(it.date)}T${pad(t[0])}${pad(t[1])}00`, `DTEND;TZID=Europe/Sofia:${ymd(it.date)}T${pad(eh)}${pad(em)}00`);
    } else {
      const d = new Date(it.date + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + 1);
      L.push(`DTSTART;VALUE=DATE:${ymd(it.date)}`, `DTEND;VALUE=DATE:${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`);
    }
    L.push(fold("SUMMARY:" + esc(it.title || "")));
    if (it.place) L.push(fold("LOCATION:" + esc(it.place)));
    const desc = [it.note, it.owner ? "Отговорник: " + it.owner : ""].filter(Boolean).join("\n");
    if (desc) L.push(fold("DESCRIPTION:" + esc(desc)));
    L.push("END:VEVENT");
  }
  L.push("END:VCALENDAR");
  return new Response(L.join("\r\n") + "\r\n", {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "private, max-age=300", "Content-Disposition": 'inline; filename="rituali.ics"' },
  });
});
