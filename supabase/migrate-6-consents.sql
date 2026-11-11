-- =====================================================================
-- МИГРАЦИЯ 6 — приемане на Общите условия и Договора за обработване на лични данни
-- Пуска се след миграция 2. Само добавя (нова таблица + функции); нищо съществуващо не се пипа.
--
--   terms — всеки потребител на агенция приема Общите условия и Политиката за поверителност
--           (веднъж за всяка версия; при нова версия — пак веднъж)
--   dpa   — администраторът на агенцията приема Договора за обработване от името на агенцията
--
-- Приложението работи и БЕЗ тази миграция (просто не пита за съгласие).
-- Връщане: в края на файла.
-- =====================================================================
begin;

create table if not exists public.consents (
  id          bigserial primary key,
  user_id     uuid not null,
  agency_id   uuid references public.agencies(id) on delete cascade,
  kind        text not null check (kind in ('terms','dpa')),
  version     text not null,
  username    text not null default '',
  name        text not null default '',
  user_agent  text not null default '',
  accepted_at timestamptz not null default now()
);
create index if not exists consents_user   on public.consents (user_id, kind, accepted_at desc);
create index if not exists consents_agency on public.consents (agency_id, kind, accepted_at desc);
alter table public.consents enable row level security;   -- без правила: достъп само през функциите
revoke all on public.consents from anon, authenticated;

-- какво е приел влезлият (и агенцията му): последните версии
create or replace function public.my_consents() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'terms', (select version from consents where user_id = auth.uid() and kind = 'terms' order by accepted_at desc limit 1),
    'dpa',   (select version from consents c join profiles p on p.id = auth.uid()
               where c.agency_id = p.agency_id and c.kind = 'dpa' order by c.accepted_at desc limit 1))
$$;

-- приемане: условията — всеки служител за себе си; договорът — само администратор на агенцията
create or replace function public.accept_terms(p_terms text, p_dpa text default null, p_ua text default '') returns void
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select pr.id, pr.agency_id, pr.username, pr.name, pr.role into p
    from profiles pr where pr.id = auth.uid() and pr.active;
  if p.id is null then raise exception 'Само за потребители на агенция.'; end if;
  if coalesce(p_terms,'') = '' and coalesce(p_dpa,'') = '' then raise exception 'Няма какво да се приеме.'; end if;
  if coalesce(p_terms,'') <> '' then
    insert into consents (user_id, agency_id, kind, version, username, name, user_agent)
      values (p.id, p.agency_id, 'terms', p_terms, p.username, p.name, left(coalesce(p_ua,''), 300));
  end if;
  if coalesce(p_dpa,'') <> '' then
    if p.role <> 'admin' then raise exception 'Договора приема администраторът на агенцията.'; end if;
    insert into consents (user_id, agency_id, kind, version, username, name, user_agent)
      values (p.id, p.agency_id, 'dpa', p_dpa, p.username, p.name, left(coalesce(p_ua,''), 300));
  end if;
end $$;

-- собственик: всички приемания (най-новите първо)
create or replace function public.platform_consents() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform() then raise exception 'Само за собственика на платформата.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'agency_id', c.agency_id, 'code', a.code, 'agency', a.name, 'kind', c.kind, 'version', c.version,
      'username', c.username, 'name', c.name, 'at', c.accepted_at) order by c.accepted_at desc)
    from consents c left join agencies a on a.id = c.agency_id), '[]'::jsonb);
end $$;

revoke execute on function public.my_consents(), public.accept_terms(text, text, text), public.platform_consents()
  from public, anon;
grant execute on function public.my_consents(), public.accept_terms(text, text, text), public.platform_consents()
  to authenticated;

notify pgrst, 'reload schema';
commit;

-- ---------- ВРЪЩАНЕ ----------
-- begin;
-- drop function if exists public.platform_consents();
-- drop function if exists public.accept_terms(text, text, text);
-- drop function if exists public.my_consents();
-- drop table if exists public.consents;   -- ВНИМАНИЕ: губи се записът кой какво е приел
-- notify pgrst, 'reload schema';
-- commit;
