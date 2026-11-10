"""Builds supabase/migrate-to-agencies.sql from migrate-parts/ + the function/rule blocks of setup.sql.
Run:  python3 supabase/build-migrate.py"""
from pathlib import Path

D = Path(__file__).parent
setup = (D / "setup.sql").read_text(encoding="utf-8")

def section(start, end):
    i, j = setup.index(start), setup.index(end)
    assert i < j, (start, end)
    return setup[i:j]

who = section("-- ---------- кой е влязъл", "-- agency_id се попълва сам")          # my_agency, is_member, is_admin, is_platform
rules = section("-- ---------- правила за достъп", "-- ---------- потребителско име")  # RLS policies
funcs = section("-- ---------- потребителско име", "-- ---------- Word файловете")    # all other functions + execute grants

P = D / "migrate-parts"
out = (P / "1-start.sql").read_text(encoding="utf-8") + who + funcs + \
      (P / "3-records-default.sql").read_text(encoding="utf-8") + rules + \
      (P / "5-finish.sql").read_text(encoding="utf-8")
(D / "migrate-to-agencies.sql").write_text(out, encoding="utf-8")
print("wrote migrate-to-agencies.sql,", out.count("\n"), "lines")
