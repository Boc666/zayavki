
-- ---------- Word файловете: всяка агенция в своя папка <agency_id>/ ----------
-- Старите файлове на Тангра са без папка — само Тангра ги вижда; новите отиват в папката ѝ.
create policy "docs read"   on storage.objects for select to authenticated
  using (bucket_id = 'docs' and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));
create policy "docs write"  on storage.objects for insert to authenticated
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs update" on storage.objects for update to authenticated
  using (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text)
  with check (bucket_id = 'docs' and (storage.foldername(name))[1] = public.my_agency()::text);
create policy "docs delete" on storage.objects for delete to authenticated
  using (bucket_id = 'docs' and ((storage.foldername(name))[1] = public.my_agency()::text
         or (cardinality(storage.foldername(name)) = 0 and public.my_agency() = (select id from public.agencies where code = 'tangra'))));

-- ---------- 6) входът на служителите: потребител → код tangra + потребител ----------
update auth.users u set email = public.username_email('tangra', p.username), updated_at = now()
  from public.profiles p where p.id = u.id;
update auth.identities i set identity_data = i.identity_data || jsonb_build_object('email', public.username_email('tangra', p.username))
  from public.profiles p where i.user_id = p.id and i.provider = 'email';

-- ---------- 7) собственикът на платформата (временна парола) ----------
create temp table _mig_owner as
  select 'boc666'::text as username,
         translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/=', 'xyz') as temp_password;
insert into public.platform_admins (id, username, name)
  select public._make_auth_user(public.platform_email(username), temp_password), username, 'Собственик' from _mig_owner;

-- ---------- 8) проверка преди запис ----------
do $$ declare b record; bad int; begin
  select * into b from _mig_before;
  if (select count(*) from public.profiles) <> b.profiles then raise exception 'СПРЯНО: броят служители се промени.'; end if;
  if (select count(*) from public.records) <> b.records then raise exception 'СПРЯНО: броят записи се промени.'; end if;
  select count(*) into bad from public.profiles p join auth.users u on u.id = p.id
    where u.email <> public.username_email('tangra', p.username);
  if bad > 0 then raise exception 'СПРЯНО: % служители не получиха новия вход.', bad; end if;
end $$;

commit;

-- ---------- резултат ----------
select o.username as "собственик (вход с празен код на агенция)",
       o.temp_password as "временна парола — запишете я и я сменете",
       (select count(*) from public.profiles) as "служители на Тангра",
       (select count(*) from public.records where store = 'requests') as "заявки на Тангра",
       (select count(*) from public.records) as "всички записи"
from _mig_owner o;
