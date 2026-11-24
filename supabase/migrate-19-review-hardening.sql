-- =====================================================================
-- МИГРАЦИЯ 19 — поправки от прегледа на кода (ноември 2026)
--  1) служителите на агенцията вече НЕ виждат вътрешните бележки на собственика за агенцията им
--     (бележки, месечна такса, лице за контакт, телефон, имейл, ЕИК, адрес в панела на собственика).
--     Програмата не чете тези колони директно — всичко минава през функциите на панела, които остават същите.
--  2) връзката за календара (iCal) спира да работи, когато потребител загуби правото „Заявки“ или бъде спрян.
--     Еднократно се махат и вече съществуващите такива връзки.
-- Данните на агенциите не се променят. Връщане: в края на файла.
-- Пуска се първо в ТЕСТОВИЯ проект (klcaiengszmdvpgkybxn), после в живия.
-- =====================================================================
begin;

-- ---------- 1. агенцията: служителите четат само безопасните колони ----------
do $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'agencies'
    and column_name not in ('notes', 'monthly_fee', 'contact_person', 'contact_phone', 'contact_email', 'eik', 'address');
  execute 'revoke select on public.agencies from anon, authenticated';
  execute format('grant select (%s) on public.agencies to authenticated', cols);
end $$;

-- ---------- 2. календар: без право „Заявки“ — без връзка ----------
create or replace function public._cal_token_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (new.active and (new.role = 'admin' or coalesce(new.perms->>'req', 'none') in ('view', 'edit'))) then
    delete from calendar_tokens where user_id = new.id;
  end if;
  return new;
end $$;
revoke execute on function public._cal_token_cleanup() from public, anon, authenticated;

drop trigger if exists profiles_cal_cleanup on public.profiles;
create trigger profiles_cal_cleanup after update of perms, role, active on public.profiles
  for each row execute function public._cal_token_cleanup();

-- еднократно: връзки на потребители, които вече нямат право
delete from public.calendar_tokens t using public.profiles p
where p.id = t.user_id
  and not (p.active and (p.role = 'admin' or coalesce(p.perms->>'req', 'none') in ('view', 'edit')));

commit;

-- ---------- проверка след пускане (само чете) ----------
-- select column_name from information_schema.column_privileges
--  where table_schema = 'public' and table_name = 'agencies' and grantee = 'authenticated' and privilege_type = 'SELECT';
--  → не трябва да има notes, monthly_fee, contact_*, eik, address

-- ---------- ВРЪЩАНЕ (ако нещо се обърка) ----------
-- begin;
-- revoke select on public.agencies from authenticated;
-- grant select on public.agencies to authenticated;
-- drop trigger if exists profiles_cal_cleanup on public.profiles;
-- drop function if exists public._cal_token_cleanup();
-- commit;
-- (изтритите календарни връзки не се връщат: потребителят натиска „Календар“ и получава нова)
