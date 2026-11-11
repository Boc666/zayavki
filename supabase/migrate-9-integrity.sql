-- =====================================================================
-- МИГРАЦИЯ 9 — цялост на данните (Етап 1 от одита)
--  1) номерата на заявките и фактурите се раздават от базата (броячи) и не могат да се повторят (уникални индекси);
--  2) атомарен запис на няколко реда с проверка на версията (склад + заявка) — put_atomic_v;
--  3) възстановяване на парола: брояч на опитите и временно заключване; при смяна на парола
--     останалите влизания на потребителя се прекратяват.
-- Само добавя. Съществуващите данни не се променят. Уникалните индекси се създават само ако
-- няма вече повторени номера (иначе — съобщение, и броячите пак работят).
-- Връщане: в края на файла.
-- =====================================================================
begin;

-- ---------- 1. броячи ----------
create table if not exists public.counters (
  agency_id uuid not null references public.agencies(id) on delete cascade,
  name      text not null check (name in ('request','invoice')),
  next      bigint not null check (next >= 1),
  primary key (agency_id, name)
);
alter table public.counters enable row level security;
revoke all on public.counters from anon, authenticated;

-- първа стойност: по-голямото от досегашната настройка и най-големия използван номер + 1
create or replace function public._counter_seed(p_agency uuid, p_name text) returns bigint
language sql stable security definer set search_path = public as $$
  select greatest(1,
    coalesce((select nullif(value->'value'->>case when p_name = 'request' then 'nextNo' else 'invNext' end,'')::bigint
              from records where agency_id = p_agency and store = 'meta' and key = 'settings'), 1),
    coalesce((select max(nullif(regexp_replace(case when p_name = 'request' then value->>'number' else value->'inv'->>'number' end, '\D', '', 'g'), '')::numeric)::bigint + 1
              from records where agency_id = p_agency and store = 'requests' and coalesce(value->>'sample','false') <> 'true'
                and length(regexp_replace(coalesce(case when p_name = 'request' then value->>'number' else value->'inv'->>'number' end,''), '\D', '', 'g')) between 1 and 15), 1))
$$;

create or replace function public._number_used(p_agency uuid, p_name text, n bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from records where agency_id = p_agency and store = 'requests'
    and coalesce(value->>'sample','false') <> 'true'
    and regexp_replace(coalesce(case when p_name = 'request' then value->>'number' else value->'inv'->>'number' end,''), '\D', '', 'g') ~ '^\d{1,15}$'
    and regexp_replace(coalesce(case when p_name = 'request' then value->>'number' else value->'inv'->>'number' end,''), '\D', '', 'g')::numeric = n)
$$;

create or replace function public._counter_check(p_name text, p_admin boolean) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare ag uuid := public.my_agency();
begin
  if ag is null then raise exception 'Нямате достъп.'; end if;
  if p_name not in ('request','invoice') then raise exception 'Непознат брояч.'; end if;
  if p_admin and not public.is_admin() then raise exception 'Само администратор може да сменя номерацията.'; end if;
  if not p_admin and not public.can_area(case when p_name = 'request' then 'req' else 'docs' end, 'edit') then
    raise exception 'Нямате права да издавате номера.'; end if;
  return ag;
end $$;

-- следващият свободен номер (взима го — никой друг няма да получи същия)
create or replace function public.take_number(p_name text) returns bigint
language plpgsql security definer set search_path = public as $$
declare ag uuid := public._counter_check(p_name, false); n bigint;
begin
  insert into counters (agency_id, name, next) values (ag, p_name, public._counter_seed(ag, p_name)) on conflict do nothing;
  loop
    update counters set next = next + 1 where agency_id = ag and name = p_name returning next - 1 into n;
    exit when not public._number_used(ag, p_name, n);   -- прескача номера, въведени на ръка
  end loop;
  return n;
end $$;

-- след ръчно въведен номер: броячът да не го раздаде пак
create or replace function public.bump_number(p_name text, p_value bigint) returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid := public._counter_check(p_name, false);
begin
  if p_value is null or p_value < 1 then return; end if;
  insert into counters (agency_id, name, next) values (ag, p_name, greatest(public._counter_seed(ag, p_name), p_value + 1))
  on conflict (agency_id, name) do update set next = greatest(counters.next, p_value + 1);
end $$;

