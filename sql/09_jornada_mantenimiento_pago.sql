-- 09 · Jornada de mantenimiento y pago al obrero (Chio 15/11/2026 16:28)
-- · José cobra 15 €/h (ajuste 'pago_mantenimiento'). Los 30 €/h de 'tarifa_mantenimiento' son
--   lo que se cobra al propietario y NO se enseñan en «Mis horas».
-- · José marca COMIENZO y FIN de jornada (reutiliza la tabla jornadas y la función jornada()).
--   El tiempo de la jornada que no está en ningún parte = «Taller» (preparar y guardar herramientas, moverse).

insert into ajustes values ('pago_mantenimiento', '15') on conflict (clave) do nothing;

create or replace function mi_jornada_mant(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; h date := _hoy();
begin
  yo := _quien(p_k);
  return jsonb_build_object(
    'hoy', h, 'ahora', now(),
    'pago', (select (valor#>>'{}')::numeric from ajustes where clave = 'pago_mantenimiento'),
    'jornada', (select jsonb_build_object('inicio', j.inicio, 'fin', j.fin)
                  from jornadas j where j.persona = yo.id and j.fecha = h),
    'mes', (select coalesce(jsonb_agg(jsonb_build_object('fecha', j.fecha, 'inicio', j.inicio, 'fin', j.fin) order by j.fecha), '[]')
              from jornadas j where j.persona = yo.id and date_trunc('month', j.fecha) = date_trunc('month', h)));
end $$;

revoke all on function mi_jornada_mant(text) from public;
grant execute on function mi_jornada_mant(text) to anon, authenticated;
