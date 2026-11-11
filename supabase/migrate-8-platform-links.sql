-- =====================================================================
-- МИГРАЦИЯ 8 — фактури към агенциите, табло на собственика, заявки за регистрация,
-- публични линкове (оферта до клиента, отзив) и линк за календара в телефона.
-- Пуска се след миграции 2, 3 и 6. Само добавя — нищо съществуващо не се променя.
-- Връщане: в края на файла.
-- =====================================================================
begin;

-- ---------- данни на доставчика за фактурите към агенциите ----------
alter table public.platform_settings
  add column if not exists seller_name    text not null default '„Тангра 2012“ ЕООД',
  add column if not exists seller_eik     text not null default '201860492',
  add column if not exists seller_vat     text not null default '',          -- ДДС № (празно = нерегистрирана по ДДС)
  add column if not exists seller_address text not null default 'гр. София, бул. „Овча купел“ 89а',
  add column if not exists seller_mol     text not null default '',
  add column if not exists seller_iban    text not null default '',
  add column if not exists seller_bank    text not null default '',
  add column if not exists invoice_next   bigint not null default 1;

create table if not exists public.platform_invoices (
  id          bigserial primary key,
  number      bigint not null unique,
  agency_id   uuid not null references public.agencies(id) on delete restrict,
  payment_id  bigint references public.payments(id) on delete set null,
  issued_on   date not null default current_date,
  description text not null,
  amount      numeric(10,2) not null,          -- крайна сума
  vat_rate    numeric(5,2) not null default 0,
  data        jsonb not null,                  -- снимка на продавача и купувача към датата на издаване
  cancelled   boolean not null default false,
  created_at  timestamptz not null default now()
);
alter table public.platform_invoices enable row level security;
revoke all on public.platform_invoices from anon, authenticated;

-- ---------- заявки за регистрация (от страницата за вход, без акаунт) ----------
create table if not exists public.agency_signups (
  id             bigserial primary key,
  created_at     timestamptz not null default now(),
  agency_name    text not null,
  code_wanted    text not null default '',
  contact_person text not null default '',
  phone          text not null,
  email          text not null default '',
  city           text not null default '',
  eik            text not null default '',
  note           text not null default '',
  status         text not null default 'pending' check (status in ('pending','approved','rejected')),
  agency_id      uuid references public.agencies(id) on delete set null,
  handled_at     timestamptz
);
alter table public.agency_signups enable row level security;
revoke all on public.agency_signups from anon, authenticated;

-- ---------- публични линкове: оферта до клиента и молба за отзив ----------
create table if not exists public.public_links (
  token        text primary key,
  agency_id    uuid not null references public.agencies(id) on delete cascade,
  kind         text not null check (kind in ('offer','review')),
  ref_key      text not null,                  -- заявката
  data         jsonb not null,                 -- какво вижда клиентът (снимка)
  created_by   text not null default '',
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  opened_at    timestamptz,
  response     jsonb,
  responded_at timestamptz
);
create index if not exists public_links_ref on public.public_links (agency_id, ref_key, created_at desc);
alter table public.public_links enable row level security;
revoke all on public.public_links from anon, authenticated;