-- администратор: задава следващия номер (Настройки)
create or replace function public.set_number(p_name text, p_value bigint) returns void
language plpgsql security definer set search_path = public as $$
declare ag uuid := public._counter_check(p_name, true);
begin
  if p_value is null or p_value < 1 then raise exception 'Номерът трябва да е поне 1.'; end if;
  insert into counters (agency_id, name, next) values (ag, p_name, p_value)
  on conflict (agency_id, name) do update set next = p_value;
end $$;

-- какви са следващите номера (за показване в празна заявка / фактура)
create or replace function public.peek_numbers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ag uuid := public.my_agency();
begin
  if ag is null then raise exception 'Нямате достъп.'; end if;
  return jsonb_build_object(
    'request', coalesce((select next from counters where agency_id = ag and name = 'request'), public._counter_seed(ag, 'request')),
    'invoice', coalesce((select next from counters where agency_id = ag and name = 'invoice'), public._counter_seed(ag, 'invoice')));
end $$;

-- уникални номера — само ако вече няма повторени (иначе съобщение; приложението пак ги предотвратява за новите)
do $$
begin
  if not exists (select 1 from records where store = 'requests' and coalesce(value->>'sample','false') <> 'true' and coalesce(value->>'number','') <> ''
                 group by agency_id, value->>'number' having count(*) > 1) then
    create unique index if not exists records_request_number_uq on public.records (agency_id, (value->>'number'))
      where store = 'requests' and coalesce(value->>'sample','false') <> 'true' and coalesce(value->>'number','') <> '';
  else raise notice 'Има повторени номера на заявки — уникалният индекс НЕ е създаден. Оправете ги и пуснете миграцията пак.'; end if;
  if not exists (select 1 from records where store = 'requests' and coalesce(value->'inv'->>'number','') <> ''
                 group by agency_id, value->'inv'->>'number' having count(*) > 1) then
    create unique index if not exists records_invoice_number_uq on public.records (agency_id, (value->'inv'->>'number'))
      where store = 'requests' and coalesce(value->'inv'->>'number','') <> '';
  else raise notice 'Има повторени номера на фактури — уникалният индекс НЕ е създаден.'; end if;
end $$;

