-- =====================================================================
-- Панел на собственика, част 2: срок на достъп, история, входове, плащания,
-- данни за контакт, съобщения, отваряне на агенция от собственика.
-- Пуска се след setup.sql / migrate-to-agencies.sql. Само добавя — не трие данни.
-- =====================================================================

-- ---------- нови колони и таблици ----------
alter table public.agencies
  add column if not exists access_until   timestamptz,          -- null = без срок
  add column if not exists contact_person text not null default '',
  add column if not exists contact_phone  text not null default '',
  add column if not exists contact_email  text not null default '',
  add column if not exists eik            text not null default '',
  add column if not exists address        text not null default '',
  add column if not exists notes          text not null default '',
  add column if not exists monthly_fee    numeric(10,2);

alter table public.platform_admins
  add column if not exists acting_agency uuid references public.agencies(id) on delete set null; -- собственикът е „влязъл“ в агенция

create table if not exists public.platform_settings (
  id            int primary key default 1 check (id = 1),
  support_phone text not null default '+359 893 008 182',
  trial_days    int  not null default 14,
  warn_days     int  not null default 5
);
insert into public.platform_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.access_log (        -- кога на коя агенция какъв достъп е даден
  id        bigserial primary key,
  agency_id uuid references public.agencies(id) on delete cascade,
  at        timestamptz not null default now(),
  action    text not null,
  until_at  timestamptz,
  by_user   uuid default auth.uid(),
  note      text not null default ''
);
create index if not exists access_log_agency on public.access_log (agency_id, at desc);

create table if not exists public.login_log (         -- входове на служителите
  id        bigserial primary key,
  agency_id uuid references public.agencies(id) on delete cascade,
  user_id   uuid,
  username  text not null default '',
  name      text not null default '',
  at        timestamptz not null default now()
);
create index if not exists login_log_agency on public.login_log (agency_id, at desc);

create table if not exists public.payments (
  id         bigserial primary key,
  agency_id  uuid not null references public.agencies(id) on delete cascade,
  paid_on    date not null default current_date,
  amount     numeric(10,2) not null,
  note       text not null default '',
  created_at timestamptz not null default now(),
  by_user    uuid default auth.uid()
);
create index if not exists payments_agency on public.payments (agency_id, paid_on desc);

create table if not exists public.announcements (
  id         bigserial primary key,
  agency_id  uuid references public.agencies(id) on delete cascade, -- null = за всички агенции
  text       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.platform_settings enable row level security;
alter table public.access_log        enable row level security;
alter table public.login_log         enable row level security;
alter table public.payments          enable row level security;
alter table public.announcements     enable row level security;
revoke all on public.platform_settings, public.access_log, public.login_log, public.payments, public.announcements from anon, authenticated;

-- ---------- кой е влязъл: срокът се спазва; собственикът, „влязъл“ в агенция, я вижда като администратор ----------
create or replace function public.my_agency() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.agency_id from profiles p join agencies a on a.id = p.agency_id
      where p.id = auth.uid() and p.active and a.active and (a.access_until is null or a.access_until > now())),
    (select acting_agency from platform_admins where id = auth.uid()))
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p join agencies a on a.id = p.agency_id
                 where p.id = auth.uid() and p.active and a.active and p.role = 'admin'
                   and (a.access_until is null or a.access_until > now()))
      or exists (select 1 from platform_admins where id = auth.uid() and acting_agency is not null)
$$;

create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('kind','platform','name',pa.name,'username',pa.username,
              'acting', case when a.id is null then null else jsonb_build_object('agency_id',a.id,'code',a.code,'agency_name',a.name) end)
       from platform_admins pa left join agencies a on a.id = pa.acting_agency where pa.id = auth.uid()),
    (select jsonb_build_object('kind','agency','agency_id',a.id,'code',a.code,'agency_name',a.name,
                               'agency_active',a.active,'active',p.active,'access_until',a.access_until,
                               'expired', a.access_until is not null and a.access_until <= now(),
                               'support_phone',s.support_phone,'warn_days',s.warn_days)
       from profiles p join agencies a on a.id = p.agency_id cross join platform_settings s where p.id = auth.uid()))
