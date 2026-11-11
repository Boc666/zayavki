-- =====================================================================
-- МИГРАЦИЯ 10 — Етап 2 от одита
--  1) правата за ЧЕТЕНЕ се проверяват и в базата (досега — само за документите):
--       заявки   → някое от: Заявки, Работни листове, Фактури/оферти, Отчети, Табло, Некролози, Склад
--       клиенти  → Клиенти или Заявки (при запис на заявка програмата предлага профил)
--       събития, партньори → Заявки
--       история (audit) → само администратор
--       документи → Документи (както досега);  настройки и каталог (meta) → всички в агенцията
--     Ограничение: правата са по запис, не по поле — който вижда заявката, вижда и сумите в нея.
--  2) изтекъл линк към клиента вече не показва офертата (само „потвърдена/оценена“);
--  3) износ на всички данни на агенция за собственика (за архив и при напускане);
--  4) индекс за историята (бързо зареждане на последните записи).
-- Само правила и функции — данните не се променят. Връщане: в края на файла.
-- =====================================================================
begin;

-- кои видове данни може да чете влезлият — изчислява се ВЕДНЪЖ на заявка (не за всеки ред)
create or replace function public.my_read_stores() returns text[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[
    'meta',
    case when public.can_area('req','view') or public.can_area('ws','view') or public.can_area('docs','view') or public.can_area('fin','view')
           or public.can_area('dash','view') or public.can_area('necro','view') or public.can_area('stock','view') then 'requests' end,
    case when public.can_area('clients','view') or public.can_area('req','view') then 'clients' end,
    case when public.can_area('req','view') then 'events' end,
    case when public.can_area('req','view') then 'partners' end,
    case when public.is_admin() then 'audit' end,
    case when public.can_area('files','view') then 'docs' end], null)
$$;
revoke execute on function public.my_read_stores() from public, anon;
grant execute on function public.my_read_stores() to authenticated;

drop policy if exists "records read" on public.records;
create policy "records read" on public.records for select to authenticated
  using (agency_id = (select public.my_agency()) and store = any ((select public.my_read_stores())::text[]));

create index if not exists records_audit_time on public.records (agency_id, updated_at desc) where store = 'audit';

-- изтекъл линк: без данните на офертата
create or replace function public.public_link_get(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public_links; a agencies;
begin
  select * into l from public_links where token = p_token;
  if l.token is null then return jsonb_build_object('error','missing'); end if;
  select * into a from agencies where id = l.agency_id;
  if l.expires_at < now() then
    if l.response is null then return jsonb_build_object('error','expired'); end if;
    return jsonb_build_object('kind', l.kind, 'data', jsonb_build_object('agency', jsonb_build_object('name', a.name)), 'agency', a.name,
      'response', jsonb_build_object('answer', l.response->>'answer', 'rating', l.response->'rating'), 'responded_at', l.responded_at, 'closed', true);
  end if;
  if l.opened_at is null then update public_links set opened_at = now() where token = p_token; end if;
  return jsonb_build_object('kind', l.kind, 'data', l.data, 'agency', a.name, 'expires_at', l.expires_at,
    'response', l.response, 'responded_at', l.responded_at);
end $$;

-- износ на агенция (собственик): всички записи + потребителите (без пароли). Word файловете остават в хранилището.
create or replace function public.platform_export_agency(p_agency uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a agencies;
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  select * into a from agencies where id = p_agency;
  if a.id is null then raise exception 'Няма такава агенция.'; end if;
  return jsonb_build_object(
    'agency', jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'eik', a.eik, 'address', a.address,
                                 'contact_person', a.contact_person, 'contact_phone', a.contact_phone, 'contact_email', a.contact_email),
    'exported_at', now(),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'name', name, 'role', role, 'active', active,
                          'perms', perms, 'created_at', created_at, 'last_login', last_login) order by username) from profiles where agency_id = a.id), '[]'::jsonb),
    'records', coalesce((select jsonb_agg(jsonb_build_object('store', store, 'key', key, 'value', value, 'updated_at', updated_at) order by store, key)
                          from records where agency_id = a.id), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(name order by name) from storage.objects where bucket_id = 'docs' and ((storage.foldername(name))[1] = a.id::text
                          or (cardinality(storage.foldername(name)) = 0 and a.code = 'tangra'))), '[]'::jsonb));
end $$;
revoke execute on function public.platform_export_agency(uuid) from public, anon;
grant execute on function public.platform_export_agency(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;

-- ---------- ВРЪЩАНЕ ----------
-- begin;
-- drop policy if exists "records read" on public.records;
-- create policy "records read" on public.records for select to authenticated
--   using (agency_id = public.my_agency() and (store <> 'docs' or public.can_area('files','view')));
-- drop function if exists public.platform_export_agency(uuid);
-- (public_link_get — версията от migrate-8-platform-links.sql)
-- notify pgrst, 'reload schema';
-- commit;
