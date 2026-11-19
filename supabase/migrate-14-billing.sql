-- ============================================================
-- Миграция 14: плащане на абонамента с карта (Lemon Squeezy)
--
-- Как работи:
--   1. Администраторът на агенцията натиска „Плати с карта“ → отваря се страницата за плащане
--      на Lemon Squeezy (адресите се пазят в platform_settings.billing, собственикът ги въвежда).
--   2. Lemon Squeezy праща известие (webhook) до Edge функцията billing-webhook.
--      Тя проверява подписа и вика billing_apply() със service_role ключа.
--   3. billing_apply() удължава access_until до края на платения период + 2 дни
--      и записва плащането в payments (виждат се в панела на собственика).
--
-- Само добавя: нови колона, 2 таблици и 3 функции. Нищо не се трие и не се променя.
-- ============================================================
set search_path = public;

-- настройки за плащането (адреси на страниците за плащане, цени, вкл./изкл.)
alter table platform_settings add column if not exists billing jsonb not null default '{}'::jsonb;

-- последното известно състояние на абонамента на всяка агенция
create table if not exists billing_subscriptions (
  agency_id   uuid primary key references agencies(id),
  provider    text not null default 'lemonsqueezy',
  sub_id      text,
  status      text,
  plan        text,
  renews_at   timestamptz,
  ends_at     timestamptz,
  portal_url  text,
  updated_at  timestamptz not null default now()
);
alter table billing_subscriptions enable row level security; -- без политики: достъп само през функциите

-- всяко получено известие веднъж (повторно изпратено известие не удължава два пъти)
create table if not exists billing_events (
  event_key   text primary key,
  agency_id   uuid,
  kind        text,
  result      text,
  raw         jsonb,
  created_at  timestamptz not null default now()
);
alter table billing_events enable row level security; -- без политики