$$;

create or replace function public.touch_login() returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid;
begin
  update profiles set last_login = now() where id = auth.uid() and active returning agency_id into ag;
  if ag is not null then
    insert into login_log (agency_id, user_id, username, name)
      select agency_id, id, username, name from profiles where id = auth.uid();
  end if;
  update platform_admins set last_login = now() where id = auth.uid();
end $$;

-- съобщения за агенцията на влезлия (лентата горе)
create or replace function public.my_announcements() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'text',text,'at',created_at) order by created_at desc), '[]'::jsonb)
  from announcements where active and (agency_id is null or agency_id = public.my_agency()) and public.my_agency() is not null
$$;

-- ---------- собственик ----------
create or replace function public._plog(p_agency uuid, p_action text, p_until timestamptz, p_note text default '') returns void
language sql security definer set search_path = public as $$
  insert into access_log (agency_id, action, until_at, note) values (p_agency, p_action, p_until, coalesce(p_note,''))
$$;

create or replace function public.platform_agencies() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at') from (
    select jsonb_build_object(
      'id', a.id, 'code', a.code, 'name', a.name, 'active', a.active, 'created_at', a.created_at,
      'access_until', a.access_until, 'expired', a.access_until is not null and a.access_until <= now(),
      'contact_person', a.contact_person, 'contact_phone', a.contact_phone, 'contact_email', a.contact_email,
      'eik', a.eik, 'address', a.address, 'notes', a.notes, 'monthly_fee', a.monthly_fee,
      'paid_total', (select coalesce(sum(amount),0) from payments pm where pm.agency_id = a.id),
      'last_payment', (select max(paid_on) from payments pm where pm.agency_id = a.id),
      'users', (select count(*) from profiles p where p.agency_id = a.id and p.active),
      'admins', (select coalesce(jsonb_agg(p.username order by p.username), '[]'::jsonb) from profiles p where p.agency_id = a.id and p.role = 'admin' and p.active),
      'last_login', (select max(p.last_login) from profiles p where p.agency_id = a.id),
      'requests', (select count(*) from records r where r.agency_id = a.id and r.store = 'requests')) as x
    from agencies a) t), '[]'::jsonb);
end $$;

create or replace function public.platform_settings_get() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return (select to_jsonb(s) - 'id' from platform_settings s where id = 1);
end $$;

