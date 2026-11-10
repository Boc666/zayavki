-- =====================================================================
-- Заявки — база за МНОГО агенции (Supabase)
-- Пуска се ВЕДНЪЖ в ПРАЗЕН проект: Supabase → SQL Editor → постави всичко → Run.
-- (Съществуващата база на Тангра се прехвърля с отделен файл — migrate-to-agencies.sql.)
--
-- Как е устроено:
--   agencies         — агенциите (код за вход, име, активна/спряна)
--   platform_admins  — собственикът(ците) на платформата (супер-админ); НЕ виждат данните на агенциите
--   profiles         — служителите; всеки е в точно една агенция
--   records          — всички данни (заявки, настройки, каталог, история…), всеки ред с agency_id
--   storage „docs“   — Word файловете, в папка <agency_id>/
-- Защитата е в базата (Row Level Security): потребител вижда само редовете на своята агенция.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- таблици ----------
create table public.agencies (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[a-z0-9][a-z0-9-]{1,29}$'),
  name       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.platform_admins (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  name       text not null,
  created_at timestamptz not null default now(),
  last_login timestamptz
);

create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  agency_id  uuid not null references public.agencies(id) on delete cascade,
  username   text not null,
  name       text not null,
  role       text not null default 'user' check (role in ('admin','user')),
  perms      jsonb not null default '{}'::jsonb,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_login timestamptz,
  unique (agency_id, username)
);

create table public.agency_secrets (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name      text not null,
  hash      text not null,
  primary key (agency_id, name)
);

create table public.platform_secrets (
  name text primary key,
  hash text not null
);

-- ---------- кой е влязъл ----------
create or replace function public.my_agency() returns uuid
language sql stable security definer set search_path = public as $$
  select p.agency_id from profiles p join agencies a on a.id = p.agency_id
  where p.id = auth.uid() and p.active and a.active
$$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_agency() is not null
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p join agencies a on a.id = p.agency_id
                 where p.id = auth.uid() and p.active and a.active and p.role = 'admin')
$$;

create or replace function public.is_platform() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where id = auth.uid())
$$;

-- agency_id се попълва сам от входа — приложението не го изпраща
create table public.records (
  agency_id  uuid not null default public.my_agency() references public.agencies(id) on delete cascade,
  store      text not null,
  key        text not null,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (agency_id, store, key)
);

-- ---------- правила за достъп ----------
alter table public.agencies         enable row level security;
alter table public.platform_admins  enable row level security;
alter table public.profiles         enable row level security;
alter table public.agency_secrets   enable row level security;
alter table public.platform_secrets enable row level security;
alter table public.records          enable row level security;

create policy "agency read own"  on public.agencies for select to authenticated using (id = public.my_agency());
create policy "profiles read"    on public.profiles for select to authenticated using (agency_id = public.my_agency());
create policy "records read"     on public.records  for select to authenticated using (agency_id = public.my_agency());
create policy "records insert"   on public.records  for insert to authenticated with check (agency_id = public.my_agency());
create policy "records update"   on public.records  for update to authenticated
  using (agency_id = public.my_agency() and store <> 'audit') with check (agency_id = public.my_agency() and store <> 'audit');
create policy "records delete"   on public.records  for delete to authenticated
  using (agency_id = public.my_agency() and store in ('requests','docs'));
-- platform_admins, agency_secrets, platform_secrets: без правила = никой не ги чете отвън (само през функциите)
revoke all on public.platform_admins, public.agency_secrets, public.platform_secrets from anon, authenticated;
revoke insert, update, delete on public.agencies, public.profiles from anon, authenticated;

-- ---------- потребителско име → вътрешен „имейл“ (имейли не се пращат) ----------
-- служител: u + hex("код/потребител"); собственик: p + hex("потребител"). Същото е в index.html.
create or replace function public.username_email(p_code text, p_user text) returns text
language sql immutable as $$
  select 'u' || encode(convert_to(lower(trim(p_code)) || '/' || lower(trim(p_user)), 'UTF8'), 'hex') || '@zayavki.local'
