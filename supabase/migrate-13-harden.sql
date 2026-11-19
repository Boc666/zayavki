-- ============================================================
-- Миграция 13: заключване на search_path на двете помощни функции
-- (защитен одит — lint 0011 function_search_path_mutable).
-- Ползват само вградени команди → фиксираме празен search_path.
-- Нищо не се трие, поведението не се променя.
-- ============================================================
alter function public.username_email(text, text) set search_path = '';
alter function public.platform_email(text)        set search_path = '';
