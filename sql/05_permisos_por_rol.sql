-- LOTO EQUIPO · permisos por rol (revisión 11/11/2026)
-- ✅ APLICADO el 11/11/2026 en el proyecto dotjulmjnnrcijmiauis. Cambia quién puede hacer qué.
-- Se aplica después de 04_refuerzo_seguridad.sql.

-- A) mis_partes: los códigos de cajetín y de acceso salen solo de los apartamentos que tienen
--    una avería abierta, no de los 45. La web de mantenimiento solo los enseña en esos, así que
--    no se nota; pero si un enlace de mantenimiento se pierde, no se van todos los códigos de golpe.
create or replace function mis_partes(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; h date := _hoy(); ver_codigos boolean;
begin
  yo := _quien(p_k);
  ver_codigos := yo.rol = 'mantenimiento' or yo.lider;
  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol),
    'hoy', h,
    'tarifa', (select valor from ajustes where clave = 'tarifa_mantenimiento'),
    'apartamentos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta,
        'cajetin', case when ver_codigos and x.abierto then a.cajetin end,
        'codigo',  case when ver_codigos and x.abierto then a.codigo end,
        'parking', a.parking,
        'acceso',  case when ver_codigos and x.abierto then a.acceso end,
        'acceso_edificio', case when ver_codigos and x.abierto then e.acceso end
      ) order by a.edificio, a.id), '[]')
      from apartamentos a left join edificios e on e.id = a.edificio
      cross join lateral (select exists (select 1 from partes p
                            where p.apartamento = a.id and p.estado <> 'terminado') as abierto) x),
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
        'notas', p.notas, 'cerrado', p.cerrado,
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta
      ) order by p.urgente desc, p.creado)
      from partes p join apartamentos a on a.id = p.apartamento
      where p.estado <> 'terminado' or p.cerrado > now() - interval '31 days'), '[]'));
end $$;

-- B) parte_actualizar: hoy cualquier enlace válido (también los de limpieza) puede cambiar horas,
--    costes y estado de cualquier avería. Se limita a mantenimiento y a líderes, y se acotan las cifras.
create or replace function parte_actualizar(p_k text, p_id bigint, p_estado text, p_horas numeric,
  p_materiales text, p_coste_materiales numeric, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if yo.rol <> 'mantenimiento' and not yo.lider then raise exception 'sin_permiso'; end if;
  if p_horas is not null and (p_horas < 0 or p_horas > 24) then raise exception 'horas_no_validas'; end if;
  if p_coste_materiales is not null and (p_coste_materiales < 0 or p_coste_materiales > 5000) then
    raise exception 'coste_no_valido'; end if;
  update partes set
    estado = coalesce(p_estado, estado),
    asignado = case when p_estado in ('en_curso', 'terminado') and asignado is null and yo.rol = 'mantenimiento' then yo.id else asignado end,
    horas = coalesce(p_horas, horas),
    materiales = coalesce(left(p_materiales, 300), materiales),
    coste_materiales = coalesce(p_coste_materiales, coste_materiales),
    notas = case when length(trim(coalesce(p_nota, ''))) > 0
                 then notas || jsonb_build_object('ts', now(), 'por', yo.nombre, 'texto', left(trim(p_nota), 600)) else notas end,
    cerrado = case when p_estado = 'terminado' then now() when p_estado is not null then null else cerrado end
  where id = p_id;
  if not found then raise exception 'parte_no_existe'; end if;
end $$;

revoke execute on function mis_partes(text),
  parte_actualizar(text, bigint, text, numeric, text, numeric, text) from public, authenticated;
grant execute on function mis_partes(text),
  parte_actualizar(text, bigint, text, numeric, text, numeric, text) to anon;
notify pgrst, 'reload schema';