$$;
create or replace function public.platform_email(p_user text) returns text
language sql immutable as $$
  select 'p' || encode(convert_to(lower(trim(p_user)), 'UTF8'), 'hex') || '@zayavki.local'
$$;

create or replace function public._make_auth_user(p_email text, p_password text) returns uuid
language plpgsql security definer set search_path = public, auth, extensions as $$
declare uid uuid := gen_random_uuid();
begin
  if length(coalesce(p_password,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email,
          crypt(p_password, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true),
          'email', now(), now(), now());
  return uid;
end $$;

create or replace function public._create_user(p_agency uuid, p_username text, p_name text, p_password text, p_role text, p_perms jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid; un text := lower(trim(p_username)); cd text;
begin
  select code into cd from agencies where id = p_agency;
  if cd is null then raise exception 'Няма такава агенция.'; end if;
  if un = '' or coalesce(trim(p_name),'') = '' then raise exception 'Попълнете име и потребителско име.'; end if;
  if p_role not in ('admin','user') then raise exception 'Невалидна роля.'; end if;
  if exists (select 1 from profiles where agency_id = p_agency and username = un) then raise exception 'Това потребителско име вече съществува.'; end if;
  uid := _make_auth_user(username_email(cd, un), p_password);
  insert into profiles (id, agency_id, username, name, role, perms) values (uid, p_agency, un, trim(p_name), p_role, coalesce(p_perms,'{}'::jsonb));
  return uid;
end $$;

-- ---------- след вход: кой съм (собственик или служител на коя агенция) ----------
create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('kind','platform','name',name,'username',username) from platform_admins where id = auth.uid()),
    (select jsonb_build_object('kind','agency','agency_id',a.id,'code',a.code,'agency_name',a.name,
                               'agency_active',a.active,'active',p.active)
       from profiles p join agencies a on a.id = p.agency_id where p.id = auth.uid()))
$$;

create or replace function public.touch_login() returns void
language sql security definer set search_path = public as $$
  update profiles set last_login = now() where id = auth.uid() and active;
  update platform_admins set last_login = now() where id = auth.uid();
$$;