create or replace function public.platform_settings_set(p_phone text, p_trial_days int, p_warn_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if coalesce(trim(p_phone),'') = '' then raise exception 'Попълнете телефон за връзка.'; end if;
  update platform_settings set support_phone = trim(p_phone), trial_days = greatest(coalesce(p_trial_days,0),0),
         warn_days = greatest(coalesce(p_warn_days,0),0) where id = 1;
end $$;

-- срок: p_until = null → без срок
create or replace function public.platform_set_access(p_agency uuid, p_until timestamptz, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update agencies set access_until = p_until where id = p_agency;
  if not found then raise exception 'Няма такава агенция.'; end if;
  perform _plog(p_agency, case when p_until is null then 'Достъп без срок' else 'Срок на достъпа' end, p_until, p_note);
end $$;

-- удължава от днес или от сегашния край (което е по-късно)
create or replace function public.platform_extend(p_agency uuid, p_months int, p_days int, p_note text default '') returns timestamptz
language plpgsql security definer set search_path = public as $$
declare u timestamptz;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update agencies set access_until = greatest(coalesce(access_until, now()), now())
                                     + make_interval(months => coalesce(p_months,0), days => coalesce(p_days,0))
    where id = p_agency returning access_until into u;
  if u is null then raise exception 'Няма такава агенция.'; end if;
  perform _plog(p_agency, 'Удължен достъп'
    || case when coalesce(p_months,0) > 0 then ' +' || p_months || ' мес.' else '' end
    || case when coalesce(p_days,0)   > 0 then ' +' || p_days   || ' дни'  else '' end, u, p_note);
  return u;
end $$;

create or replace function public.platform_update_agency(p_agency uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'Попълнете името на агенцията.'; end if;
  update agencies set name = trim(p->>'name'),
    contact_person = coalesce(p->>'contact_person',''), contact_phone = coalesce(p->>'contact_phone',''),
    contact_email = coalesce(p->>'contact_email',''), eik = coalesce(p->>'eik',''), address = coalesce(p->>'address',''),
    notes = coalesce(p->>'notes',''), monthly_fee = nullif(p->>'monthly_fee','')::numeric
  where id = p_agency;
  if not found then raise exception 'Няма такава агенция.'; end if;
end $$;

create or replace function public.platform_set_agency_active(p_agency uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update agencies set active = p_active where id = p_agency;
  if not found then raise exception 'Няма такава агенция.'; end if;
  perform _plog(p_agency, case when p_active then 'Агенцията е пусната' else 'Агенцията е спряна' end, null);
end $$;

create or replace function public.platform_add_payment(p_agency uuid, p_paid_on date, p_amount numeric, p_note text, p_extend_months int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Сумата трябва да е по-голяма от 0.'; end if;
  insert into payments (agency_id, paid_on, amount, note) values (p_agency, coalesce(p_paid_on, current_date), p_amount, coalesce(p_note,''));
  perform _plog(p_agency, 'Плащане ' || to_char(p_amount, 'FM999999990.00') || ' €', null, p_note);
  if coalesce(p_extend_months,0) > 0 then perform platform_extend(p_agency, p_extend_months, 0, 'след плащане'); end if;
end $$;

create or replace function public.platform_delete_payment(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid; amt numeric;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  delete from payments where id = p_id returning agency_id, amount into ag, amt;
  if ag is not null then perform _plog(ag, 'Изтрито плащане ' || to_char(amt, 'FM999999990.00') || ' €', null); end if;
end $$;

create or replace function public.platform_agency_detail(p_agency uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return jsonb_build_object(
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'paid_on',paid_on,'amount',amount,'note',note) order by paid_on desc, id desc), '[]'::jsonb)
                   from payments where agency_id = p_agency),
    'access', (select coalesce(jsonb_agg(x order by (x->>'at') desc), '[]'::jsonb) from (
                 select jsonb_build_object('at',at,'action',action,'until',until_at,'note',note) x
                 from access_log where agency_id = p_agency order by at desc limit 100) t),
    'logins', (select coalesce(jsonb_agg(x order by (x->>'at') desc), '[]'::jsonb) from (
                 select jsonb_build_object('at',at,'username',username,'name',name) x
                 from login_log where agency_id = p_agency order by at desc limit 100) t),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('username',username,'name',name,'role',role,'active',active,'last_login',last_login) order by username), '[]'::jsonb)
                from profiles where agency_id = p_agency));
end $$;

create or replace function public.platform_access_log(p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'at') desc), '[]'::jsonb) from (
    select jsonb_build_object('at',l.at,'agency',coalesce(a.name,'—'),'code',coalesce(a.code,''),'action',l.action,'until',l.until_at,'note',l.note) x
    from access_log l left join agencies a on a.id = l.agency_id order by l.at desc limit greatest(coalesce(p_limit,200),1)) t);
end $$;

create or replace function public.platform_login_log(p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'at') desc), '[]'::jsonb) from (
    select jsonb_build_object('at',l.at,'agency',coalesce(a.name,'—'),'code',coalesce(a.code,''),'username',l.username,'name',l.name) x
    from login_log l left join agencies a on a.id = l.agency_id order by l.at desc limit greatest(coalesce(p_limit,200),1)) t);
end $$;

