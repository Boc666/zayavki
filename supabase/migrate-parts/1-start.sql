-- =====================================================================
-- ПРЕМЕСТВАНЕ НА ТАНГРА към базата за много агенции
-- Пуска се ВЕДНЪЖ в ИСТИНСКИЯ проект (tdgsyvqfpebexycjnwal): SQL Editor → постави всичко → Run.
--
-- Какво прави:
--   • създава агенция „Тангра“ с код за вход  tangra  и закача към нея ВСИЧКИ съществуващи данни;
--   • служителите си запазват паролите (при вход пишат и код  tangra);
--   • старите Word файлове остават където са (приложението ги намира);
--   • създава собственика на платформата  boc666  с временна парола (показва се в резултата — сменете я).
-- Ако нещо не е както се очаква, скриптът спира и НЕ променя нищо (всичко е в една транзакция).
-- Файлът е сглобен автоматично от supabase/migrate-parts/ — редактирайте частите, не него.
-- =====================================================================

begin;

-- ---------- 0) проверка: това ли е старата база на Тангра ----------
do $$ begin
  if to_regclass('public.agencies') is not null then
    raise exception 'СПРЯНО: базата вече е преместена (има таблица agencies). Нищо не е променено.'; end if;
  if to_regclass('public.profiles') is null or to_regclass('public.records') is null or to_regclass('public.app_secrets') is null then
    raise exception 'СПРЯНО: това не е базата на Тангра (липсват profiles/records/app_secrets). Нищо не е променено.'; end if;
end $$;

create temp table _mig_before as
  select (select count(*) from public.profiles) as profiles, (select count(*) from public.records) as records;

-- ---------- 1) нови таблици ----------
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

insert into public.agencies (code, name) values ('tangra', 'Погребална агенция „Тангра“');

-- ---------- 2) служителите → агенция Тангра ----------
alter table public.profiles add column agency_id uuid references public.agencies(id) on delete cascade;
update public.profiles set agency_id = (select id from public.agencies where code = 'tangra');
alter table public.profiles alter column agency_id set not null;
do $$ declare c record; begin  -- потребителското име вече е уникално в рамките на агенцията, не глобално
  for c in select conname from pg_constraint where conrelid = 'public.profiles'::regclass and contype = 'u' loop
    execute format('alter table public.profiles drop constraint %I', c.conname); end loop;
  for c in select i.relname from pg_index x join pg_class i on i.oid = x.indexrelid
           where x.indrelid = 'public.profiles'::regclass and x.indisunique and not x.indisprimary loop
    execute format('drop index public.%I', c.relname); end loop;
end $$;
alter table public.profiles add constraint profiles_agency_username_key unique (agency_id, username);

-- ---------- 3) данните → агенция Тангра ----------
alter table public.records add column agency_id uuid references public.agencies(id) on delete cascade;
update public.records set agency_id = (select id from public.agencies where code = 'tangra');
alter table public.records alter column agency_id set not null;
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.records'::regclass and contype in ('p','u') loop
    execute format('alter table public.records drop constraint %I', c.conname); end loop;
  for c in select i.relname from pg_index x join pg_class i on i.oid = x.indexrelid
           where x.indrelid = 'public.records'::regclass and x.indisunique loop
    execute format('drop index public.%I', c.relname); end loop;
end $$;
alter table public.records add primary key (agency_id, store, key);

-- ---------- 4) кодът за възстановяване на администратора на Тангра ----------
insert into public.agency_secrets (agency_id, name, hash)
  select (select id from public.agencies where code = 'tangra'), name, hash from public.app_secrets;

-- ---------- 5) старите правила и функции ----------
drop policy if exists "records delete" on public.records;
drop policy if exists "records update" on public.records;
drop policy if exists "records insert" on public.records;
drop policy if exists "records read"   on public.records;
drop policy if exists "profiles admin write" on public.profiles;
drop policy if exists "profiles read"  on public.profiles;
drop policy if exists "docs files delete" on storage.objects;
drop policy if exists "docs files update" on storage.objects;
drop policy if exists "docs files write"  on storage.objects;
drop policy if exists "docs files read"   on storage.objects;
drop function if exists public.username_email(text);
drop function if exists public._create_user(text, text, text, text, jsonb);
drop function if exists public.recover_admin(text, text, text);

