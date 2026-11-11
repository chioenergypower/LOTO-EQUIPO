-- LOTO EQUIPO · refuerzo de seguridad (revisión 11/11/2026)
-- ✅ APLICADO el 11/11/2026 en el proyecto dotjulmjnnrcijmiauis. Se aplica después de 03_mantenimiento_agenda.sql.
-- No cambia nada de lo que ven o hacen las webs: solo quita permisos que sobran.

-- 1) Las tablas tenían todavía TRUNCATE / REFERENCES / TRIGGER para el público (anon) y para usuarios
--    con sesión (authenticated). Hoy no se pueden usar desde la API, pero TRUNCATE se salta el RLS:
--    se quitan para que no dependa de eso.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- 2) Lo que se cree a partir de ahora nace cerrado: cada tabla o función nueva hay que abrirla a propósito.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- 3) Las funciones de las webs solo las llama el público con su enlace personal (anon).
--    Se quita el permiso genérico (PUBLIC) y el de «authenticated», que no se usa.
revoke execute on function
  mi_dia(text), jornada(text, text), tarea(text, bigint, text), peticion(text, bigint, text, boolean),
  reposicion(text, text, text, numeric, boolean), reposicion_llevada(text, bigint), incidencia(text, text, text, boolean),
  falta_material(text, text), mensaje(text, text, text), mis_partes(text), mi_agenda(text),
  parte_actualizar(text, bigint, text, numeric, text, numeric, text)
  from public, authenticated;
grant execute on function
  mi_dia(text), jornada(text, text), tarea(text, bigint, text), peticion(text, bigint, text, boolean),
  reposicion(text, text, text, numeric, boolean), reposicion_llevada(text, bigint), incidencia(text, text, text, boolean),
  falta_material(text, text), mensaje(text, text, text), mis_partes(text), mi_agenda(text),
  parte_actualizar(text, bigint, text, numeric, text, numeric, text)
  to anon;

-- 4) Funciones internas: nadie de fuera las llama directamente.
alter function _hoy() set search_path = public;
revoke execute on function _hoy() from public, anon, authenticated;
revoke execute on function _quien(text) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- Comprobación (debe devolver 0 filas):
--   select table_name, grantee, privilege_type from information_schema.role_table_grants
--   where table_schema = 'public' and grantee in ('anon', 'authenticated');