-- ---------- 2. атомарен запис с проверка на версията ----------
-- ops: [{store, key, value, expected}] — expected = версията, която клиентът е прочел (null = без проверка)
-- При разминаване: грешка 'CONFLICT:<store>:<key>' и нищо не се записва. Връща {"store:key": нова версия}.
-- SECURITY INVOKER — правата (RLS + records_guard) важат както при всеки запис.
create or replace function public.put_atomic_v(ops jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare o jsonb; ag uuid := public.my_agency(); cur integer; nv integer; out jsonb := '{}'::jsonb;
begin
  if ag is null then raise exception 'not allowed'; end if;
  for o in select * from jsonb_array_elements(ops) loop
    if o->>'store' = 'audit' then
      insert into records (agency_id, store, key, value) values (ag, 'audit', o->>'key', o->'value') on conflict (agency_id, store, key) do nothing;
      continue;
    end if;
    select version into cur from records where agency_id = ag and store = o->>'store' and key = o->>'key' for update;
    if o ? 'expected' and o->>'expected' is not null and (cur is null or cur <> (o->>'expected')::integer) then
      raise exception 'CONFLICT:%:%', o->>'store', o->>'key';
    end if;
    if cur is null then
      insert into records (agency_id, store, key, value, updated_at, updated_by) values (ag, o->>'store', o->>'key', o->'value', now(), auth.uid())
      returning version into nv;
    else
      update records set value = o->'value', updated_at = now(), updated_by = auth.uid()
      where agency_id = ag and store = o->>'store' and key = o->>'key' returning version into nv;
    end if;
    out := out || jsonb_build_object((o->>'store') || ':' || (o->>'key'), nv);
  end loop;
  return out;
end $$;

-- ---------- 3. пароли ----------
create table if not exists public.auth_attempts (
  id  bigserial primary key,
  key text not null,
  at  timestamptz not null default now()
);
create index if not exists auth_attempts_key on public.auth_attempts (key, at desc);
alter table public.auth_attempts enable row level security;
revoke all on public.auth_attempts from anon, authenticated;

-- прекратява влизанията на потребител (освен текущото, ако е подадено)
create or replace function public._revoke_sessions(p_user uuid, p_keep uuid default null) returns void
language sql security definer set search_path = public, auth as $$
  delete from auth.sessions where user_id = p_user and (p_keep is null or id <> p_keep)
$$;

-- възстановяване с код: най-много 5 грешни опита за 15 минути (за агенция+потребител и общо за агенцията — 20)
drop function if exists public.recover_admin(text, text, text, text);
create function public.recover_admin(p_agency text, p_username text, p_code text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, auth, extensions as $$
declare s text; uid uuid; un text := lower(trim(p_username)); ac text := lower(trim(coalesce(p_agency,''))); ag uuid;
        k1 text := 'rec:' || ac || '/' || un; k2 text := 'rec:' || ac;
begin
  perform pg_sleep(1);
  delete from auth_attempts where at < now() - interval '1 day';
  if (select count(*) from auth_attempts where key = k1 and at > now() - interval '15 minutes') >= 5
     or (select count(*) from auth_attempts where key = k2 and at > now() - interval '15 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'msg', 'Твърде много грешни опити. Опитайте отново след 15 минути или се обадете на тел. ' ||
      coalesce((select support_phone from platform_settings where id = 1), '+359 893 008 182') || '.');
  end if;
  if ac = '' then
    select hash into s from platform_secrets where name = 'recovery';
    select id into uid from platform_admins where username = un;
  else
    select id into ag from agencies where code = ac;
    select hash into s from agency_secrets where agency_id = ag and name = 'recovery';
    select id into uid from profiles where agency_id = ag and username = un and role = 'admin';
  end if;
  if s is null or uid is null or crypt(coalesce(p_code,''), s) <> s then
    insert into auth_attempts (key) values (k1), (k2);
    return jsonb_build_object('ok', false, 'msg', 'Грешни данни или код.');
  end if;
  if length(coalesce(p_password,'')) < 6 then return jsonb_build_object('ok', false, 'msg', 'Паролата трябва да е поне 6 знака.'); end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
  update profiles set active = true where id = uid;
  delete from auth_attempts where key = k1;
  perform public._revoke_sessions(uid);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.recover_admin(text, text, text, text) to anon, authenticated;

create or replace function public.change_my_password(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare h text;
begin
  select encrypted_password into h from auth.users where id = auth.uid();
  if h is null or crypt(coalesce(p_old,''), h) <> h then raise exception 'Сегашната парола е грешна.'; end if;
  if length(coalesce(p_new,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_new, gen_salt('bf')), updated_at = now() where id = auth.uid();
  perform public._revoke_sessions(auth.uid(), nullif(auth.jwt()->>'session_id','')::uuid);   -- другите устройства излизат
end $$;

create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not is_admin() then raise exception 'Само администратор.'; end if;
  if not exists (select 1 from profiles where id = p_user and agency_id = my_agency()) then raise exception 'Няма такъв потребител.'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'Паролата трябва да е поне 6 знака.'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
  perform public._revoke_sessions(p_user);
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
  if coalesce(p_password,'') <> '' or (cur.active and not p_active) then perform public._revoke_sessions(p_user); end if;   -- нова парола или спрян
end $$;

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
  perform public._revoke_sessions(uid);
end $$;

-- ---------- кой може да вика функциите ----------
revoke execute on function public._counter_seed(uuid, text), public._number_used(uuid, text, bigint), public._counter_check(text, boolean),
  public._revoke_sessions(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.take_number(text), public.bump_number(text, bigint), public.set_number(text, bigint), public.peek_numbers(),
  public.put_atomic_v(jsonb) from public, anon;
grant execute on function public.take_number(text), public.bump_number(text, bigint), public.set_number(text, bigint), public.peek_numbers(),
  public.put_atomic_v(jsonb) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ---------- ВРЪЩАНЕ ----------
-- Приложението само разпознава липсата на новите функции и минава на стария начин.
-- begin;
-- drop index if exists public.records_request_number_uq, public.records_invoice_number_uq;
-- drop function if exists public.take_number(text), public.bump_number(text, bigint), public.set_number(text, bigint), public.peek_numbers(),
--   public.put_atomic_v(jsonb), public._counter_check(text, boolean), public._number_used(uuid, text, bigint), public._counter_seed(uuid, text);
-- drop table if exists public.counters;
-- recover_admin: върнете версията от fix-cyrillic.sql (връща void) — ВНИМАНИЕ: тогава и приложението трябва да е отпреди миграция 9.
-- drop table if exists public.auth_attempts;
-- commit;
