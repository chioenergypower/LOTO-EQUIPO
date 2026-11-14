-- 07 · Mantenimiento: el reloj nunca cobra de más (R-14.14, Chio 14/11/2026 23:05)
-- Se cobra el tiempo exacto. Si el reloj ha contado mucho (más de 1 hora, o más del doble de lo estimado),
-- al TERMINAR se le pregunta a José cuánto ha trabajado de verdad y Recepción recibe un aviso.
-- Recepción (Claude) estima el tiempo de cada parte (ej. bombilla = 15 min) en minutos_estimados.

alter table partes
  add column if not exists minutos_estimados numeric,  -- lo que estima Recepción para ese trabajo
  add column if not exists minutos_reloj numeric;      -- lo que contó el reloj antes de corregirlo

-- José dice cuánto trabajó de verdad (solo puede BAJAR el tiempo del reloj, nunca subirlo).
create or replace function parte_tiempo_real(p_k text, p_id bigint, p_minutos numeric) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo; antes numeric; apt text;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  perform _parte_parar(p_id);
  select minutos, apartamento into antes, apt from partes where id = p_id and estado <> 'terminado';
  if not found then raise exception 'parte_no_existe'; end if;
  if p_minutos is null or p_minutos <= 0 or p_minutos > antes then raise exception 'minutos_no_validos'; end if;
  update partes set minutos_reloj = antes, minutos = p_minutos,
         notas = notas || jsonb_build_object('ts', now(), 'por', yo.nombre,
                 'texto', 'Tiempo real: ' || round(p_minutos) || ' min (el reloj contó ' || round(antes) || ' min)')
   where id = p_id;
  perform _parte_recalc(p_id);
  insert into mensajes(de, para, apartamento, texto)
  values (yo.id, 'recepcion', apt,
          '⏱️ ' || yo.nombre || ' corrige el tiempo en ' || apt || ': ' || round(p_minutos) || ' min (el reloj contó '
          || round(antes) || ' min). Revisar.');
end $$;

revoke all on function parte_tiempo_real(text, bigint, numeric) from public;
grant execute on function parte_tiempo_real(text, bigint, numeric) to anon, authenticated;

-- mis_partes: añade 'estimado' (minutos estimados por Recepción) y 'reloj' (lo que contó el reloj).
create or replace function mis_partes(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare yo equipo; h date := _hoy(); ver_codigos boolean;
begin
  yo := _quien(p_k);
  ver_codigos := yo.rol = 'mantenimiento' or yo.lider;
  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol),
    'hoy', h, 'ahora', now(),
    'tarifa', (select (valor#>>'{}')::numeric from ajustes where clave = 'tarifa_mantenimiento'),
    'apartamentos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta,
        'cajetin', case when ver_codigos then a.cajetin end,
        'codigo',  case when ver_codigos then a.codigo end,
        'parking', a.parking,
        'acceso',  case when ver_codigos then a.acceso end,
        'acceso_edificio', case when ver_codigos then e.acceso end
      ) order by a.edificio, a.id), '[]')
      from apartamentos a left join edificios e on e.id = a.edificio),
    'estancias', (select coalesce(jsonb_agg(jsonb_build_object(
        'apartamento', s.apartamento, 'llegada', s.llegada, 'salida', s.salida,
        'hora_entrada', coalesce(s.hora_entrada,
           (select t.hora_entrada from tareas_limpieza t
             where t.apartamento = s.apartamento and t.fecha = s.llegada and t.hora_entrada is not null limit 1))
      ) order by s.apartamento, s.llegada), '[]')
      from estancias s where s.salida >= h - 1 and s.llegada <= h + 8),
    'bloqueos', (select coalesce(jsonb_agg(jsonb_build_object(
        'apartamento', b.apartamento, 'desde', b.desde, 'hasta', b.hasta, 'motivo', b.motivo)), '[]')
      from bloqueos b where b.hasta >= h and b.desde <= h + 8),
    'partes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'creado', p.creado, 'apartamento', p.apartamento, 'descripcion', p.descripcion,
        'urgente', p.urgente, 'reporta', p.reporta, 'estado', p.estado,
        'asignado', (select q.nombre from equipo q where q.id = p.asignado), 'mio', p.asignado = yo.id,
        'horas', p.horas, 'materiales', p.materiales, 'coste_materiales', p.coste_materiales,
        'inicio', p.inicio, 'minutos', p.minutos, 'tarifa', p.tarifa,
        'estimado', p.minutos_estimados, 'reloj', p.minutos_reloj,
        'mano_obra', p.coste_mano_obra, 'total', p.total, 'liquidado', p.liquidado,
        'mats', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'concepto', m.concepto, 'precio', m.precio) order by m.id), '[]')
                   from partes_materiales m where m.parte_id = p.id),
        'notas', p.notas, 'cerrado', p.cerrado,
        'nfotos', (select count(*) from partes_fotos f where f.parte_id = p.id),
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta
      ) order by p.urgente desc, p.creado)
      from partes p join apartamentos a on a.id = p.apartamento
      where p.estado <> 'terminado' or p.cerrado > now() - interval '31 days'), '[]'));
end $function$;

-- Vista para Recepción: relojes en marcha demasiado tiempo y trabajos muy por encima de lo estimado.
create or replace view privado.mantenimiento_revisar_tiempo as
select p.id, p.apartamento, p.descripcion, p.estado, p.inicio,
       round(p.minutos + coalesce(extract(epoch from now() - p.inicio) / 60, 0)) as minutos_ahora,
       p.minutos_estimados, p.minutos_reloj,
       case when p.inicio is not null and now() - p.inicio > interval '60 minutes' then 'reloj_en_marcha_mas_de_1h'
            when p.minutos_estimados is not null and p.minutos > 2 * p.minutos_estimados then 'mas_del_doble_de_lo_estimado'
       end as motivo
  from partes p
 where (p.inicio is not null and now() - p.inicio > interval '60 minutes')
    or (p.minutos_estimados is not null and p.minutos > 2 * p.minutos_estimados and p.cerrado > now() - interval '7 days');
