-- ============================================================
-- Миграция 11: самостоятелна регистрация с 14-дневен пробен достъп
-- Пуска се след миграции 1–10. Само добавя — не трие данни.
-- Публична функция self_signup (за anon), със защита от злоупотреба.
-- ============================================================
set search_path = public;

-- дневник на самостоятелните регистрации (за ограничаване на злоупотреба)
create table if not exists public.signup_log(
  id         bigserial primary key,
  code       text,
  created_at timestamptz not null default now()
);
alter table public.signup_log enable row level security;
-- без политики → достъпна само през security-definer функции (не за anon/authenticated директно)
create index if not exists signup_log_time on public.signup_log(created_at);

-- телефон за поддръжка и пробен период по подразбиране
update public.platform_settings
   set support_phone = coalesce(nullif(trim(support_phone), ''), '+359 893 008 182'),
       trial_days    = 14,
       warn_days     = coalesce(warn_days, 3)
 where id = 1;

-- ---------- самостоятелна регистрация ----------
-- Създава нова агенция с 14-дневен достъп и неин администратор.
-- Викаема от anon (нерегистриран посетител от рекламната страница).
create or replace function public.self_signup(
  p_agency_name text,
  p_code        text,
  p_admin_name  text,
  p_admin_username text,
  p_admin_password text,
  p_phone       text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  ag uuid;
  cd text := lower(trim(p_code));
  nm text := trim(p_agency_name);
  un text := lower(trim(p_admin_username));
begin
  -- защита от злоупотреба: максимум 15 нови регистрации на час (глобално)
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
  if length(coalesce(p_admin_password, '')) < 6 then
    raise exception 'Паролата трябва да е поне 6 знака.';
  end if;
  if exists (select 1 from agencies where code = cd) then
    raise exception 'Вече има агенция с този код. Изберете друг.';
  end if;

  insert into agencies (code, name, access_until)
    values (cd, nm, now() + interval '14 days')
    returning id into ag;

  perform _create_user(ag, un, p_admin_name, p_admin_password, 'admin', '{}'::jsonb);

  insert into records (agency_id, store, key, value) values
    (ag, 'meta', 'settings', jsonb_build_object('key','settings','value', jsonb_build_object(
       'agency', upper(nm), 'short', nm, 'addr', '', 'gsm', coalesce(trim(p_phone), ''),
       'city', '', 'logo', '', 'logoMode', 'none'))),
    (ag, 'meta', 'initialized', jsonb_build_object('key','initialized','value', true));

  insert into signup_log(code) values (cd);
  perform _plog(ag, 'Самостоятелна регистрация — пробен период 14 дни', now() + interval '14 days');

  return jsonb_build_object('code', cd, 'username', un, 'trial_days', 14);
end $$;

revoke execute on function public.self_signup(text, text, text, text, text, text) from public;
grant  execute on function public.self_signup(text, text, text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';
