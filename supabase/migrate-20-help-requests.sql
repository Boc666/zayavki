-- =====================================================================
-- МИГРАЦИЯ 20 — запитвания от бутона „Помощ“ (изисква миграции 16 и 17)
--  Съобщението се записва в help_requests и отива в Telegram на собственика през _tg_send().
--  Агенцията и името на потребителя се взимат от входа, не от браузъра.
--  Лимити: 5 на час от потребител, 20 на ден от агенция, до 1500 знака.
-- Само добавя: съществуващите данни не се променят. Връщане: в края на файла.
-- Пуска се първо в ТЕСТОВИЯ проект (klcaiengszmdvpgkybxn), после в живия.
-- =====================================================================
begin;

create table if not exists public.help_requests(
  id         uuid primary key,
  agency_id  uuid not null references public.agencies(id) on delete cascade,
  user_id    uuid not null,
  user_name  text not null default '',
  topic      text not null,
  body       text not null,
  phone      text not null default '',
  info       text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists help_requests_agency_idx on public.help_requests(agency_id, created_at);
alter table public.help_requests enable row level security;   -- без политики: само през функцията
revoke all on public.help_requests from public, anon, authenticated;

create or replace function public.help_request(p_id uuid, p_topic text, p_text text, p_phone text, p_info text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  ag uuid := my_agency(); me uuid := auth.uid(); nm text;
  kind text := case when p_topic in ('Въпрос', 'Проблем', 'Предложение', 'Абонамент') then p_topic else 'Въпрос' end;
  txt text := trim(coalesce(p_text, '')); ph text := left(trim(coalesce(p_phone, '')), 60);
  inf text := left(trim(coalesce(p_info, '')), 160); rid uuid := coalesce(p_id, gen_random_uuid());
begin
  if me is null or ag is null then raise exception 'Нямате достъп. Влезте отново в програмата.'; end if;
  if txt = '' then raise exception 'Напишете съобщението си.'; end if;
  if length(txt) > 1500 then raise exception 'Съобщението е твърде дълго (най-много 1500 знака).'; end if;
  if length(regexp_replace(ph, '\D', '', 'g')) < 6 then raise exception 'Попълнете телефон за връзка.'; end if;

  perform pg_advisory_xact_lock(hashtextextended('help_request:' || ag::text, 0));   -- лимитът не се заобикаля с едновременни заявки
  if exists (select 1 from help_requests where id = rid and user_id = me) then return; end if;   -- повторно натискане: вече е прието
  if (select count(*) from help_requests where user_id = me and created_at > now() - interval '1 hour') >= 5
     or (select count(*) from help_requests where agency_id = ag and created_at > now() - interval '1 day') >= 20 then
    raise exception 'Изпратихте много съобщения. Опитайте по-късно или се обадете на +359 893 008 182.';
  end if;

  select coalesce((select name from profiles where id = me), (select name from platform_admins where id = me), '') into nm;
  insert into help_requests(id, agency_id, user_id, user_name, topic, body, phone, info)
  values (rid, ag, me, nm, kind, txt, ph, inf);

  perform _tg_send(E'🆘 Запитване: ' || kind || E'\n\n' || _tg_agency(ag)
    || E'\nОт: ' || coalesce(nullif(nm, ''), 'без име') || ' · ' || ph
    || E'\n\n' || txt || case when inf <> '' then E'\n\n' || inf else '' end);
end $$;
revoke all on function public.help_request(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.help_request(uuid, text, text, text, text) to authenticated;

commit;
notify pgrst, 'reload schema';

-- ---------- преглед на запитванията (само чете) ----------
-- select h.created_at, a.name, h.user_name, h.phone, h.topic, h.body
--   from help_requests h join agencies a on a.id = h.agency_id order by h.created_at desc limit 50;

-- ---------- ВРЪЩАНЕ (изтрива и записаните запитвания) ----------
-- begin;
-- drop function if exists public.help_request(uuid, text, text, text, text);
-- drop table if exists public.help_requests;
-- commit;
