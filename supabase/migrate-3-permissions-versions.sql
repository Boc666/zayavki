-- =====================================================================
-- МИГРАЦИЯ 3 — права, наложени от базата + версия на всеки запис
-- СТАТУС: за преглед. НЕ е изпълнявана никъде.
-- Ред: първо в тестовия проект → проверки (виж края на файла) → после в истинския.
-- Връщане: supabase/migrate-3-rollback.sql
--
-- Какво прави:
--  1) Правата от профила (perms) се проверяват В БАЗАТА, не само в интерфейса:
--     заявки, работни листове, фактури/оферти, каталог, настройки, склад,
--     некролози, документи, клиенти. Изтриване на заявки — само с флаг reqdel.
--  2) Историята (store 'audit') е само за добавяне; сървърът добавя час и автор.
--  3) Всеки запис получава колона version (+1 при всяка промяна) и RPC save_record
--     с атомарна проверка на версията — защита от тихо презаписване.
--  4) Документите (Word) се четат само с право „Документи: вижда“, пишат с „редактира“.
--  Изолацията между агенциите (my_agency) НЕ се променя — правилата само я стесняват.
--  Данните НЕ се променят: само се добавя колона с подразбираща се стойност 1.
-- =====================================================================
begin;

-- ---------- 1. помощни функции за права ----------
-- нивото на влезлия за даден раздел: 'edit' | 'view' | 'none' (администратор/собственик в агенция = 'edit')
create or replace function public.my_perm(p_area text) returns text
language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then 'edit'
    else coalesce((select p.perms->>p_area from profiles p
                   where p.id = auth.uid() and p.active and p.agency_id = public.my_agency()), 'none') end
$$;
create or replace function public.can_area(p_area text, p_lvl text default 'view') returns boolean
language sql stable set search_path = public as $$
  select case public.my_perm(p_area) when 'edit' then true when 'view' then p_lvl = 'view' else false end
$$;
-- отделни флагове (reqdel, stockadj) — булеви в perms
create or replace function public.my_flag(p_flag text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or coalesce((select (p.perms->>p_flag) = 'true' from profiles p
                   where p.id = auth.uid() and p.active and p.agency_id = public.my_agency()), false)
$$;

-- ---------- 2. версия на записа ----------
alter table public.records add column if not exists version integer not null default 1;

-- ---------- 3. пазач на всеки запис (права по раздел + версия + история само за добавяне) ----------
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
    if st not in ('requests','docs') and not public.is_admin() then raise exception 'Само администратор може да изтрива.'; end if;
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

  elsif st = 'clients' then
    if not public.can_area('clients','edit') then raise exception 'Нямате права да променяте клиентски профили.'; end if;

  elsif not public.is_admin() then
    raise exception 'Само администратор.';
  end if;

  if tg_op = 'UPDATE' then new.version := old.version + 1; end if;
  return new;
end $$;

drop trigger if exists records_guard on public.records;
create trigger records_guard before insert or update or delete on public.records
  for each row execute function public.records_guard();

-- ---------- 4. четене: документите само с право „Документи“ ----------
drop policy if exists "records read" on public.records;
create policy "records read" on public.records for select to authenticated
  using (agency_id = public.my_agency() and (store <> 'docs' or public.can_area('files','view')));

-- Word файловете в хранилището — същото правило
drop policy if exists "docs read"   on storage.objects;
drop policy if exists "docs write"  on storage.objects;
drop policy if exists "docs update" on storage.objects;
drop policy if exists "docs delete" on storage.objects;
create policy "docs read" on storage.objects for select to authenticated
  using (bucket_id = 'docs' and public.can_area('files','view') and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));
