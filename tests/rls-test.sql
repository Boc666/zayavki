-- =====================================================================
-- ТЕСТ НА ПРАВАТА В БАЗАТА — само за ТЕСТОВИЯ проект (klcaiengszmdvpgkybxn)!
-- Създава 2 временни агенции и потребители с различни права, проверява кой какво може да чете и пише,
-- и накрая ОТМЕНЯ всичко (нищо не остава в базата). Резултатът е в съобщението на грешката „РЕЗУЛТАТ“:
--   ✔ — както се очаква; ✗ — проблем.
-- Пуска се след всяка миграция, която пипа правата: SQL Editor на тестовия проект → Run.
-- =====================================================================
create or replace function pg_temp.as_user(u uuid, q text) returns text language plpgsql as $f$
declare r text;
begin
  if u is null then perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon';
  else perform set_config('request.jwt.claims', json_build_object('sub',u,'role','authenticated')::text, true); execute 'set local role authenticated'; end if;
  begin
    if q ~* '^\s*select' then execute q into r; else execute q; r := 'OK'; end if;
    execute 'reset role'; return coalesce(r,'OK');
  exception when others then execute 'reset role'; return 'ERR: ' || sqlerrm; end;
end $f$;

do $$
declare
  a uuid; b uuid; adm uuid; ws uuid; rq uuid; none_ uuid; bad uuid; res text := ''; n int := 0; f int := 0; v text;