create or replace function public.change_my_password(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare h text;
begin
  select encrypted_password into h from auth.users where id = auth.uid();
  if h is null or crypt(coalesce(p_old,''), h) <> h then raise exception 'Сегашната парола е грешна.'; end if;
  if length(coalesce(p_new,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_new, gen_salt('bf')), updated_at = now() where id = auth.uid();
end $$;

-- ---------- данни ----------
create or replace function public.put_atomic(ops jsonb) returns void
language plpgsql set search_path = public as $$
declare o jsonb; ag uuid := my_agency();
begin
  if ag is null then raise exception 'not allowed'; end if;
  for o in select * from jsonb_array_elements(ops) loop
    if o->>'store' = 'audit' then   -- историята не се презаписва
      insert into records(agency_id, store, key, value) values (ag, 'audit', o->>'key', o->'value')
      on conflict (agency_id, store, key) do nothing;
    else
      insert into records(agency_id, store, key, value, updated_at, updated_by)
      values (ag, o->>'store', o->>'key', o->'value', now(), auth.uid())
      on conflict (agency_id, store, key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
    end if;
  end loop;
end $$;

-- ---------- администратор на агенция: служители ----------
create or replace function public.admin_create_user(p_username text, p_name text, p_password text, p_role text, p_perms jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Само администратор.'; end if;
  return _create_user(my_agency(), p_username, p_name, p_password, p_role, p_perms);
end $$;

create or replace function public.admin_update_user(p_user uuid, p_username text, p_name text, p_role text, p_active boolean, p_perms jsonb, p_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare un text := lower(trim(p_username)); ag uuid := my_agency(); cd text; em text; cur profiles;
begin
  if not is_admin() then raise exception 'Само администратор.'; end if;
  select * into cur from profiles where id = p_user and agency_id = ag;
  if cur.id is null then raise exception 'Няма такъв потребител.'; end if;
  if p_role not in ('admin','user') then raise exception 'Невалидна роля.'; end if;
  if exists (select 1 from profiles where agency_id = ag and username = un and id <> p_user) then raise exception 'Това потребителско име вече съществува.'; end if;
  if cur.role = 'admin' and cur.active and (p_role <> 'admin' or not p_active)
     and not exists (select 1 from profiles where agency_id = ag and role = 'admin' and active and id <> p_user) then
    raise exception 'Трябва да остане поне един активен администратор.';
  end if;
  select code into cd from agencies where id = ag;
  em := username_email(cd, un);
  update profiles set username = un, name = p_name, role = p_role, active = p_active, perms = coalesce(p_perms,'{}'::jsonb) where id = p_user;
  update auth.users set email = em, updated_at = now() where id = p_user;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', em) where user_id = p_user and provider = 'email';
  if coalesce(p_password,'') <> '' then
    if length(p_password) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
    update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')) where id = p_user;
  end if;
end $$;

create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not is_admin() then raise exception 'Само администратор.'; end if;
  if not exists (select 1 from profiles where id = p_user and agency_id = my_agency()) then raise exception 'Няма такъв потребител.'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
end $$;

-- ---------- код за възстановяване ----------
create or replace function public.set_recovery(p_password text, p_code text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare h text;
begin
  select encrypted_password into h from auth.users where id = auth.uid();
  if h is null or crypt(coalesce(p_password,''), h) <> h then raise exception 'Грешна парола.'; end if;
  if length(coalesce(p_code,'')) < 8 then raise exception 'Кодът трябва да е поне 8 знака.'; end if;
  if is_admin() then
    insert into agency_secrets(agency_id, name, hash) values (my_agency(), 'recovery', crypt(p_code, gen_salt('bf')))
      on conflict (agency_id, name) do update set hash = excluded.hash;
  elsif is_platform() then
    insert into platform_secrets(name, hash) values ('recovery', crypt(p_code, gen_salt('bf')))
      on conflict (name) do update set hash = excluded.hash;
  else raise exception 'Само администратор.'; end if;
end $$;

-- p_agency празно = собственик на платформата
create or replace function public.recover_admin(p_agency text, p_username text, p_code text, p_password text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare s text; uid uuid; un text := lower(trim(p_username)); ag uuid;
begin
  perform pg_sleep(1);  -- забавя налучкването
  if coalesce(trim(p_agency),'') = '' then
    select hash into s from platform_secrets where name = 'recovery';
    select id into uid from platform_admins where username = un;
  else
    select id into ag from agencies where code = lower(trim(p_agency));
    select hash into s from agency_secrets where agency_id = ag and name = 'recovery';
    select id into uid from profiles where agency_id = ag and username = un and role = 'admin';
  end if;
  if s is null or uid is null or crypt(coalesce(p_code,''), s) <> s then raise exception 'Грешни данни или код.'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
  update profiles set active = true where id = uid;
end $$;

-- ---------- първо пускане: създава СОБСТВЕНИКА на платформата (само докато няма такъв) ----------
create or replace function public.needs_setup() returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from platform_admins)
$$;

create or replace function public.setup_first_admin(p_username text, p_name text, p_password text, p_recovery text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid; un text := lower(trim(p_username));
begin
  perform pg_advisory_xact_lock(7311);
  if exists (select 1 from platform_admins) then raise exception 'Програмата вече е настроена.'; end if;
  if un = '' or coalesce(trim(p_name),'') = '' then raise exception 'Попълнете име и потребителско име.'; end if;
  if length(coalesce(p_recovery,'')) < 8 then raise exception 'Кодът за възстановяване трябва да е поне 8 знака.'; end if;
  uid := _make_auth_user(platform_email(un), p_password);
  insert into platform_admins (id, username, name) values (uid, un, trim(p_name));
  insert into platform_secrets(name, hash) values ('recovery', crypt(p_recovery, gen_salt('bf')))
    on conflict (name) do update set hash = excluded.hash;
  return uid;
end $$;

-- ---------- собственик на платформата: управление на агенциите (без достъп до данните им) ----------
create or replace function public.platform_agencies() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'created_at') from (
    select jsonb_build_object(
      'id', a.id, 'code', a.code, 'name', a.name, 'active', a.active, 'created_at', a.created_at,
      'users', (select count(*) from profiles p where p.agency_id = a.id and p.active),
      'admins', (select coalesce(jsonb_agg(p.username order by p.username), '[]'::jsonb) from profiles p where p.agency_id = a.id and p.role = 'admin' and p.active),
      'last_login', (select max(p.last_login) from profiles p where p.agency_id = a.id),
      'requests', (select count(*) from records r where r.agency_id = a.id and r.store = 'requests')) as x
    from agencies a) t), '[]'::jsonb);
end $$;

create or replace function public.platform_create_agency(p_code text, p_name text, p_admin_username text, p_admin_name text, p_admin_password text, p_recovery text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare ag uuid; cd text := lower(trim(p_code)); nm text := trim(p_name);
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  if cd !~ '^[a-z0-9][a-z0-9-]{1,29}$' then raise exception 'Кодът е 2–30 знака: малки латински букви, цифри и тире (напр. tangra).'; end if;
  if nm = '' then raise exception 'Попълнете името на агенцията.'; end if;
  if exists (select 1 from agencies where code = cd) then raise exception 'Вече има агенция с този код.'; end if;
  insert into agencies (code, name) values (cd, nm) returning id into ag;
  perform _create_user(ag, p_admin_username, p_admin_name, p_admin_password, 'admin', '{}'::jsonb);
  if length(coalesce(p_recovery,'')) >= 8 then
    insert into agency_secrets(agency_id, name, hash) values (ag, 'recovery', crypt(p_recovery, gen_salt('bf')));
  end if;
  -- начални настройки: името на агенцията, без чужди адрес/телефон/лого, без примерни заявки
  insert into records (agency_id, store, key, value) values
    (ag, 'meta', 'settings', jsonb_build_object('key','settings','value', jsonb_build_object(
       'agency', upper(nm), 'short', nm, 'addr', '', 'gsm', '', 'city', '', 'logo', '', 'logoMode', 'none'))),
    (ag, 'meta', 'initialized', jsonb_build_object('key','initialized','value', true));
  return ag;
end $$;

create or replace function public.platform_set_agency_active(p_agency uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  update agencies set active = p_active where id = p_agency;
  if not found then raise exception 'Няма такава агенция.'; end if;
end $$;

-- за поддръжка: агенция е забравила паролата на администратора си и няма код
create or replace function public.platform_reset_password(p_agency uuid, p_username text, p_password text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare uid uuid;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  select id into uid from profiles where agency_id = p_agency and username = lower(trim(p_username));
  if uid is null then raise exception 'Няма такъв потребител в тази агенция.'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
  update profiles set active = true where id = uid;
end $$;

-- ---------- кой може да вика функциите ----------
-- вътрешните — никой отвън (Supabase по подразбиране дава достъп на всички)
revoke execute on function public._make_auth_user(text, text) from public, anon, authenticated;
revoke execute on function public._create_user(uuid, text, text, text, text, jsonb) from public, anon, authenticated;
-- само за влезли
revoke execute on function public.put_atomic(jsonb), public.my_context(), public.touch_login(), public.change_my_password(text, text),
  public.admin_create_user(text, text, text, text, jsonb), public.admin_update_user(uuid, text, text, text, boolean, jsonb, text),
  public.admin_set_password(uuid, text), public.set_recovery(text, text), public.platform_agencies(),
  public.platform_create_agency(text, text, text, text, text, text), public.platform_set_agency_active(uuid, boolean),
  public.platform_reset_password(uuid, text, text) from public, anon;
-- needs_setup, setup_first_admin и recover_admin остават достъпни преди вход (имат собствени проверки)

-- ---------- Word файловете: всяка агенция в своя папка <agency_id>/ ----------
insert into storage.buckets (id, name, public) values ('docs', 'docs', false) on conflict (id) do nothing;
create policy "docs read"   on storage.objects for select to authenticated
  using (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs write"  on storage.objects for insert to authenticated
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs update" on storage.objects for update to authenticated
  using (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text)
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs delete" on storage.objects for delete to authenticated
  using (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
