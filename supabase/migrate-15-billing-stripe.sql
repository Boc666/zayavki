-- ============================================================
-- Миграция 15: плащане с карта и през Stripe (Payment Links + Managed Payments)
--
-- Разлики от Lemon Squeezy:
--   - агенцията идва само в checkout.session.completed (client_reference_id в линка);
--     следващите известия (подновяване, отказ) носят само номера на абонамента/клиента →
--     пазим връзката sub_id / customer_id → агенция в billing_subscriptions;
--   - ако известие за непознат абонамент дойде преди checkout-а, billing_apply връща 'retry',
--     НЕ го записва и Edge функцията отговаря 500 → Stripe го праща пак след малко;
--   - при завършено плащане достъпът веднага става поне 3 дни напред (докато дойде фактурата),
--     а платената фактура удължава до края на платения период + 2 дни.
--
-- Само добавя и разширява; съществуващите данни не се пипат.
-- ============================================================
set search_path = public;

alter table billing_subscriptions add column if not exists customer_id text;
create index if not exists billing_subscriptions_sub_idx on billing_subscriptions (sub_id);
create index if not exists billing_subscriptions_cust_idx on billing_subscriptions (customer_id);

create or replace function public.billing_apply(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  ag uuid; a agencies; new_until timestamptz; n int;
  prov text := coalesce(nullif(p->>'provider',''), 'lemonsqueezy');
  pname text := case coalesce(nullif(p->>'provider',''), 'lemonsqueezy') when 'stripe' then 'Stripe' else 'Lemon Squeezy' end;
begin
  -- 1) коя агенция: изрично подадена → по номер на абонамента → по клиент
  begin ag := nullif(p->>'agency_id','')::uuid; exception when others then ag := null; end;
  if ag is not null and not exists (select 1 from agencies where id = ag) then ag := null; end if;
  if ag is null and nullif(p->>'sub_id','') is not null then
    select agency_id into ag from billing_subscriptions where sub_id = p->>'sub_id' limit 1; end if;
  if ag is null and nullif(p->>'customer_id','') is not null then
    select agency_id into ag from billing_subscriptions where customer_id = p->>'customer_id' limit 1; end if;
  if ag is null then
    -- Stripe: още не знаем чий е → без запис, за да може повторното изпращане да мине
    if prov = 'stripe' then return 'retry'; end if;
    insert into billing_events (event_key, kind, result, raw) values (p->>'event_key', p->>'kind', 'unknown agency', p->'raw')
      on conflict (event_key) do nothing;
    return 'unknown agency';
  end if;
  select * into a from agencies where id = ag;

  -- 2) всяко известие само веднъж
  insert into billing_events (event_key, kind, agency_id, raw) values (p->>'event_key', p->>'kind', a.id, p->'raw')
    on conflict (event_key) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'duplicate'; end if;

  -- 3a) завършено плащане (Stripe checkout): връзка абонамент ↔ агенция + незабавен достъп
  if p->>'kind' = 'checkout' then
    insert into billing_subscriptions as b (agency_id, provider, sub_id, customer_id, status, plan, portal_url, updated_at)
      values (a.id, prov, nullif(p->>'sub_id',''), nullif(p->>'customer_id',''), 'active', nullif(p->>'plan',''), nullif(p->>'portal_url',''), now())
      on conflict (agency_id) do update set provider = excluded.provider,
        sub_id = coalesce(excluded.sub_id, b.sub_id), customer_id = coalesce(excluded.customer_id, b.customer_id),
        status = 'active', plan = coalesce(excluded.plan, b.plan), portal_url = coalesce(excluded.portal_url, b.portal_url), updated_at = now();
    if a.access_until is not null and a.access_until < now() + interval '3 days' then
      update agencies set access_until = now() + interval '3 days' where id = a.id;
      perform _plog(a.id, 'Плащане с карта (' || pname || '): временен достъп до фактурата', now() + interval '3 days', '');
    end if;
    update billing_events set result = 'ok' where event_key = p->>'event_key';
    return 'ok';
  end if;

  -- 3b) състояние на абонамента
  if p->>'kind' = 'sub' then
    insert into billing_subscriptions as b (agency_id, provider, sub_id, customer_id, status, plan, renews_at, ends_at, portal_url, updated_at)
      values (a.id, prov, nullif(p->>'sub_id',''), nullif(p->>'customer_id',''), p->>'status', nullif(p->>'plan',''),
              nullif(p->>'renews_at','')::timestamptz, nullif(p->>'ends_at','')::timestamptz,
              nullif(p->>'portal_url',''), now())
      on conflict (agency_id) do update set provider = excluded.provider,
        sub_id = coalesce(excluded.sub_id, b.sub_id), customer_id = coalesce(excluded.customer_id, b.customer_id),
        status = excluded.status, plan = coalesce(excluded.plan, b.plan),
        renews_at = excluded.renews_at, ends_at = excluded.ends_at,
        portal_url = coalesce(excluded.portal_url, b.portal_url), updated_at = now();
    new_until := case
      when p->>'status' in ('active','on_trial') then nullif(p->>'renews_at','')::timestamptz
      when p->>'status' = 'cancelled'           then nullif(p->>'ends_at','')::timestamptz
      else null end;
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

  -- 3c) платена сума (+ при Stripe: краят на платения период от фактурата)
  if p->>'kind' = 'payment' then
    if coalesce((p->>'amount')::numeric, 0) > 0 then
      insert into payments (agency_id, paid_on, amount, note)
        values (a.id, current_date, (p->>'amount')::numeric,
                'Карта (' || pname || ')' || coalesce(' · ' || nullif(p->>'plan',''), '')
                  || case when upper(coalesce(p->>'currency','EUR')) <> 'EUR' then ' · ' || upper(p->>'currency') else '' end);
      perform _plog(a.id, 'Плащане с карта ' || to_char((p->>'amount')::numeric, 'FM999999990.00') || ' ' || upper(coalesce(p->>'currency','EUR')), null, coalesce(p->>'plan',''));
    end if;
    new_until := nullif(p->>'period_end','')::timestamptz;
    if new_until is not null and a.access_until is not null then
      new_until := new_until + interval '2 days';
      if new_until > a.access_until then
        update agencies set access_until = new_until where id = a.id;
        perform _plog(a.id, 'Абонамент с карта', new_until, coalesce(p->>'plan',''));
      end if;
      update billing_subscriptions set renews_at = nullif(p->>'period_end','')::timestamptz, updated_at = now() where agency_id = a.id;
    end if;
    update billing_events set result = 'ok' where event_key = p->>'event_key';
    return 'ok';
  end if;

  update billing_events set result = 'ignored' where event_key = p->>'event_key';
  return 'ignored';
