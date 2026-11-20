-- ============================================================
-- Миграция 18: имейл на администратора — потвърждение при регистрация и смяна на паролата по имейл
-- Само добавя колони/таблици и подменя функции. Не трие данни.
--
--  • Самостоятелна регистрация: администраторът дава имейл; входът е възможен едва след
--    натискане на линка в писмото (profiles.must_confirm).
--  • „Забравена парола“ на администратор на агенция: линк по имейл (важи 1 час).
--  • Кодът за възстановяване за АГЕНЦИИТЕ спира да работи (собственикът на платформата си го пази).
--  • Сегашните администратори добавят и потвърждават имейл от „Потребители“.
--
-- Писмата се пращат през Resend (pg_net, асинхронно). Ключ във Vault: resend_api_key (въвежда собственикът).
-- Подател: Memoriox <noreply@memoriox.eu> — домейнът трябва да е потвърден в Resend.
-- ============================================================
set search_path = public;

alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists email_confirmed_at timestamptz;
alter table public.profiles add column if not exists must_confirm boolean not null default false;
create index if not exists profiles_email_idx on public.profiles (lower(email));

create table if not exists public.email_tokens(
  id          bigserial primary key,
  kind        text not null check (kind in ('confirm','reset')),
  user_id     uuid not null,
  email       text not null,
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.email_tokens enable row level security;   -- без политики: само през функциите
revoke all on public.email_tokens from anon, authenticated;
create index if not exists email_tokens_user_idx on public.email_tokens (user_id, kind);

-- ---------- помощни ----------
create or replace function public._email_ok(p text) returns boolean
language sql immutable as $$
  select coalesce(length(p) <= 254 and p ~ '^[^@\s<>"'',;]+@[^@\s<>"'',;]+\.[a-zA-Z]{2,}$', false) $$;

create or replace function public._mask_email(p text) returns text
language sql immutable as $$
  select case when p is null or position('@' in p) = 0 then coalesce(p, '')
    else left(split_part(p, '@', 1), 2) || '•••@' || split_part(p, '@', 2) end $$;

create or replace function public._h(p text) returns text
language sql immutable as $$ select replace(replace(replace(replace(coalesce(p,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;') $$;

-- нов еднократен линк; старите неизползвани от същия вид се анулират. Връща самия токен (в базата се пази само отпечатък).
create or replace function public._email_token(p_kind text, p_user uuid, p_email text, p_ttl interval) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(32), 'hex');
begin
  update email_tokens set used_at = now() where user_id = p_user and kind = p_kind and used_at is null;
  delete from email_tokens where created_at < now() - interval '30 days';
  insert into email_tokens(kind, user_id, email, token_hash, expires_at)
    values (p_kind, p_user, lower(trim(p_email)), encode(digest(t, 'sha256'), 'hex'), now() + p_ttl);
  return t;
end $$;

-- изпращане през Resend (асинхронно, след commit)
create or replace function public._send_email(p_to text, p_subject text, p_html text, p_text text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  select trim(decrypted_secret) into k from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if coalesce(k, '') = '' then raise exception 'Изпращането на имейли още не е настроено. Обадете се на +359 893 008 182.'; end if;
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    body    := jsonb_build_object('from', 'Memoriox <noreply@memoriox.eu>', 'to', jsonb_build_array(p_to),
                                  'subject', p_subject, 'html', p_html, 'text', p_text),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || k));
end $$;

create or replace function public._mail_html(p_title text, p_lead text, p_btn text, p_url text, p_foot text) returns text
language sql immutable as $$
  select '<!doctype html><html lang="bg"><body style="margin:0;background:#f4f1ec;font-family:Arial,Helvetica,sans-serif;color:#1c1a17">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:32px 12px"><tr><td align="center">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:14px;padding:32px">'
    || '<tr><td style="font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#8a6a3b;font-weight:bold">Memoriox</td></tr>'
    || '<tr><td style="padding-top:14px;font-size:22px;font-weight:bold">' || p_title || '</td></tr>'
    || '<tr><td style="padding-top:12px;font-size:15px;line-height:1.55;color:#3b3833">' || p_lead || '</td></tr>'
    || '<tr><td style="padding:26px 0"><a href="' || p_url || '" style="display:inline-block;background:#1c1a17;color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;padding:13px 22px;border-radius:9px">' || p_btn || '</a></td></tr>'
    || '<tr><td style="font-size:12.5px;line-height:1.5;color:#77726b">Ако бутонът не работи, копирайте този адрес в браузъра:<br><span style="word-break:break-all">' || p_url || '</span></td></tr>'
    || '<tr><td style="padding-top:18px;font-size:12.5px;line-height:1.5;color:#77726b">' || p_foot || '</td></tr>'
    || '</table></td></tr></table></body></html>' $$;

create or replace function public._send_confirm(p_user uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare t text; u text; a text;
begin
  select p.name, ag.name into u, a from profiles p join agencies ag on ag.id = p.agency_id where p.id = p_user;
  t := _email_token('confirm', p_user, p_email, interval '3 days');
  perform _send_email(p_email, 'Потвърдете имейла си — Memoriox',
    _mail_html('Потвърдете имейла си',
      'Здравейте, ' || _h(u) || '!<br>Натиснете бутона, за да потвърдите имейла на администратора на „' || _h(a) || '“ в Memoriox.',
      'Потвърди имейла', 'https://app.memoriox.eu/?confirm=' || t,
      'Линкът важи 3 дни. Ако не сте се регистрирали в Memoriox, просто пренебрегнете това писмо.'),
    'Потвърдете имейла си в Memoriox: https://app.memoriox.eu/?confirm=' || t || E'\nЛинкът важи 3 дни.');
end $$;

-- ---------- достъпът: непотвърден администратор (самостоятелна регистрация) не вижда данни ----------
create or replace function public.my_agency() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.agency_id from profiles p join agencies a on a.id = p.agency_id
      where p.id = auth.uid() and p.active and not p.must_confirm and a.active and (a.access_until is null or a.access_until > now())),
    (select acting_agency from platform_admins where id = auth.uid()))
$$;

create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('kind','platform','name',pa.name,'username',pa.username,
              'acting', case when a.id is null then null else jsonb_build_object('agency_id',a.id,'code',a.code,'agency_name',a.name) end)
       from platform_admins pa left join agencies a on a.id = pa.acting_agency where pa.id = auth.uid()),
    (select jsonb_build_object('kind','agency','agency_id',a.id,'code',a.code,'agency_name',a.name,
                               'agency_active',a.active,'active',p.active,'access_until',a.access_until,
                               'expired', a.access_until is not null and a.access_until <= now(),
                               'support_phone',s.support_phone,'warn_days',s.warn_days,
                               'role',p.role,'must_confirm',p.must_confirm,
                               'email',_mask_email(p.email),'email_confirmed',p.email_confirmed_at is not null)
       from profiles p join agencies a on a.id = p.agency_id cross join platform_settings s where p.id = auth.uid()))
$$;

-- ---------- самостоятелна регистрация: + имейл, вход след потвърждение ----------
drop function if exists public.self_signup(text, text, text, text, text, text);
create or replace function public.self_signup(
  p_agency_name text, p_code text, p_admin_name text, p_admin_username text,
  p_admin_password text, p_phone text default null, p_email text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  ag uuid; uid uuid;
  cd text := lower(trim(p_code));
  nm text := trim(p_agency_name);
  un text := lower(trim(p_admin_username));
  em text := lower(trim(coalesce(p_email, '')));
begin
  if (select count(*) from signup_log where created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Твърде много регистрации в момента. Опитайте след малко или се обадете на +359 893 008 182.';
  end if;
  if cd !~ '^[a-z0-9][a-z0-9-]{1,29}$' then
    raise exception 'Кодът е 2–30 знака: малки латински букви, цифри и тире (напр. mir).';
  end if;
  if nm = '' then raise exception 'Попълнете името на агенцията.'; end if;
  if coalesce(trim(p_admin_name), '') = '' or un = '' then
    raise exception 'Попълнете вашето име и потребителско име.';
  end if;
  if not _email_ok(em) then raise exception 'Попълнете валиден имейл — на него ще получите линк за потвърждение.'; end if;
  if exists (select 1 from profiles where lower(email) = em and email_confirmed_at is not null) then
    raise exception 'С този имейл вече има регистрирана агенция. Влезте в нея или се обадете на +359 893 008 182.';
  end if;
  if length(coalesce(p_admin_password, '')) < 6 then
    raise exception 'Паролата трябва да е поне 6 знака.';
  end if;
  if exists (select 1 from agencies where code = cd) then
    raise exception 'Вече има агенция с този код. Изберете друг.';
  end if;

  insert into agencies (code, name, access_until, contact_email)
    values (cd, nm, now() + interval '14 days', em)
    returning id into ag;

  uid := _create_user(ag, un, p_admin_name, p_admin_password, 'admin', '{}'::jsonb);
  update profiles set email = em, must_confirm = true where id = uid;

  insert into records (agency_id, store, key, value) values
    (ag, 'meta', 'settings', jsonb_build_object('key','settings','value', jsonb_build_object(
       'agency', upper(nm), 'short', nm, 'addr', '', 'gsm', coalesce(trim(p_phone), ''),
       'city', '', 'logo', '', 'logoMode', 'none'))),
    (ag, 'meta', 'initialized', jsonb_build_object('key','initialized','value', true));

  insert into signup_log(code) values (cd);
  perform _plog(ag, 'Самостоятелна регистрация — пробен период 14 дни', now() + interval '14 days');
  perform _send_confirm(uid, em);

  return jsonb_build_object('code', cd, 'username', un, 'trial_days', 14, 'email', _mask_email(em), 'must_confirm', true);
end $$;
revoke execute on function public.self_signup(text, text, text, text, text, text, text) from public;
grant  execute on function public.self_signup(text, text, text, text, text, text, text) to anon, authenticated;

-- ---------- потвърждаване на имейла (линкът от писмото) ----------
create or replace function public.email_confirm(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t email_tokens; p profiles; cd text; was boolean;
begin
  select * into t from email_tokens where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and kind = 'confirm';
  if t.id is null then return jsonb_build_object('ok', false, 'msg', 'Линкът е невалиден. Поискайте нов от програмата.'); end if;
  select * into p from profiles where id = t.user_id;
  select code into cd from agencies where id = p.agency_id;
  if t.used_at is not null then
    if p.email_confirmed_at is not null and lower(p.email) = t.email then
      return jsonb_build_object('ok', true, 'already', true, 'code', cd, 'username', p.username);
    end if;
    return jsonb_build_object('ok', false, 'msg', 'Този линк вече е използван или е заменен с по-нов. Поискайте нов от програмата.');
  end if;
  if t.expires_at < now() then return jsonb_build_object('ok', false, 'msg', 'Линкът е изтекъл. Влезте и поискайте нов.'); end if;
  was := p.must_confirm;
  update profiles set email = t.email, email_confirmed_at = now(), must_confirm = false where id = t.user_id;
  update email_tokens set used_at = now() where id = t.id;
  if was then
    begin perform _tg_send('✅ Имейлът е потвърден' || E'\n\n' || _tg_agency(p.agency_id)); exception when others then null; end;
  end if;
  return jsonb_build_object('ok', true, 'code', cd, 'username', p.username);
end $$;
revoke all on function public.email_confirm(text) from public;
grant execute on function public.email_confirm(text) to anon, authenticated;

-- ---------- нов линк за потвърждение / смяна на имейла (влязъл администратор) ----------
create or replace function public.request_email_confirm(p_email text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; em text; k text;
begin
  select * into p from profiles where id = auth.uid();
  if p.id is null or not p.active then raise exception 'Нямате достъп.'; end if;
  if p.role <> 'admin' then raise exception 'Имейл за възстановяване имат само администраторите.'; end if;
  em := lower(trim(coalesce(nullif(trim(p_email), ''), p.email, '')));
  if not _email_ok(em) then raise exception 'Въведете валиден имейл.'; end if;
  if exists (select 1 from profiles where lower(email) = em and email_confirmed_at is not null and id <> p.id and agency_id <> p.agency_id) then
    raise exception 'Този имейл вече се използва от друга агенция.';
  end if;
  k := 'mail:' || p.id::text;
  delete from auth_attempts where at < now() - interval '1 day';
  if (select count(*) from auth_attempts where key = k and at > now() - interval '10 minutes') >= 3
     or (select count(*) from auth_attempts where key = k and at > now() - interval '1 day') >= 10 then
    raise exception 'Изпратихме вече няколко писма. Проверете пощата (и папка „Спам“) или опитайте след 10 минути.';
  end if;
  insert into auth_attempts(key) values (k);
  if p.must_confirm then update profiles set email = em where id = p.id; end if;
  perform _send_confirm(p.id, em);
  return jsonb_build_object('ok', true, 'email', _mask_email(em));
end $$;
revoke all on function public.request_email_confirm(text) from public, anon;
grant execute on function public.request_email_confirm(text) to authenticated;

-- ---------- забравена парола: линк по имейл ----------
create or replace function public.password_reset_request(p_agency text, p_username text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ac text := lower(trim(coalesce(p_agency, ''))); un text := lower(trim(coalesce(p_username, '')));
        k1 text; k2 text; p profiles; a agencies; t text;
begin
  perform pg_sleep(0.5);
  k1 := 'pwr:' || ac || '/' || un; k2 := 'pwr:' || ac;
  delete from auth_attempts where at < now() - interval '1 day';
  if (select count(*) from auth_attempts where key = k1 and at > now() - interval '15 minutes') >= 3
     or (select count(*) from auth_attempts where key = k2 and at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'msg', 'Твърде много опити. Опитайте отново след 15 минути.');
  end if;
  insert into auth_attempts(key) values (k1), (k2);
  select * into a from agencies where code = ac and active;
  if a.id is not null then
    select * into p from profiles where agency_id = a.id and username = un and role = 'admin' and active
      and email_confirmed_at is not null and coalesce(email, '') <> '';
  end if;
  if p.id is not null then
    t := _email_token('reset', p.id, p.email, interval '1 hour');
    perform _send_email(p.email, 'Смяна на паролата — Memoriox',
      _mail_html('Смяна на паролата',
        'Здравейте, ' || _h(p.name) || '!<br>Поискана е смяна на паролата на администратор <b>' || _h(p.username) || '</b> в „' || _h(a.name) || '“ (код ' || _h(a.code) || ').',
        'Задай нова парола', 'https://app.memoriox.eu/?reset=' || t,
        'Линкът важи 1 час и може да се използва веднъж. Ако не сте поискали смяна, пренебрегнете писмото — паролата ви не е променена.'),
      'Смяна на паролата в Memoriox: https://app.memoriox.eu/?reset=' || t || E'\nЛинкът важи 1 час.');
  end if;
  -- един и същ отговор, за да не се издава кои потребители имат имейл
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.password_reset_request(text, text) from public;
grant execute on function public.password_reset_request(text, text) to anon, authenticated;

create or replace function public.password_reset_confirm(p_token text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, auth, extensions as $$
declare t email_tokens; p profiles; cd text;
begin
  select * into t from email_tokens where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and kind = 'reset';
  if t.id is null or t.used_at is not null then
    return jsonb_build_object('ok', false, 'msg', 'Линкът е невалиден или вече е използван. Поискайте нов от „Забравена парола“.');
  end if;
  if t.expires_at < now() then return jsonb_build_object('ok', false, 'msg', 'Линкът е изтекъл (важи 1 час). Поискайте нов от „Забравена парола“.'); end if;
  if length(coalesce(p_password, '')) < 6 then return jsonb_build_object('ok', false, 'msg', 'Паролата трябва да е поне 6 знака.'); end if;
  select * into p from profiles where id = t.user_id and active;
  if p.id is null then return jsonb_build_object('ok', false, 'msg', 'Този потребител е спрян. Обърнете се към поддръжката.'); end if;
  select code into cd from agencies where id = p.agency_id;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p.id;
  update email_tokens set used_at = now() where id = t.id;
  perform public._revoke_sessions(p.id);
  return jsonb_build_object('ok', true, 'code', cd, 'username', p.username);
end $$;
revoke all on function public.password_reset_confirm(text, text) from public;
grant execute on function public.password_reset_confirm(text, text) to anon, authenticated;

-- ---------- кодът за възстановяване спира за агенциите (собственикът на платформата си го пази) ----------
do $$
declare d text;
begin
  select pg_get_functiondef('public.recover_admin(text,text,text,text)'::regprocedure) into d;
  if position('Възстановяването с код е спряно' in d) = 0 then
    d := replace(d, 'begin
  perform pg_sleep(1);', 'begin
  perform pg_sleep(1);
  if ac <> '''' then
    return jsonb_build_object(''ok'', false, ''msg'', ''Възстановяването с код е спряно. Използвайте „Забравена парола“ — ще получите линк на имейла на администратора.'');
  end if;');
    if position('Възстановяването с код е спряно' in d) = 0 then raise exception 'recover_admin: не намерих мястото за промяна'; end if;
    execute d;
  end if;
end $$;

-- ---------- Telegram: имейлът в известието за нов пробен период ----------
create or replace function public._tg_on_signup() returns trigger
language plpgsql security definer set search_path = public as $$
declare a record; adm record; ph text; n bigint;
begin
  select id, name, code, access_until into a from agencies where code = new.code;
  if a.id is null then return new; end if;
  select p.name, p.username, p.email, p.must_confirm into adm from profiles p where p.agency_id = a.id and p.role = 'admin' limit 1;
  select nullif(trim(value->'value'->>'gsm'), '') into ph from records
   where agency_id = a.id and store = 'meta' and key = 'settings';
  select count(*) into n from signup_log;
  perform _tg_send(format(
    E'🆕 Нов пробен период в Memoriox\n\nАгенция: %s\nКод: %s\nАдминистратор: %s (%s)\nИмейл: %s\nТелефон: %s\nПробен до: %s\n%s\nСамостоятелни регистрации общо: %s',
    a.name, a.code, coalesce(adm.name, '—'), coalesce(adm.username, '—'), coalesce(adm.email, '—'), coalesce(ph, 'не е въведен'),
    to_char(a.access_until at time zone 'Europe/Sofia', 'DD.MM.YYYY'),
    case when adm.must_confirm then E'⏳ Чака потвърждение на имейла\n' else '' end, n));
  return new;
exception when others then
  raise warning 'telegram signup: %', sqlerrm;
  return new;
end $$;

revoke all on function public._h(text), public._email_ok(text), public._mask_email(text), public._email_token(text, uuid, text, interval),
  public._send_email(text, text, text, text), public._mail_html(text, text, text, text, text), public._send_confirm(uuid, text)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