-- ------------------------------------------------------------
-- billing_apply — вика се САМО от Edge функцията (service_role).
-- p = {event_key, kind:'sub'|'payment', agency_id, sub_id, status, plan,
--      renews_at, ends_at, portal_url, amount, currency, raw}
-- ------------------------------------------------------------
create or replace function public.billing_apply(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  ag uuid; a agencies; new_until timestamptz; n int;
begin
  insert into billing_events (event_key, kind, raw) values (p->>'event_key', p->>'kind', p->'raw')
    on conflict (event_key) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'duplicate'; end if;

  begin ag := (p->>'agency_id')::uuid; exception when others then ag := null; end;
  select * into a from agencies where id = ag;
  if a.id is null then
    update billing_events set result = 'unknown agency' where event_key = p->>'event_key';
    return 'unknown agency';
  end if;
  update billing_events set agency_id = a.id where event_key = p->>'event_key';

  if p->>'kind' = 'sub' then
    insert into billing_subscriptions as b (agency_id, sub_id, status, plan, renews_at, ends_at, portal_url, updated_at)
      values (a.id, p->>'sub_id', p->>'status', p->>'plan',
              nullif(p->>'renews_at','')::timestamptz, nullif(p->>'ends_at','')::timestamptz,
              nullif(p->>'portal_url',''), now())
      on conflict (agency_id) do update set sub_id = excluded.sub_id, status = excluded.status, plan = excluded.plan,
        renews_at = excluded.renews_at, ends_at = excluded.ends_at,
        portal_url = coalesce(excluded.portal_url, b.portal_url), updated_at = now();
    -- платеният период: активен → до следващото подновяване; отказан → до края на платеното
    new_until := case
      when p->>'status' in ('active','on_trial') then nullif(p->>'renews_at','')::timestamptz
      when p->>'status' = 'cancelled'           then nullif(p->>'ends_at','')::timestamptz
      else null end;
    -- „без срок“ (null) не се пипа; срокът само се удължава, никога не се скъсява
    if new_until is not null and a.access_until is not null then
      new_until := new_until + interval '2 days';
      if new_until > a.access_until then
        update agencies set access_until = new_until where id = a.id;
        perform _plog(a.id, 'Абонамент с карта', new_until, coalesce(p->>'plan',''));
      end if;
    end if;
    update billing_events set result = 'ok' where event_key = p->>'event_key';
    return 'ok';
  end if;

  if p->>'kind' = 'payment' then
    if coalesce((p->>'amount')::numeric, 0) > 0 then
      insert into payments (agency_id, paid_on, amount, note)
        values (a.id, current_date, (p->>'amount')::numeric,
                'Карта (Lemon Squeezy)' || coalesce(' · ' || nullif(p->>'plan',''), '')
                  || case when upper(coalesce(p->>'currency','EUR')) <> 'EUR' then ' · ' || upper(p->>'currency') else '' end);
      perform _plog(a.id, 'Плащане с карта ' || to_char((p->>'amount')::numeric, 'FM999999990.00') || ' ' || upper(coalesce(p->>'currency','EUR')), null, coalesce(p->>'plan',''));
    end if;
    update billing_events set result = 'ok' where event_key = p->>'event_key';
    return 'ok';
  end if;

  update billing_events set result = 'ignored' where event_key = p->>'event_key';
  return 'ignored';
end $$;
revoke all on function public.billing_apply(jsonb) from public, anon, authenticated;
grant execute on function public.billing_apply(jsonb) to service_role;

-- ------------------------------------------------------------
-- my_billing — за администратора на агенцията.
-- Работи и когато срокът е изтекъл (за да може да плати), затова не ползва my_agency().
-- ------------------------------------------------------------
create or replace function public.my_billing() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ag uuid; a agencies; s jsonb; b billing_subscriptions;
begin
  select p.agency_id into ag from profiles p join agencies x on x.id = p.agency_id
    where p.id = auth.uid() and p.active and p.role = 'admin' and x.active;
  if ag is null then select acting_agency into ag from platform_admins where id = auth.uid(); end if;
  if ag is null then return jsonb_build_object('admin', false); end if;
  select * into a from agencies where id = ag;
  select coalesce(billing, '{}'::jsonb) into s from platform_settings where id = 1;
  select * into b from billing_subscriptions where agency_id = ag;
  return jsonb_build_object(
    'admin', true, 'agency_id', a.id, 'code', a.code,
    'until', a.access_until, 'expired', a.access_until is not null and a.access_until <= now(),
    'checkout', jsonb_build_object(
      'on', coalesce((s->>'on')::boolean, false),
      'monthly_url', s->>'monthly_url', 'yearly_url', s->>'yearly_url',
      'monthly_price', s->'monthly_price', 'yearly_price', s->'yearly_price'),
    'sub', case when b.agency_id is null then null else jsonb_build_object(
      'status', b.status, 'plan', b.plan, 'renews_at', b.renews_at, 'ends_at', b.ends_at, 'portal_url', b.portal_url) end);
end $$;
revoke all on function public.my_billing() from public, anon;
grant execute on function public.my_billing() to authenticated;

-- ------------------------------------------------------------
-- platform_billing_set — собственикът въвежда адресите и цените
-- ------------------------------------------------------------
create or replace function public.platform_billing_set(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare m text := nullif(trim(coalesce(p->>'monthly_url','')),''); y text := nullif(trim(coalesce(p->>'yearly_url','')),'');
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if (m is not null and m !~ '^https://') or (y is not null and y !~ '^https://') then
    raise exception 'Адресите за плащане трябва да започват с https://';
  end if;
  update platform_settings set billing = jsonb_build_object(
    'on', coalesce((p->>'on')::boolean, false),
    'monthly_url', m, 'yearly_url', y,
    'monthly_price', coalesce((p->>'monthly_price')::numeric, 39),
    'yearly_price',  coalesce((p->>'yearly_price')::numeric, 390)) where id = 1;
end $$;
revoke all on function public.platform_billing_set(jsonb) from public, anon;
grant execute on function public.platform_billing_set(jsonb) to authenticated;

-- начални цени (без адреси → бутоните не се показват, докато собственикът не ги въведе)
update platform_settings set billing = jsonb_build_object('on', false, 'monthly_price', 39, 'yearly_price', 390)
  where id = 1 and (billing is null or billing = '{}'::jsonb);

notify pgrst, 'reload schema';