-- ---------- линк за календара (iCal) ----------
create table if not exists public.calendar_tokens (
  token      text primary key,
  agency_id  uuid not null references public.agencies(id) on delete cascade,
  user_id    uuid not null,
  only_mine  boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists calendar_tokens_user on public.calendar_tokens (user_id);
alter table public.calendar_tokens enable row level security;
revoke all on public.calendar_tokens from anon, authenticated;

create or replace function public._token() returns text
language sql volatile set search_path = public, extensions as $$
  select translate(encode(gen_random_bytes(18), 'base64'), '+/', '-_')
$$;

-- =====================================================================
-- СОБСТВЕНИК
-- =====================================================================
create or replace function public.platform_seller_set(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update platform_settings set
    seller_name = coalesce(trim(p->>'seller_name'), seller_name), seller_eik = coalesce(trim(p->>'seller_eik'), seller_eik),
    seller_vat = coalesce(trim(p->>'seller_vat'), seller_vat), seller_address = coalesce(trim(p->>'seller_address'), seller_address),
    seller_mol = coalesce(trim(p->>'seller_mol'), seller_mol), seller_iban = coalesce(trim(p->>'seller_iban'), seller_iban),
    seller_bank = coalesce(trim(p->>'seller_bank'), seller_bank),
    invoice_next = greatest(coalesce(nullif(p->>'invoice_next','')::bigint, invoice_next), 1)
  where id = 1;
end $$;

-- фактура за плащане (или ръчна, без плащане)
create or replace function public.platform_issue_invoice(p_agency uuid, p_payment bigint, p_amount numeric, p_description text, p_issued_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s platform_settings; a agencies; n bigint; amt numeric; inv platform_invoices; rate numeric;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  select * into a from agencies where id = p_agency;
  if a.id is null then raise exception 'Няма такава агенция.'; end if;
  if p_payment is not null and exists (select 1 from platform_invoices where payment_id = p_payment and not cancelled) then
    raise exception 'За това плащане вече има фактура.'; end if;
  amt := coalesce(p_amount, (select amount from payments where id = p_payment and agency_id = p_agency));
  if coalesce(amt,0) <= 0 then raise exception 'Сумата трябва да е по-голяма от 0.'; end if;
  select * into s from platform_settings where id = 1 for update;
  n := s.invoice_next;
  update platform_settings set invoice_next = n + 1 where id = 1;
  rate := case when coalesce(s.seller_vat,'') <> '' then 20 else 0 end;
  insert into platform_invoices (number, agency_id, payment_id, issued_on, description, amount, vat_rate, data)
  values (n, a.id, p_payment, coalesce(p_issued_on, current_date), coalesce(nullif(trim(p_description),''), 'Абонамент за система „Заявки“'), amt, rate,
    jsonb_build_object(
      'seller', jsonb_build_object('name', s.seller_name, 'eik', s.seller_eik, 'vat', s.seller_vat, 'address', s.seller_address, 'mol', s.seller_mol, 'iban', s.seller_iban, 'bank', s.seller_bank),
      'buyer',  jsonb_build_object('name', a.name, 'eik', a.eik, 'address', a.address, 'mol', a.contact_person)))
  returning * into inv;
  perform _plog(a.id, 'Фактура № ' || lpad(n::text, 10, '0') || ' за ' || to_char(amt, 'FM999999990.00') || ' €', null);
  return to_jsonb(inv);
end $$;

create or replace function public.platform_invoices_list(p_agency uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object('agency', a.name, 'code', a.code) order by i.number desc)
    from platform_invoices i join agencies a on a.id = i.agency_id where p_agency is null or i.agency_id = p_agency), '[]'::jsonb);
end $$;

create or replace function public.platform_cancel_invoice(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid; n bigint;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update platform_invoices set cancelled = true where id = p_id and not cancelled returning agency_id, number into ag, n;
  if ag is not null then perform _plog(ag, 'Анулирана фактура № ' || lpad(n::text, 10, '0'), null); end if;
end $$;

-- табло: приходи по месеци (последните 12)
create or replace function public.platform_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return jsonb_build_object(
    'months', (select coalesce(jsonb_agg(jsonb_build_object('m', to_char(m, 'YYYY-MM'),
                 'sum', (select coalesce(sum(amount),0) from payments where date_trunc('month', paid_on) = m)) order by m), '[]'::jsonb)
               from generate_series(date_trunc('month', current_date) - interval '11 months', date_trunc('month', current_date), interval '1 month') m),
    'signups_pending', (select count(*) from agency_signups where status = 'pending'),
    'requests_30d', (select count(*) from records where store = 'requests' and (value->>'created') >= to_char(now() - interval '30 days', 'YYYY-MM-DD')));
end $$;

-- заявки за регистрация
create or replace function public.platform_signups() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s) order by (s.status = 'pending') desc, s.created_at desc) from agency_signups s), '[]'::jsonb);
end $$;

