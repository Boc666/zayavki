-- ============================================================
-- Миграция 12: публичен каталог за клиенти (QR витрина)
-- Снимките се пазят в ПУБЛИЧНА папка „showcase"; близките отварят
-- каталога без вход по кода на агенцията (public_showcase).
-- Само добавя — не трие данни.
-- ============================================================
set search_path = public;

-- публична папка за снимките на каталога
insert into storage.buckets (id, name, public) values ('showcase','showcase',true)
  on conflict (id) do nothing;

-- качване/промяна/триене — само в папката на своята агенция (<agency_id>/...)
do $$
begin
  if not exists (select 1 from pg_policies where tablename='objects' and policyname='showcase write') then
    create policy "showcase write" on storage.objects for insert to authenticated
      with check (bucket_id='showcase' and (storage.foldername(name))[1] = public.my_agency()::text);
  end if;
  if not exists (select 1 from pg_policies where tablename='objects' and policyname='showcase update') then
    create policy "showcase update" on storage.objects for update to authenticated
      using (bucket_id='showcase' and (storage.foldername(name))[1] = public.my_agency()::text)
      with check (bucket_id='showcase' and (storage.foldername(name))[1] = public.my_agency()::text);
  end if;
  if not exists (select 1 from pg_policies where tablename='objects' and policyname='showcase delete') then
    create policy "showcase delete" on storage.objects for delete to authenticated
      using (bucket_id='showcase' and (storage.foldername(name))[1] = public.my_agency()::text);
  end if;
  if not exists (select 1 from pg_policies where tablename='objects' and policyname='showcase read') then
    create policy "showcase read" on storage.objects for select to anon, authenticated
      using (bucket_id='showcase');
  end if;
end $$;

-- публичен прочит на каталога по код на агенцията (за katalog.html)
create or replace function public.public_showcase(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a agencies; sett jsonb; sc jsonb;
begin
  select * into a from agencies
    where code = lower(trim(p_code)) and active
      and (access_until is null or access_until > now());
  if a.id is null then return jsonb_build_object('error','missing'); end if;
  select value->'value' into sett from records where agency_id=a.id and store='meta' and key='settings';
  select value->'value' into sc   from records where agency_id=a.id and store='meta' and key='showcase';
  if sc is null or coalesce((sc->>'on')::boolean, false) = false then
    return jsonb_build_object('off', true, 'agency', jsonb_build_object('name', a.name));
  end if;
  return jsonb_build_object(
    'agency', jsonb_build_object('name', a.name, 'short', sett->>'short', 'gsm', sett->>'gsm', 'logo', sett->>'logo'),
    'showcase', sc
  );
end $$;
revoke execute on function public.public_showcase(text) from public;
grant  execute on function public.public_showcase(text) to anon, authenticated;

notify pgrst, 'reload schema';
