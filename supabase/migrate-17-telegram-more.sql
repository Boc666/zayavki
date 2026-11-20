-- ============================================================
-- Миграция 17: още известия в Telegram за собственика (изисква миграция 16)
-- Само добавя — не трие и не променя данни на агенциите.
--
--  💳 плащане с карта (и „нов абонат“ при първото)          — веднага
--  ⚠️ неуспешно плащане / отказан / приключил абонамент       — веднага
--  🌅 сутрешен преглед (всеки ден 07:00 UTC = 9:00 зимно време):
--       пробни, които изтичат до 3 дни · изтекли без плащане · агенции без вход 7 дни
--  📊 седмичен отчет (понеделник 07:00 UTC)
--  🤖 команди към бота: /stats /trials /paid /help  (през Edge функцията tg-bot)
--
-- Нищо от заявките на агенциите (починали, клиенти, суми) не се праща — само абонаментите.
-- Тайни във Vault: telegram_bot_token, telegram_chat_id (от миграция 16),
--                  telegram_hook_secret (създава се тук, за проверка, че командата идва от Telegram).
-- ============================================================
set search_path = public;

create extension if not exists pg_cron with schema pg_catalog;

-- кое известие вече е пратено (за да не се повтаря всяка сутрин)
create table if not exists public.tg_sent(
  kind      text not null,
  agency_id uuid not null,
  ref       text not null default '',
  sent_at   timestamptz not null default now(),
  primary key (kind, agency_id, ref)
);
alter table public.tg_sent enable row level security;   -- без политики: само през функциите
revoke all on public.tg_sent from anon, authenticated;

-- ---------- помощни ----------
create or replace function public._tg_eur(x numeric) returns text
language sql immutable as $$ select replace(to_char(coalesce(x,0), 'FM999999990.00'), '.', ',') || ' €' $$;

create or replace function public._tg_date(t timestamptz, p_null text default 'без срок') returns text
language sql stable as $$ select coalesce(to_char(t at time zone 'Europe/Sofia', 'DD.MM.YYYY'), p_null) $$;

-- „Агенция Мир (mir) · Иван Петров · 0888…“
create or replace function public._tg_agency(ag uuid) returns text
language sql stable security definer set search_path = public as $$
  select a.name || ' (' || a.code || ')'
      || coalesce(' · ' || (select p.name from profiles p where p.agency_id = a.id and p.role = 'admin' order by p.created_at limit 1), '')
      || coalesce(' · ' || coalesce(nullif(trim(a.contact_phone), ''),
                    (select nullif(trim(r.value->'value'->>'gsm'), '') from records r
                      where r.agency_id = a.id and r.store = 'meta' and r.key = 'settings')), '')
  from agencies a where a.id = ag $$;

-- плаща ли агенцията (абонамент с карта или някога записано плащане)
create or replace function public._tg_paying(ag uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from billing_subscriptions b where b.agency_id = ag and b.status in ('active','cancelled','past_due','unpaid'))
      or exists (select 1 from payments p where p.agency_id = ag) $$;

