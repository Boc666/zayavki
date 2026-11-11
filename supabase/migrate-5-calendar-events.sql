-- =====================================================================
-- МИГРАЦИЯ 5 — ръчни събития в календара (store 'events')
-- Пуска се след миграция 3. Не променя данни.
--  * събития добавят, променят и изтриват служителите с „Заявки: редактира“ (и администраторът);
--  * виждат ги всички в агенцията (както ритуалите в календара);
--  * изолацията между агенциите е същата.
-- Връщане: в края на файла.
-- =====================================================================
begin;

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

-- изтриване: заявки, документи и вече събития (тригерът проверява правото)
drop policy if exists "records delete" on public.records;
create policy "records delete" on public.records for delete to authenticated
  using (agency_id = public.my_agency() and store in ('requests','docs','events'));

-- позволени видове данни: старите бази имат ограничение само за requests/meta/docs/audit,
-- което спира и клиентските профили (миграция 3) — разширяваме го (нищо съществуващо не се пипа)
alter table public.records drop constraint if exists records_store_check;
alter table public.records add constraint records_store_check
  check (store = any (array['requests','meta','docs','audit','clients','events']));

notify pgrst, 'reload schema';
commit;

-- ВРЪЩАНЕ: пуснете отново функцията records_guard от migrate-3-permissions-versions.sql и:
-- drop policy if exists "records delete" on public.records;
-- create policy "records delete" on public.records for delete to authenticated
--   using (agency_id = public.my_agency() and store in ('requests','docs'));
-- (записаните събития остават в базата, но приложението вече няма да може да ги променя)