-- собственикът „влиза“ в агенция (вижда и променя всичко като администратор) и излиза
create or replace function public.platform_enter_agency(p_agency uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if not exists (select 1 from agencies where id = p_agency) then raise exception 'Няма такава агенция.'; end if;
  update platform_admins set acting_agency = p_agency where id = auth.uid();
  perform _plog(p_agency, 'Собственикът отвори агенцията', null);
end $$;

create or replace function public.platform_leave_agency() returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  select acting_agency into ag from platform_admins where id = auth.uid();
  update platform_admins set acting_agency = null where id = auth.uid();
  if ag is not null then perform _plog(ag, 'Собственикът излезе от агенцията', null); end if;
end $$;

create or replace function public.platform_announcements() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'text',n.text,'active',n.active,'at',n.created_at,
            'agency', coalesce(a.name,'Всички агенции')) order by n.created_at desc), '[]'::jsonb)
          from announcements n left join agencies a on a.id = n.agency_id);
end $$;

create or replace function public.platform_add_announcement(p_agency uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if coalesce(trim(p_text),'') = '' then raise exception 'Напишете текста на съобщението.'; end if;
  insert into announcements (agency_id, text) values (p_agency, trim(p_text));
end $$;

create or replace function public.platform_set_announcement(p_id bigint, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update announcements set active = p_active where id = p_id;
end $$;

-- нова агенция: пробен период от настройките + запис в историята
create or replace function public.platform_create_agency(p_code text, p_name text, p_admin_username text, p_admin_name text, p_admin_password text, p_recovery text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare ag uuid; cd text := lower(trim(p_code)); nm text := trim(p_name); td int; u timestamptz;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if cd !~ '^[a-z0-9][a-z0-9-]{1,29}$' then raise exception 'Кодът е 2–30 знака: малки латински букви, цифри и тире (напр. tangra).'; end if;
  if nm = '' then raise exception 'Попълнете името на агенцията.'; end if;
  if exists (select 1 from agencies where code = cd) then raise exception 'Вече има агенция с този код.'; end if;
  select trial_days into td from platform_settings where id = 1;
  u := case when coalesce(td,0) > 0 then now() + make_interval(days => td) else null end;
  insert into agencies (code, name, access_until) values (cd, nm, u) returning id into ag;
  perform _create_user(ag, p_admin_username, p_admin_name, p_admin_password, 'admin', '{}'::jsonb);
  if length(coalesce(p_recovery,'')) >= 8 then
    insert into agency_secrets(agency_id, name, hash) values (ag, 'recovery', crypt(p_recovery, gen_salt('bf')));
  end if;
  insert into records (agency_id, store, key, value) values
    (ag, 'meta', 'settings', jsonb_build_object('key','settings','value', jsonb_build_object(
       'agency', upper(nm), 'short', nm, 'addr', '', 'gsm', '', 'city', '', 'logo', '', 'logoMode', 'none'))),
    (ag, 'meta', 'initialized', jsonb_build_object('key','initialized','value', true));
  perform _plog(ag, case when u is null then 'Създадена (без срок)' else 'Създадена — пробен период ' || td || ' дни' end, u);
  return ag;
end $$;

-- ---------- кой може да вика функциите ----------
revoke execute on function public._plog(uuid, text, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.my_announcements(), public.platform_settings_get(), public.platform_settings_set(text, int, int),
  public.platform_set_access(uuid, timestamptz, text), public.platform_extend(uuid, int, int, text), public.platform_update_agency(uuid, jsonb),
  public.platform_add_payment(uuid, date, numeric, text, int), public.platform_delete_payment(bigint), public.platform_agency_detail(uuid),
  public.platform_access_log(int), public.platform_login_log(int), public.platform_enter_agency(uuid), public.platform_leave_agency(),
  public.platform_announcements(), public.platform_add_announcement(uuid, text), public.platform_set_announcement(bigint, boolean)
  from public, anon;

notify pgrst, 'reload schema';