begin
  -- ---------- подготовка (временно — всичко се отменя накрая) ----------
  insert into agencies (code, name) values ('zz-test-a', 'ZZ Тест А') returning id into a;
  insert into agencies (code, name) values ('zz-test-b', 'ZZ Тест Б') returning id into b;
  adm   := public._create_user(a, 'zz-adm',  'ZZ Админ',   'zz-pass-123', 'admin', '{}');
  ws    := public._create_user(a, 'zz-ws',   'ZZ Листове', 'zz-pass-123', 'user',  '{"ws":"edit","dash":"view"}');
  rq    := public._create_user(a, 'zz-req',  'ZZ Заявки',  'zz-pass-123', 'user',  '{"req":"edit","dash":"view","clients":"view"}');
  none_ := public._create_user(a, 'zz-none', 'ZZ Нищо',    'zz-pass-123', 'user',  '{}');
  bad   := public._create_user(b, 'zz-b',    'ZZ Чужд',    'zz-pass-123', 'admin', '{}');
  insert into records (agency_id, store, key, value) values
    (a,'requests','r1','{"id":"r1","number":"1","decName":"Тест","ws":{"x":1},"inv":{}}'),
    (a,'clients','c1','{"id":"c1","name":"Клиент"}'),
    (a,'events','e1','{"id":"e1","title":"Събитие","date":"2026-12-01"}'),
    (a,'partners','p1','{"id":"p1","name":"Партньор"}'),
    (a,'audit','a1','{"id":"a1","ts":"2026-11-12T10:00:00Z","action":"тест"}'),
    (a,'meta','settings','{"key":"settings","value":{"nextNo":2}}'),
    (b,'requests','rb','{"id":"rb","number":"1","decName":"Чужда"}');

  -- помощник за редовете
  create temp table _r(i serial, name text, got text, want text) on commit drop;

  -- ---------- 1. четене ----------
  insert into _r(name,got,want) values
    ('администратор вижда всички видове данни', pg_temp.as_user(adm, $q$select string_agg(distinct store, ',' order by store) from public.records$q$), 'audit,clients,events,meta,partners,requests'),
    ('само „Работни листове“: заявки и настройки', pg_temp.as_user(ws, $q$select string_agg(distinct store, ',' order by store) from public.records$q$), 'meta,requests'),
    ('„Заявки“: без историята', pg_temp.as_user(rq, $q$select string_agg(distinct store, ',' order by store) from public.records$q$), 'clients,events,meta,partners,requests'),
    ('без права: само настройките', pg_temp.as_user(none_, $q$select string_agg(distinct store, ',' order by store) from public.records$q$), 'meta'),
    ('друга агенция не вижда нищо от А', pg_temp.as_user(bad, format($q$select count(*)::text from public.records where agency_id=%L$q$, a)), '0'),
    ('без вход: нищо', pg_temp.as_user(null, $q$select count(*)::text from public.records$q$), '0');

  -- ---------- 2. запис ----------
  insert into _r(name,got,want) values
    ('„Заявки: редактира“ променя заявка', pg_temp.as_user(rq, $q$update public.records set value = value || '{"notes":"x"}' where store='requests' and key='r1'$q$), 'OK'),
    ('„Работни листове“ НЕ променя основната част на заявката', pg_temp.as_user(ws, $q$update public.records set value = value || '{"notes":"y"}' where store='requests' and key='r1'$q$), 'ERR'),
    ('„Работни листове“ променя работния лист', pg_temp.as_user(ws, $q$update public.records set value = jsonb_set(value,'{ws,x}','2') where store='requests' and key='r1'$q$), 'OK'),
    ('„Заявки“ без „Фактури“ НЕ пипа фактурата', pg_temp.as_user(rq, $q$update public.records set value = jsonb_set(value,'{inv}','{"number":"5"}') where store='requests' and key='r1'$q$), 'ERR'),
    ('служител НЕ сменя настройките', pg_temp.as_user(rq, $q$update public.records set value = jsonb_set(value,'{value,city}','"X"') where store='meta' and key='settings'$q$), 'ERR'),
    ('историята не се променя (дори от администратор)', pg_temp.as_user(adm, $q$update public.records set value = value || '{"action":"подправено"}' where store='audit' and key='a1'$q$), 'OK0'),
    ('историята не се трие', pg_temp.as_user(adm, $q$delete from public.records where store='audit' and key='a1'$q$), 'OK0'),
    ('служител НЕ добавя партньор', pg_temp.as_user(rq, format($q$insert into public.records(agency_id,store,key,value) values (%L,'partners','p2','{"id":"p2"}')$q$, a)), 'ERR'),
    ('чужд НЕ пише в агенция А', pg_temp.as_user(bad, format($q$insert into public.records(agency_id,store,key,value) values (%L,'requests','zz','{"id":"zz"}')$q$, a)), 'ERR'),
    ('без право за изтриване на заявки — не изтрива', pg_temp.as_user(rq, $q$delete from public.records where store='requests' and key='r1'$q$), 'ERR');

  -- ---------- 3. номера и версии ----------
  insert into _r(name,got,want) values
    ('номер на заявка — с право', pg_temp.as_user(rq, $q$select public.take_number('request')::text$q$), '2'),
    ('следващият номер е различен', pg_temp.as_user(rq, $q$select public.take_number('request')::text$q$), '3'),
    ('номер на фактура — без право „Фактури“', pg_temp.as_user(rq, $q$select public.take_number('invoice')::text$q$), 'ERR'),
    ('повторен номер на заявка се отказва', pg_temp.as_user(rq, format($q$insert into public.records(agency_id,store,key,value) values (%L,'requests','r2','{"id":"r2","number":"1"}')$q$, a)), 'ERR'),
    ('запис със стара версия се спира', pg_temp.as_user(adm, $q$select public.put_atomic_v('[{"store":"meta","key":"settings","value":{"key":"settings","value":{}},"expected":999}]')::text$q$), 'ERR'),
    ('без вход: възстановяване с грешен код', pg_temp.as_user(null, $q$select (public.recover_admin('zz-test-a','zz-adm','грешен','x12345')->>'ok')$q$), 'false'),
    ('без вход: непознат линк', pg_temp.as_user(null, $q$select public.public_link_get('няма-такъв-линк')->>'error'$q$), 'missing');

  -- историята: „OK0“ = заявката мина, но не промени/изтри нищо (правилото не допуска ред от историята)
  update _r set got = case when got = 'OK' and exists (select 1 from records where store='audit' and key='a1' and agency_id=a and value->>'action' = 'тест') then 'OK0' else got end
    where name in ('историята не се трие','историята не се променя (дори от администратор)');

  for v in select (case when (want = 'ERR' and got like 'ERR%') or got = want then '✔ ' else '✗ ' end) || name ||
                  case when (want = 'ERR' and got like 'ERR%') or got = want then '' else '  [очаквано: ' || want || ', получено: ' || left(got,120) || ']' end
           from _r order by i loop
    n := n + 1; if left(v,1) = '✗' then f := f + 1; end if; res := res || E'\n' || v;
  end loop;
  raise exception 'РЕЗУЛТАТ: % от % проверки минаха%', n - f, n, res;   -- грешката отменя всички временни данни
end $$;
