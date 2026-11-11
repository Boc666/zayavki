-- =====================================================================
-- МИГРАЦИЯ 7 — указател „Партньори“ (store partners)
-- Само разширява позволените видове данни и правилото за изтриване. Нищо съществуващо не се пипа.
-- Права: четат всички в агенцията; добавя, променя и трие само администратор
--        (records_guard вече пуска непознатите видове данни само за администратор).
-- Връщане: в края на файла.
-- =====================================================================
begin;

alter table public.records drop constraint if exists records_store_check;
alter table public.records add constraint records_store_check
  check (store = any (array['requests','meta','docs','audit','clients','events','partners']));

drop policy if exists "records delete" on public.records;
create policy "records delete" on public.records for delete to authenticated
  using (agency_id = public.my_agency() and store in ('requests','docs','events','partners'));

notify pgrst, 'reload schema';
commit;

-- ---------- ВРЪЩАНЕ ----------
-- begin;
-- delete from public.records where store = 'partners';   -- ВНИМАНИЕ: трие указателя
-- alter table public.records drop constraint if exists records_store_check;
-- alter table public.records add constraint records_store_check
--   check (store = any (array['requests','meta','docs','audit','clients','events']));
-- drop policy if exists "records delete" on public.records;
-- create policy "records delete" on public.records for delete to authenticated
--   using (agency_id = public.my_agency() and store in ('requests','docs','events'));
-- notify pgrst, 'reload schema';
-- commit;