-- последен вход на някой от агенцията
create or replace function public._tg_last_login(ag uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(last_login) from profiles where agency_id = ag $$;

-- записва „пратено“; връща true само първия път
create or replace function public._tg_once(p_kind text, ag uuid, p_ref text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into tg_sent(kind, agency_id, ref) values (p_kind, ag, coalesce(p_ref, '')) on conflict do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ---------- 💳 / ⚠️ веднага след известие от Stripe ----------
-- billing_apply() накрая маркира известието result='ok' — тогава всичко (плащане, срок) вече е записано.
create or replace function public._tg_on_billing() returns trigger
language plpgsql security definer set search_path = public as $$
declare p payments; b billing_subscriptions; a agencies; n int; t text;
begin
  if new.agency_id is null or new.result is distinct from 'ok' or old.result is not distinct from 'ok' then return new; end if;
  select * into a from agencies where id = new.agency_id;

  if new.kind = 'payment' then
    select * into p from payments where agency_id = a.id order by created_at desc limit 1;
    if p.id is null or p.created_at < now() - interval '10 minutes' then return new; end if;
    select count(*) into n from payments where agency_id = a.id and note like 'Карта%';
    select * into b from billing_subscriptions where agency_id = a.id;
    perform _tg_send(
      case when n <= 1 then E'🎉 Нов абонат!\n\n' else E'💳 Плащане с карта\n\n' end
      || _tg_agency(a.id) || E'\nСума: ' || _tg_eur(p.amount)
      || coalesce(E'\nПлан: ' || nullif(b.plan, ''), '')
      || E'\nДостъп до: ' || _tg_date((select access_until from agencies where id = a.id)));
  elsif new.kind = 'sub' then
    select * into b from billing_subscriptions where agency_id = a.id;
    t := case b.status
      when 'cancelled' then E'⚠️ Отказан абонамент\n\nАгенцията е спряла подновяването. Има достъп до ' || _tg_date(b.ends_at) || E' — добър момент за обаждане.'
      when 'expired'   then E'❌ Абонаментът приключи\n\nПлатеният период е свършил и няма подновяване.'
      when 'past_due'  then E'⚠️ Неуспешно плащане\n\nКартата не мина. Stripe ще опита пак през следващите дни.'
      when 'unpaid'    then E'⚠️ Неплатен абонамент\n\nНяколко опита за плащане не минаха.'
      when 'incomplete' then E'⚠️ Незавършено плащане\n\nПлащането при абонирането не е потвърдено.'
      when 'incomplete_expired' then E'❌ Плащането при абонирането изтече без потвърждение.'
      else null end;
    if t is not null and _tg_once('sub_' || b.status, a.id, coalesce(b.ends_at::text, '') || coalesce(b.renews_at::text, '')) then
      perform _tg_send(split_part(t, E'\n\n', 1) || E'\n\n' || _tg_agency(a.id) || E'\n' || split_part(t, E'\n\n', 2));
    end if;
  end if;
  return new;
exception when others then
  raise warning 'telegram billing: %', sqlerrm;
  return new;
end $$;

drop trigger if exists billing_events_telegram on public.billing_events;
create trigger billing_events_telegram after update of result on public.billing_events
  for each row execute function public._tg_on_billing();

-- ---------- 🌅 сутрешен преглед ----------
create or replace function public._tg_daily() returns void
language plpgsql security definer set search_path = public as $$
declare r record; s1 text := ''; s2 text := ''; s3 text := ''; d int;
begin
  -- пробни, които изтичат до 3 дни
  for r in select a.id, a.access_until from agencies a
            where a.active and a.access_until > now() and a.access_until <= now() + interval '3 days'
              and not _tg_paying(a.id) order by a.access_until loop
    if _tg_once('trial_end3', r.id, r.access_until::date::text) then
      d := greatest(0, ceil(extract(epoch from (r.access_until - now())) / 86400)::int);
      s1 := s1 || E'\n• ' || _tg_agency(r.id) || ' — ' || case when d <= 1 then 'утре' else 'след ' || d || ' дни' end
                || ' · вход: ' || _tg_date(_tg_last_login(r.id), 'никога');
    end if;
  end loop;
  -- изтекли без плащане (последните 3 дни)
  for r in select a.id, a.access_until from agencies a
            where a.active and a.access_until <= now() and a.access_until > now() - interval '3 days'
              and not _tg_paying(a.id) order by a.access_until loop
    if _tg_once('trial_expired', r.id, r.access_until::date::text) then
      s2 := s2 || E'\n• ' || _tg_agency(r.id) || ' — изтекъл ' || _tg_date(r.access_until);
    end if;
  end loop;
  -- не са влизали 7 дни (само агенции с валиден достъп; веднъж за всеки период без вход)
  for r in select a.id, _tg_last_login(a.id) as ll from agencies a
            where a.active and a.access_until > now()
              and coalesce(_tg_last_login(a.id), a.created_at) < now() - interval '7 days' loop
    if _tg_once('idle7', r.id, coalesce(r.ll::text, 'never')) then
      s3 := s3 || E'\n• ' || _tg_agency(r.id) || ' — последен вход ' || _tg_date(r.ll, 'никога')
                || case when _tg_paying(r.id) then ' (плащащ)' else ' (пробен)' end;
    end if;
  end loop;
  if s1 = '' and s2 = '' and s3 = '' then return; end if;
  perform _tg_send(E'🌅 Сутрешен преглед'
    || case when s1 <> '' then E'\n\n⏳ Пробният период изтича скоро:' || s1 else '' end
    || case when s2 <> '' then E'\n\n❌ Изтекъл пробен период без плащане:' || s2 else '' end
    || case when s3 <> '' then E'\n\n😴 Не са влизали 7 дни:' || s3 else '' end
    || E'\n\nЗа обаждане.');
exception when others then
  raise warning 'telegram daily: %', sqlerrm;
end $$;

-- ---------- 📊 обобщение (седмичен отчет и /stats) ----------
create or replace function public._tg_summary(p_days int, p_title text) returns text
language sql stable security definer set search_path = public as $$
  with ag as (select a.*, _tg_paying(a.id) as paying, _tg_last_login(a.id) as ll from agencies a where a.active),
       pay as (select * from payments where created_at > now() - make_interval(days => p_days))
  select p_title
    || E'\n\nАгенции: ' || (select count(*) from ag)
    || E'\n• плащащи: ' || (select count(*) from ag where paying)
    || E'\n• в пробен период: ' || (select count(*) from ag where not paying and access_until > now())
    || E'\n• с изтекъл достъп: ' || (select count(*) from ag where access_until <= now())
    || E'\n• влизали последните 7 дни: ' || (select count(*) from ag where ll > now() - interval '7 days')
    || E'\n\nЗа последните ' || p_days || ' дни:'
    || E'\n• нови пробни периоди: ' || (select count(*) from signup_log where created_at > now() - make_interval(days => p_days))
    || E'\n• плащания с карта: ' || (select count(*) from pay where note like 'Карта%') || ' · ' || _tg_eur((select sum(amount) from pay where note like 'Карта%'))
    || E'\n• всички плащания: ' || _tg_eur((select sum(amount) from pay))
    || E'\n\nИзтичат до 7 дни без плащане: ' || (select count(*) from ag where not paying and access_until > now() and access_until <= now() + interval '7 days')
$$;

create or replace function public._tg_weekly() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _tg_send(_tg_summary(7, '📊 Седмичен отчет — Memoriox'));
exception when others then
  raise warning 'telegram weekly: %', sqlerrm;
end $$;

-- ---------- 🤖 команди към бота ----------
create or replace function public._tg_command(p_secret text, p_chat text, p_text text) returns text
language plpgsql security definer set search_path = public as $$
declare hook text; owner text; cmd text; s text := ''; r record;
begin
  select trim(decrypted_secret) into hook  from vault.decrypted_secrets where name = 'telegram_hook_secret' limit 1;
  select trim(decrypted_secret) into owner from vault.decrypted_secrets where name = 'telegram_chat_id' limit 1;
  if coalesce(hook, '') = '' or p_secret is distinct from hook then return 'bad secret'; end if;
  if p_chat is distinct from owner then return 'ignored'; end if;   -- чужди хора не получават нищо
  cmd := lower(split_part(split_part(trim(coalesce(p_text, '')), ' ', 1), '@', 1));
  if cmd = '/stats' then
    perform _tg_send(_tg_summary(30, '📊 Състояние в момента'));
  elsif cmd = '/trials' then
    for r in select a.id, a.access_until from agencies a
              where a.active and a.access_until > now() and not _tg_paying(a.id) order by a.access_until loop
      s := s || E'\n• ' || _tg_agency(r.id) || ' — до ' || _tg_date(r.access_until) || ' · вход: ' || _tg_date(_tg_last_login(r.id), 'никога');
    end loop;
    perform _tg_send(E'⏳ Пробни периоди в момента' || case when s = '' then E'\n\nНяма.' else E'\n' || s end);
  elsif cmd = '/paid' then
    for r in select a.id, a.access_until, b.plan, b.status from agencies a left join billing_subscriptions b on b.agency_id = a.id
              where a.active and _tg_paying(a.id) order by a.name loop
      s := s || E'\n• ' || _tg_agency(r.id) || coalesce(' · ' || nullif(r.plan, ''), '')
             || case r.status when 'cancelled' then ' · отказан' when 'past_due' then ' · неуспешно плащане' else '' end
             || ' — до ' || _tg_date(r.access_until);
    end loop;
    perform _tg_send(E'💳 Плащащи агенции' || case when s = '' then E'\n\nОще няма.' else E'\n' || s end);
  else
    perform _tg_send(E'🤖 Memoriox — команди\n\n/stats — състояние в момента\n/trials — кои са в пробен период\n/paid — кои плащат\n\nСам ще ви пиша при нов пробен период, плащане, проблем с плащане, а всяка сутрин — кой изтича или не влиза.');
  end if;
  return 'ok';
end $$;

revoke all on function public._tg_eur(numeric), public._tg_date(timestamptz, text), public._tg_agency(uuid), public._tg_paying(uuid),
  public._tg_last_login(uuid), public._tg_once(text, uuid, text), public._tg_on_billing(), public._tg_daily(),
  public._tg_summary(int, text), public._tg_weekly(), public._tg_command(text, text, text) from public, anon, authenticated;
grant execute on function public._tg_command(text, text, text) to service_role;

-- тайна за проверка на командите от Telegram (създава се веднъж)
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'telegram_hook_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'telegram_hook_secret', 'Проверка, че командата към бота идва от Telegram');
  end if;
end $$;

-- график (UTC): всеки ден 07:00 и всеки понеделник 07:05
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('tg-daily', 'tg-weekly');
end $$;
select cron.schedule('tg-daily',  '0 7 * * *', $$select public._tg_daily()$$);
select cron.schedule('tg-weekly', '5 7 * * 1', $$select public._tg_weekly()$$);
