-- =====================================================================
-- ВРЪЩАНЕ НА МИГРАЦИЯ 3 (права в базата + версии). Данните не се губят.
-- Колоната version остава (безвредна; старото приложение не я чете).
-- След връщане приложението работи постарому: записът без проверка на версията
-- (приложението само разпознава липсата на save_record и минава на стария запис).
-- =====================================================================
begin;
drop trigger if exists records_guard on public.records;
drop function if exists public.records_guard();
drop function if exists public.save_record(text, text, jsonb, integer);

drop policy if exists "records read" on public.records;
create policy "records read" on public.records for select to authenticated using (agency_id = public.my_agency());

drop policy if exists "docs read"   on storage.objects;
drop policy if exists "docs write"  on storage.objects;
drop policy if exists "docs update" on storage.objects;
drop policy if exists "docs delete" on storage.objects;
create policy "docs read" on storage.objects for select to authenticated
  using (bucket_id = 'docs' and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));
create policy "docs write" on storage.objects for insert to authenticated
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs update" on storage.objects for update to authenticated
  using (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text)
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs delete" on storage.objects for delete to authenticated
  using (bucket_id = 'docs' and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));

drop function if exists public.can_area(text, text);
drop function if exists public.my_perm(text);
drop function if exists public.my_flag(text);
notify pgrst, 'reload schema';
commit;
-- по желание, ако колоната трябва да изчезне:  alter table public.records drop column version;
