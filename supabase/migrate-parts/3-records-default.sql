
-- agency_id на новите редове се попълва сам от входа
alter table public.records alter column agency_id set default public.my_agency();

