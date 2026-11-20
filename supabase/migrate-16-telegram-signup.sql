-- ============================================================
-- Миграция 16: известие в Telegram при нов пробен период (самостоятелна регистрация)
-- Само добавя — не трие и не променя данни.
--
-- Как работи: self_signup() записва ред в signup_log → тригер → съобщение до бота в Telegram.
-- Изпраща се през pg_net (асинхронно, само след успешен commit), затова регистрацията
-- никога не се бави и не се проваля заради Telegram.
--
-- Тайни (Supabase → Integrations → Vault), не са в кода:
--   telegram_bot_token — ключът от @BotFather (въвежда се от собственика)
--   telegram_chat_id   — номерът на чата със собственика (записва се при свързването)
-- Ако някоя липсва, тригерът просто не праща нищо.
-- ============================================================
set search_path = public;

create extension if not exists pg_net;

create or replace function public._tg_send(p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; chat text;
begin
  select trim(decrypted_secret) into tok  from vault.decrypted_secrets where name = 'telegram_bot_token' limit 1;
  select trim(decrypted_secret) into chat from vault.decrypted_secrets where name = 'telegram_chat_id'   limit 1;
  if coalesce(tok, '') = '' or coalesce(chat, '') = '' then return; end if;
  perform net.http_post(
    url     := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body    := jsonb_build_object('chat_id', chat, 'text', p_text, 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
exception when others then
  raise warning 'telegram: %', sqlerrm;   -- известието никога не спира регистрацията
end $$;
revoke all on function public._tg_send(text) from public, anon, authenticated;

create or replace function public._tg_on_signup() returns trigger
language plpgsql security definer set search_path = public as $$
declare a record; adm record; ph text; n bigint;
begin
  select id, name, code, access_until into a from agencies where code = new.code;
  if a.id is null then return new; end if;
  select p.name, p.username into adm from profiles p where p.agency_id = a.id and p.role = 'admin' limit 1;
  select nullif(trim(value->'value'->>'gsm'), '') into ph from records
   where agency_id = a.id and store = 'meta' and key = 'settings';
  select count(*) into n from signup_log;
  perform _tg_send(format(
    E'🆕 Нов пробен период в Memoriox\n\nАгенция: %s\nКод: %s\nАдминистратор: %s (%s)\nТелефон: %s\nПробен до: %s\n\nСамостоятелни регистрации общо: %s',
    a.name, a.code, coalesce(adm.name, '—'), coalesce(adm.username, '—'), coalesce(ph, 'не е въведен'),
    to_char(a.access_until at time zone 'Europe/Sofia', 'DD.MM.YYYY'), n));
  return new;
exception when others then
  raise warning 'telegram signup: %', sqlerrm;
  return new;
end $$;
revoke all on function public._tg_on_signup() from public, anon, authenticated;

drop trigger if exists signup_log_telegram on public.signup_log;
create trigger signup_log_telegram after insert on public.signup_log
  for each row execute function public._tg_on_signup();
