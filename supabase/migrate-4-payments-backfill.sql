-- =====================================================================
-- МИГРАЦИЯ 4 — пренасяне на старите плащания в история (ПО ИЗБОР)
-- СТАТУС: за преглед. НЕ е изпълнявана никъде. Пуска се след миграция 3 (не зависи от нея).
-- Приложението работи и БЕЗ тази миграция: заявки без история се смятат постарому
-- (аванс / „платена изцяло“) и се превръщат в история едва при първото ново плащане.
--
-- Как се третират старите данни:
--   А) аванс > 0 и НЕ е отбелязана „платена изцяло“  → ЯСНО:
--      записва се 1 плащане = авансът (дата = датата на аванса, иначе датата на заявката;
--      начин „неизвестен“; бележка „пренесено…“; legacy:true). Остатъкът НЕ се променя
--      (общо − аванс, както и досега).
--   Б) отбелязана „платена изцяло“                    → НЕЯСНО (не знаем кога и колко е платено
--      извън аванса; общата сума се смята от редовете, отстъпката и таксите в приложението):
--      НЕ се пипа. Приложението я показва като платена, а при първото ново плащане я
--      пренася само (с изчислена сума и ясна бележка „изчислена“).
--   В) без аванс и без „платена“                      → няма какво да се пренася.
--   Полетата advance / paid / paidDate остават непроменени във всички случаи.
-- Връщане: в края на файла (от резервната таблица).
-- =====================================================================

-- ---------- 1) ПРЕГЛЕД (само чете) ----------
select a.code as agency, r.key, r.value->>'number' as number,
       r.value->>'advance' as advance, r.value->>'advanceDate' as advance_date, r.value->>'paid' as paid,
       case when coalesce(r.value->>'paid','false') = 'true' then 'Б: неясно — остава постарому'
            when coalesce(nullif(r.value->>'advance','')::numeric, 0) > 0 then 'А: 1 плащане (аванс)'
            else 'В: няма какво' end as treatment
from public.records r join public.agencies a on a.id = r.agency_id
where r.store = 'requests' and not (r.value ? 'payments')
order by a.code, r.key;

-- ---------- 2) ИЗПЪЛНЕНИЕ (само случай А) ----------
begin;
create table if not exists public.payments_backfill_backup (
  agency_id uuid not null, key text not null, value jsonb not null, saved_at timestamptz not null default now(),
  primary key (agency_id, key));
alter table public.payments_backfill_backup enable row level security;   -- без правила: никой отвън
revoke all on public.payments_backfill_backup from anon, authenticated;

insert into public.payments_backfill_backup (agency_id, key, value)
  select agency_id, key, value from public.records
  where store = 'requests' and not (value ? 'payments')
    and coalesce(value->>'paid','false') <> 'true'
    and coalesce(nullif(value->>'advance','')::numeric, 0) > 0
on conflict (agency_id, key) do nothing;

update public.records r
set value = r.value || jsonb_build_object('payments', jsonb_build_array(jsonb_build_object(
      'id', 'legacy-' || r.key, 'type', 'payment',
      'date', coalesce(nullif(r.value->>'advanceDate',''), r.value->>'reqDate', ''),
      'amount', (r.value->>'advance')::numeric, 'method', 'неизвестен',
      'note', 'пренесено от полето „Аванс“ (миграция 4)', 'legacy', true)))
where r.store = 'requests' and not (r.value ? 'payments')
  and coalesce(r.value->>'paid','false') <> 'true'
  and coalesce(nullif(r.value->>'advance','')::numeric, 0) > 0;
commit;

-- ---------- 3) ВРЪЩАНЕ (ако е нужно) ----------
-- Връща само заявките, които след миграцията НЕ са получили нови плащания
-- (историята им е все още само пренесеният ред). Другите се показват за ръчен преглед.
-- begin;
-- update public.records r set value = b.value
-- from public.payments_backfill_backup b
-- where r.agency_id = b.agency_id and r.store = 'requests' and r.key = b.key
--   and jsonb_array_length(r.value->'payments') = 1 and (r.value->'payments'->0->>'legacy') = 'true';
-- select b.key as променена_след_миграцията from public.payments_backfill_backup b
--   join public.records r on r.agency_id = b.agency_id and r.store = 'requests' and r.key = b.key
--   where jsonb_array_length(r.value->'payments') <> 1;
-- commit;
-- drop table public.payments_backfill_backup;   -- след като сте сигурни