create or replace function public.platform_signup_set(p_id bigint, p_status text, p_agency uuid default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'Невалиден статус.'; end if;
  update agency_signups set status = p_status, agency_id = coalesce(p_agency, agency_id), handled_at = now() where id = p_id;
end $$;

-- =====================================================================
-- БЕЗ ВХОД (страницата за вход): заявка за регистрация
-- =====================================================================
create or replace function public.signup_request(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare nm text := left(trim(coalesce(p->>'agency_name','')), 120); ph text := left(trim(coalesce(p->>'phone','')), 40);
begin
  if coalesce(p->>'website','') <> '' then return; end if;            -- капан за роботи (скрито поле)
  if length(nm) < 3 then raise exception 'Напишете името на агенцията.'; end if;
  if length(regexp_replace(ph, '\D', '', 'g')) < 6 then raise exception 'Напишете телефон за връзка.'; end if;
  if (select count(*) from agency_signups where created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Твърде много заявки в момента. Опитайте по-късно или се обадете на тел. %', (select support_phone from platform_settings where id = 1); end if;
  insert into agency_signups (agency_name, code_wanted, contact_person, phone, email, city, eik, note)
  values (nm, left(lower(trim(coalesce(p->>'code_wanted',''))), 30), left(trim(coalesce(p->>'contact_person','')), 120), ph,
          left(trim(coalesce(p->>'email','')), 120), left(trim(coalesce(p->>'city','')), 80), left(trim(coalesce(p->>'eik','')), 20), left(trim(coalesce(p->>'note','')), 1000));
end $$;

-- =====================================================================
-- АГЕНЦИЯ: публични линкове (оферта / отзив) и календар
-- =====================================================================
create or replace function public.create_public_link(p_kind text, p_ref text, p_data jsonb, p_days int default 14) returns text
language plpgsql security definer set search_path = public as $$
declare t text; ag uuid := public.my_agency(); who text;
begin
  if ag is null then raise exception 'Нямате достъп.'; end if;
  if p_kind not in ('offer','review') then raise exception 'Невалиден вид линк.'; end if;
  if not public.can_area('req','edit') then raise exception 'Нямате права да изпращате линкове на клиенти.'; end if;
  if not exists (select 1 from records where agency_id = ag and store = 'requests' and key = p_ref) then raise exception 'Няма такава заявка.'; end if;
  select coalesce((select name from profiles where id = auth.uid()), (select name from platform_admins where id = auth.uid()), '') into who;
  t := public._token();
  insert into public_links (token, agency_id, kind, ref_key, data, created_by, expires_at)
  values (t, ag, p_kind, p_ref, coalesce(p_data,'{}'::jsonb), who, now() + make_interval(days => least(greatest(coalesce(p_days,14),1),120)));
  return t;
end $$;

create or replace function public.my_public_links(p_ref text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ag uuid := public.my_agency();
begin
  if ag is null or not public.can_area('req','view') then raise exception 'Нямате достъп.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('token', token, 'kind', kind, 'ref', ref_key, 'created_by', created_by, 'created_at', created_at,
      'expires_at', expires_at, 'opened_at', opened_at, 'response', response, 'responded_at', responded_at,
      'title', data->>'title') order by created_at desc)
    from public_links where agency_id = ag and (p_ref is null or ref_key = p_ref)), '[]'::jsonb);
end $$;