create policy "docs write" on storage.objects for insert to authenticated
  with check (bucket_id = 'docs' and public.can_area('files','edit') and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs update" on storage.objects for update to authenticated
  using (bucket_id = 'docs' and public.can_area('files','edit') and (storage.foldername(name))[1] = public.my_agency()::text)
  with check (bucket_id = 'docs' and public.can_area('files','edit') and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs delete" on storage.objects for delete to authenticated
  using (bucket_id = 'docs' and public.can_area('files','edit') and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));

-- ---------- 5. запис с проверка на версията (защита от презаписване) ----------
-- p_expected = версията, която клиентът е отворил (null = нов запис).
-- Връща {ok:true, version} или {ok:false, conflict:true, version, updated_at, updated_by, value}.
-- SECURITY INVOKER: правата (RLS + records_guard) важат както при всеки друг запис.
create or replace function public.save_record(p_store text, p_key text, p_value jsonb, p_expected integer)
returns jsonb language plpgsql set search_path = public as $$
declare ag uuid := public.my_agency(); cur public.records; nv integer; who text;
begin
  if ag is null then raise exception 'not allowed'; end if;
  select * into cur from public.records where agency_id = ag and store = p_store and key = p_key for update;
  if found then
    if p_expected is null or cur.version <> p_expected then
      select name into who from public.profiles where id = cur.updated_by;
      return jsonb_build_object('ok', false, 'conflict', true, 'version', cur.version, 'updated_at', cur.updated_at,
                                'updated_by', coalesce(who, ''), 'value', cur.value);
    end if;
    update public.records set value = p_value, updated_at = now(), updated_by = auth.uid()
      where agency_id = ag and store = p_store and key = p_key returning version into nv;
  else
    if p_expected is not null then
      return jsonb_build_object('ok', false, 'conflict', true, 'deleted', true);
    end if;
    insert into public.records (agency_id, store, key, value, updated_at, updated_by)
      values (ag, p_store, p_key, p_value, now(), auth.uid()) returning version into nv;
  end if;
  return jsonb_build_object('ok', true, 'version', nv);
end $$;

-- ---------- 6. кой може да вика функциите ----------
revoke execute on function public.save_record(text, text, jsonb, integer) from public, anon;
revoke execute on function public.records_guard() from public, anon, authenticated;
-- my_perm / can_area / my_flag се ползват от правилата; връщат само правата на самия влязъл
revoke execute on function public.my_perm(text), public.can_area(text, text), public.my_flag(text) from public, anon;

notify pgrst, 'reload schema';
commit;

-- =====================================================================
-- ПРОВЕРКИ СЛЕД ИЗПЪЛНЕНИЕ (в тестовия проект, с потребители с различни права):
--  * служител „Заявки: вижда“ → PATCH /rest/v1/records (store=requests) → грешка „Нямате права…“
--  * служител „Работни листове: редактира“, „Заявки: вижда“ → промяна само на value.ws → успех;
--    промяна на value.decName → грешка
--  * служител без админ права → промяна на meta/settings (име на агенцията) → грешка;
--    само nextNo +1 с „Заявки: редактира“ → успех
--  * DELETE на заявка без флаг reqdel → грешка; DELETE на audit → грешка (и RLS, и тригер)
--  * save_record с остаряла версия → {conflict:true, updated_by:"…"}
--  * GET /rest/v1/records?store=eq.docs без право „Документи“ → []
--  * агенция А не вижда/пише в агенция Б (непроменено)
-- ОГРАНИЧЕНИЯ (виж и бележката в отговора):
--  * Четенето на заявките е общо за агенцията: „Финанси: няма достъп“ крие сумите само в интерфейса,
--    защото цените са в същия JSON. Истинско скриване изисква отделни таблици (Етап Б по-долу).
--  * Складът: с „Заявки: редактира“ може да се пише в meta/inventory (нужно за изписване от заявка).
--  * Историята се чете от всички в агенцията (таблото показва „Последни действия“).
-- ЕТАП Б (предложение, не е част от тази миграция): отделни таблици requests / worksheets /
--  invoices / payments / stock_moves с колони вместо JSON — тогава правата и четенето по колони,
--  складът само чрез RPC с проверка, и отчетите без достъп до суровите цени.
-- =====================================================================