end $$;
revoke all on function public.billing_apply(jsonb) from public, anon, authenticated;
grant execute on function public.billing_apply(jsonb) to service_role;

-- my_billing: + доставчик и общ линк към страницата за клиенти (Stripe Customer portal)
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
      'on', coalesce((s->>'on')::boolean, false), 'provider', coalesce(s->>'provider','stripe'),
      'monthly_url', s->>'monthly_url', 'yearly_url', s->>'yearly_url',
      'monthly_price', s->'monthly_price', 'yearly_price', s->'yearly_price'),
    'sub', case when b.agency_id is null then null else jsonb_build_object(
      'status', b.status, 'plan', b.plan, 'renews_at', b.renews_at, 'ends_at', b.ends_at,
      'portal_url', coalesce(b.portal_url, s->>'portal_url')) end);
end $$;
revoke all on function public.my_billing() from public, anon;
grant execute on function public.my_billing() to authenticated;

-- platform_billing_set: + доставчик и линк към страницата за клиенти
create or replace function public.platform_billing_set(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  m text := nullif(trim(coalesce(p->>'monthly_url','')),'');
  y text := nullif(trim(coalesce(p->>'yearly_url','')),'');
  pu text := nullif(trim(coalesce(p->>'portal_url','')),'');
  pr text := case when p->>'provider' = 'lemonsqueezy' then 'lemonsqueezy' else 'stripe' end;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if (m is not null and m !~ '^https://') or (y is not null and y !~ '^https://') or (pu is not null and pu !~ '^https://') then
    raise exception 'Адресите трябва да започват с https://';
  end if;
  update platform_settings set billing = jsonb_build_object(
    'on', coalesce((p->>'on')::boolean, false), 'provider', pr,
    'monthly_url', m, 'yearly_url', y, 'portal_url', pu,
    'monthly_price', coalesce((p->>'monthly_price')::numeric, 69.99),
    'yearly_price',  coalesce((p->>'yearly_price')::numeric, 690)) where id = 1;
end $$;
revoke all on function public.platform_billing_set(jsonb) from public, anon;
grant execute on function public.platform_billing_set(jsonb) to authenticated;

notify pgrst, 'reload schema';
