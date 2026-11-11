-- LOTO EQUIPO · quitar el permiso público de rls_auto_enable (pedido por Chio el 11/11/2026)
-- ✅ APLICADO el 11/11/2026 como migración «quitar_permiso_publico_rls_auto_enable».
-- Nadie de fuera necesita ejecutar esta función. La lanza la propia base de datos cada vez que se crea
-- una tabla, para dejarla cerrada (RLS). Comprobado: sin el permiso público, una tabla nueva sigue
-- naciendo con RLS activo.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