create or replace function public.revoke_public_link(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_area('req','edit') then raise exception 'Нямате права.'; end if;
  update public_links set expires_at = now() where token = p_token and agency_id = public.my_agency();
end $$;

-- без вход: клиентът отваря линка
create or replace function public.public_link_get(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public_links; a agencies;
begin
  select * into l from public_links where token = p_token;
  if l.token is null then return jsonb_build_object('error','missing'); end if;
  if l.expires_at < now() and l.response is null then return jsonb_build_object('error','expired'); end if;
  select * into a from agencies where id = l.agency_id;
  if l.opened_at is null then update public_links set opened_at = now() where token = p_token; end if;
  return jsonb_build_object('kind', l.kind, 'data', l.data, 'agency', a.name, 'expires_at', l.expires_at,
    'response', l.response, 'responded_at', l.responded_at);
end $$;

create or replace function public.public_link_respond(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public_links; r jsonb; rt int;
begin
  select * into l from public_links where token = p_token for update;
  if l.token is null then raise exception 'Линкът не е намерен.'; end if;
  if l.response is not null then raise exception 'Вече сте отговорили. Благодарим!'; end if;
  if l.expires_at < now() then raise exception 'Линкът е изтекъл. Свържете се с агенцията.'; end if;
  if l.kind = 'offer' then
    if coalesce(p->>'answer','') not in ('accept','question') then raise exception 'Невалиден отговор.'; end if;
    r := jsonb_build_object('answer', p->>'answer', 'name', left(trim(coalesce(p->>'name','')),120), 'note', left(trim(coalesce(p->>'note','')),1000));
  else
    rt := nullif(p->>'rating','')::int;
    if rt is null or rt < 1 or rt > 5 then raise exception 'Изберете оценка от 1 до 5.'; end if;
    r := jsonb_build_object('rating', rt, 'note', left(trim(coalesce(p->>'note','')),2000), 'name', left(trim(coalesce(p->>'name','')),120));
  end if;
  update public_links set response = r, responded_at = now() where token = p_token;
  return r;
end $$;

-- календар: линкът на влезлия служител (създава, ако няма; p_new = нов линк, старият спира)
create or replace function public.my_calendar_token(p_new boolean default false, p_only_mine boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ag uuid := public.my_agency(); t calendar_tokens;
begin
  if ag is null or not public.can_area('req','view') then raise exception 'Нямате достъп до календара.'; end if;
  if p_new then delete from calendar_tokens where user_id = auth.uid(); end if;
  select * into t from calendar_tokens where user_id = auth.uid();
  if t.token is null or t.agency_id <> ag then
    delete from calendar_tokens where user_id = auth.uid();
    insert into calendar_tokens (token, agency_id, user_id, only_mine) values (public._token(), ag, auth.uid(), coalesce(p_only_mine,false)) returning * into t;
  elsif p_only_mine is not null then
    update calendar_tokens set only_mine = p_only_mine where user_id = auth.uid() returning * into t;
  end if;
  return jsonb_build_object('token', t.token, 'only_mine', t.only_mine);
end $$;

-- без вход (извиква се от функцията „ical“): ритуали и събития за +-60/180 дни
create or replace function public.calendar_feed(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t calendar_tokens; a agencies; uid text;
begin
  select * into t from calendar_tokens where token = p_token;
  if t.token is null then return null; end if;
  select * into a from agencies where id = t.agency_id;
  if not a.active or (a.access_until is not null and a.access_until <= now()) then return null; end if;
  if not exists (select 1 from profiles where id = t.user_id and active and agency_id = t.agency_id)
     and not exists (select 1 from platform_admins where id = t.user_id) then return null; end if;
  uid := t.user_id::text;
  return jsonb_build_object('agency', a.name, 'items', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('id', 'r-' || key, 'kind', 'ritual', 'date', value->>'ritDate', 'time', value->>'ritTime',
        'title', coalesce(nullif(value->>'kind',''), 'ритуал') || ' — ' || coalesce(nullif(value->>'decName',''), '№ ' || (value->>'number')),
        'place', concat_ws(', ', nullif(value->>'cemetery',''), nullif(value->>'ritualPlace','')), 'owner', value->>'ownerName',
        'note', 'Заявка № ' || coalesce(value->>'number','')) x
      from records where agency_id = t.agency_id and store = 'requests' and coalesce(value->>'sample','false') <> 'true'
        and coalesce(value->>'ritDate','') between to_char(now() - interval '60 days','YYYY-MM-DD') and to_char(now() + interval '180 days','YYYY-MM-DD')
        and (not t.only_mine or value->>'owner' = uid)
      union all
      select jsonb_build_object('id', 'e-' || key, 'kind', coalesce(value->>'type','other'), 'date', value->>'date', 'time', value->>'time',
        'title', value->>'title', 'place', value->>'place', 'owner', value->>'ownerName', 'note', value->>'note')
      from records where agency_id = t.agency_id and store = 'events'
        and coalesce(value->>'date','') between to_char(now() - interval '60 days','YYYY-MM-DD') and to_char(now() + interval '180 days','YYYY-MM-DD')
        and (not t.only_mine or value->>'owner' = uid)) s), '[]'::jsonb));
end $$;

-- ---------- поправка: „+ Нова агенция“ от панела на собственика ----------
-- От миграция 3 тригерът отказваше първоначалните настройки на новата агенция (собственикът не е администратор на агенция).
create or replace function public.records_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  st text := coalesce(new.store, old.store);
  k  text := coalesce(new.key, old.key);
  nv jsonb; ov jsonb;
  skip constant text[] := array['ws','inv','updated','updatedBy'];
begin
  if tg_op <> 'DELETE' then nv := new.value; end if;
  if tg_op <> 'INSERT' then ov := old.value; end if;

  -- SQL Editor / service role (миграции, поддръжка) — без проверка на права, но с версия
  if auth.uid() is null then
    if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
    return coalesce(new, old);
  end if;

  -- история: само добавяне; сървърът записва кой и кога (клиентските полета остават)
  if st = 'audit' then
    if tg_op <> 'INSERT' then raise exception 'Историята не може да се променя или изтрива.'; end if;
    new.value := new.value || jsonb_build_object('serverTs', now(), 'serverUid', auth.uid());
    return new;
  end if;

  -- собственикът на платформата: пише в записите само през своите функции (нова агенция и др.) — без проверка на права
  if public.is_platform() then
    if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
    return coalesce(new, old);
  end if;

  -- upsert (INSERT … ON CONFLICT DO UPDATE) върху съществуващ ред: Postgres пуска първо INSERT-фазата.
  -- Тогава пропускаме — същият тригер проверява реда изцяло в UPDATE-фазата, която следва.
  -- (Обикновен INSERT върху съществуващ ред така или иначе пада на уникалния ключ.)
  if tg_op = 'INSERT' and exists (select 1 from public.records r
      where r.agency_id = new.agency_id and r.store = st and r.key = k) then
    return new;
  end if;

  if tg_op = 'DELETE' then
    if st = 'requests' and not public.my_flag('reqdel') then raise exception 'Нямате права да изтривате заявки.'; end if;
    if st = 'docs' and not public.can_area('files','edit') then raise exception 'Нямате права да изтривате документи.'; end if;
    if st = 'events' and not public.can_area('req','edit') then raise exception 'Нямате права да изтривате събития от календара.'; end if;
    if st not in ('requests','docs','events') and not public.is_admin() then raise exception 'Само администратор може да изтрива.'; end if;
    return old;
  end if;

  if st = 'requests' then
    if tg_op = 'INSERT' then
      if not public.can_area('req','edit') then raise exception 'Нямате права да създавате заявки.'; end if;
    else
      if (nv - skip) is distinct from (ov - skip) and not public.can_area('req','edit') then
        raise exception 'Нямате права да променяте заявки.'; end if;
      if (nv->'ws') is distinct from (ov->'ws') and not public.can_area('ws','edit') then
        raise exception 'Нямате права да променяте работни листове.'; end if;
      if (nv->'inv') is distinct from (ov->'inv') and not public.can_area('docs','edit') then
        raise exception 'Нямате права да променяте фактури и оферти.'; end if;
    end if;

  elsif st = 'meta' then
    if k = 'settings' then
      if not public.is_admin() then
        if tg_op = 'INSERT' then raise exception 'Само администратор може да променя настройките.'; end if;
        -- служителите увеличават само поредните номера (заявки / фактури)
        if ((nv->'value') - array['nextNo','invNext']) is distinct from ((ov->'value') - array['nextNo','invNext']) then
          raise exception 'Само администратор може да променя настройките.'; end if;
        if (nv->'value'->'nextNo') is distinct from (ov->'value'->'nextNo') and not public.can_area('req','edit') then
          raise exception 'Нямате права да променяте номерацията на заявките.'; end if;
        if (nv->'value'->'invNext') is distinct from (ov->'value'->'invNext') and not public.can_area('docs','edit') then
          raise exception 'Нямате права да променяте номерацията на фактурите.'; end if;
      end if;
    elsif k = 'catalog' then
      if not public.can_area('catalog','edit') then
        -- некролозите пазят цените си в каталога: позволено само това, и само с право „Некролози: редактира“
        if tg_op = 'INSERT'
           or ((nv->'value') - array['necro','lamPrice']) is distinct from ((ov->'value') - array['necro','lamPrice'])
           or not public.can_area('necro','edit') then
          raise exception 'Нямате права да променяте услугите и цените.'; end if;
      end if;
    elsif k = 'necro' then
      if not public.can_area('necro','edit') then raise exception 'Нямате права да променяте некролозите.'; end if;
    elsif k = 'inventory' then
      -- изписване от склада става и от заявката, затова и „Заявки: редактира“ (виж ограниченията)
      if not (public.can_area('stock','edit') or public.my_flag('stockadj') or public.can_area('req','edit')) then
        raise exception 'Нямате права да променяте склада.'; end if;
    elsif k = 'initialized' then
      if tg_op <> 'INSERT' and not public.is_admin() then raise exception 'Само администратор.'; end if;
    elsif not public.is_admin() then
      raise exception 'Само администратор може да променя тези настройки.';
    end if;

  elsif st = 'docs' then
    if not public.can_area('files','edit') then raise exception 'Нямате права да променяте документи.'; end if;

  elsif st = 'events' then
    if not public.can_area('req','edit') then raise exception 'Нямате права да променяте събития от календара.'; end if;

  elsif st = 'clients' then
    if not public.can_area('clients','edit') then raise exception 'Нямате права да променяте клиентски профили.'; end if;

  elsif not public.is_admin() then
    raise exception 'Само администратор.';
  end if;

  if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
  return new;
end $$;

-- ---------- кой може да вика функциите ----------
revoke execute on function public._token() from public, anon, authenticated;
revoke execute on function public.platform_seller_set(jsonb), public.platform_issue_invoice(uuid, bigint, numeric, text, date),
  public.platform_invoices_list(uuid), public.platform_cancel_invoice(bigint), public.platform_dashboard(), public.platform_signups(),
  public.platform_signup_set(bigint, text, uuid), public.create_public_link(text, text, jsonb, int), public.my_public_links(text),
  public.revoke_public_link(text), public.my_calendar_token(boolean, boolean)
  from public, anon;
grant execute on function public.platform_seller_set(jsonb), public.platform_issue_invoice(uuid, bigint, numeric, text, date),
  public.platform_invoices_list(uuid), public.platform_cancel_invoice(bigint), public.platform_dashboard(), public.platform_signups(),
  public.platform_signup_set(bigint, text, uuid), public.create_public_link(text, text, jsonb, int), public.my_public_links(text),
  public.revoke_public_link(text), public.my_calendar_token(boolean, boolean)
  to authenticated;
-- без вход
grant execute on function public.signup_request(jsonb), public.public_link_get(text), public.public_link_respond(text, jsonb),
  public.calendar_feed(text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- ---------- ВРЪЩАНЕ ----------
-- begin;
-- drop function if exists public.calendar_feed(text), public.my_calendar_token(boolean, boolean), public.public_link_respond(text, jsonb),
--   public.public_link_get(text), public.revoke_public_link(text), public.my_public_links(text), public.create_public_link(text, text, jsonb, int),
--   public.signup_request(jsonb), public.platform_signup_set(bigint, text, uuid), public.platform_signups(), public.platform_dashboard(),
--   public.platform_cancel_invoice(bigint), public.platform_invoices_list(uuid), public.platform_issue_invoice(uuid, bigint, numeric, text, date),
--   public.platform_seller_set(jsonb), public._token();
-- drop table if exists public.calendar_tokens, public.public_links, public.agency_signups;   -- ВНИМАНИЕ: губят се линковете и заявките за регистрация
-- drop table if exists public.platform_invoices;   -- ВНИМАНИЕ: издадените фактури се пазят 10 години — не трийте без копие
-- alter table public.platform_settings drop column if exists seller_name, drop column if exists seller_eik, drop column if exists seller_vat,
--   drop column if exists seller_address, drop column if exists seller_mol, drop column if exists seller_iban, drop column if exists seller_bank,
--   drop column if exists invoice_next;
-- notify pgrst, 'reload schema';
-- commit;
