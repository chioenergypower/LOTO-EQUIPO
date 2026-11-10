-- LOTO EQUIPO · funciones que usan las webs. Cada una comprueba la clave del enlace.
-- «security definer»: se ejecutan con permisos del dueño, así las tablas pueden seguir cerradas.

create or replace function _quien(p_k text) returns equipo
language plpgsql security definer set search_path = public as $$
declare r equipo;
begin
  select * into r from equipo where clave = p_k and activo;
  if not found then raise exception 'enlace_no_valido' using errcode = 'P0001'; end if;
  return r;
end $$;

create or replace function _hoy() returns date language sql stable as
$$ select (now() at time zone 'Europe/Madrid')::date $$;

-- ───────── LIMPIEZA ─────────
create or replace function mi_dia(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; h date := _hoy(); res jsonb;
begin
  yo := _quien(p_k);
  select jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol, 'lider', yo.lider),
    'fecha', h,
    'ahora', now(),
    'tarifa', (select valor from ajustes where clave = 'tarifa_limpieza'),
    'jornada', (select jsonb_build_object('inicio', j.inicio, 'fin', j.fin) from jornadas j where j.persona = yo.id and j.fecha = h),
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'apartamento', t.apartamento, 'tipo', t.tipo,
        'hora_salida', t.hora_salida, 'hora_entrada', t.hora_entrada, 'energia', t.energia,
        'peticiones', t.peticiones, 'peticiones_hechas', t.peticiones_hechas,
        'solo_camas', yo.id = any(t.solo_camas), 'camas_hechas', t.camas_hechas,
        'inicio', t.inicio, 'fin', t.fin, 'nota', t.nota,
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta,
        'cajetin', a.cajetin, 'codigo', a.codigo, 'acceso', a.acceso, 'minutos', a.minutos,
        'con', (select coalesce(jsonb_agg(e.nombre order by e.nombre), '[]') from equipo e
                where (e.id = any(t.personas) or e.id = any(t.solo_camas)) and e.id <> yo.id)
      ) order by t.hora_entrada nulls last, a.edificio, t.apartamento)
      from tareas_limpieza t join apartamentos a on a.id = t.apartamento
      where t.fecha = h and (yo.id = any(t.personas) or yo.id = any(t.solo_camas))), '[]'),
    'llevar', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'apartamento', r.apartamento, 'objeto', r.objeto) order by r.creado)
      from reposiciones r where r.pendiente and r.hecho is null), '[]'),
    'reposiciones', coalesce((select jsonb_agg(jsonb_build_object('apartamento', r.apartamento, 'objeto', r.objeto, 'precio', r.precio, 'pendiente', r.pendiente) order by r.creado)
      from reposiciones r where (r.creado at time zone 'Europe/Madrid')::date = h), '[]'),
    'incidencias', coalesce((select jsonb_agg(jsonb_build_object('apartamento', p.apartamento, 'descripcion', p.descripcion, 'urgente', p.urgente, 'estado', p.estado) order by p.creado)
      from partes p where (p.creado at time zone 'Europe/Madrid')::date = h and p.reporta = yo.nombre), '[]'),
    'material', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'texto', m.texto) order by m.creado)
      from material m where m.comprado is null), '[]'),
    'mensajes', coalesce((select jsonb_agg(x order by x->>'ts' desc) from (
        select jsonb_build_object('ts', m.ts, 'mio', m.de = yo.id, 'apartamento', m.apartamento, 'texto', m.texto) x
        from mensajes m where m.de = yo.id or m.para = yo.id order by m.ts desc limit 40) s), '[]'),
    'mes', coalesce((select jsonb_agg(jsonb_build_object('fecha', j.fecha,
        'minutos', round(extract(epoch from (coalesce(j.fin, now()) - j.inicio)) / 60)) order by j.fecha desc)
      from jornadas j where j.persona = yo.id and date_trunc('month', j.fecha) = date_trunc('month', h)), '[]')
  ) into res;
  update mensajes set leido = now() where para = yo.id and leido is null;
  return res;
end $$;

create or replace function jornada(p_k text, p_accion text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo; h date := _hoy();
begin
  yo := _quien(p_k);
  if p_accion = 'empezar' then
    insert into jornadas(persona, fecha) values (yo.id, h) on conflict do nothing;
  elsif p_accion = 'terminar' then
    update jornadas set fin = now() where persona = yo.id and fecha = h and fin is null;
  else raise exception 'accion_no_valida'; end if;
end $$;

create or replace function tarea(p_k text, p_id bigint, p_accion text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if not exists (select 1 from tareas_limpieza where id = p_id and fecha = _hoy()
                 and (yo.id = any(personas) or yo.id = any(solo_camas))) then
    raise exception 'tarea_no_asignada'; end if;
  if p_accion = 'empezar' then update tareas_limpieza set inicio = coalesce(inicio, now()) where id = p_id;
  elsif p_accion = 'terminar' then update tareas_limpieza set fin = now(), inicio = coalesce(inicio, now()) where id = p_id;
  elsif p_accion = 'reiniciar' then update tareas_limpieza set inicio = null, fin = null where id = p_id;
  elsif p_accion = 'camas' then update tareas_limpieza set camas_hechas = true where id = p_id;
  else raise exception 'accion_no_valida'; end if;
end $$;

create or replace function peticion(p_k text, p_id bigint, p_nombre text, p_hecha boolean) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  update tareas_limpieza set peticiones_hechas =
    case when p_hecha then (select coalesce(jsonb_agg(distinct v), '[]') from jsonb_array_elements(peticiones_hechas || to_jsonb(p_nombre)) v)
         else (select coalesce(jsonb_agg(v), '[]') from jsonb_array_elements(peticiones_hechas) v where v <> to_jsonb(p_nombre)) end
  where id = p_id and fecha = _hoy() and yo.id = any(personas);
end $$;

create or replace function reposicion(p_k text, p_apartamento text, p_objeto text, p_precio numeric, p_pendiente boolean) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_objeto, ''))) = 0 then raise exception 'falta_objeto'; end if;
  insert into reposiciones(apartamento, objeto, precio, persona, pendiente, hecho)
  values (p_apartamento, left(trim(p_objeto), 120), greatest(coalesce(p_precio, 0), 0), yo.id, coalesce(p_pendiente, false),
          case when coalesce(p_pendiente, false) then null else now() end);
end $$;

create or replace function reposicion_llevada(p_k text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin perform _quien(p_k); update reposiciones set hecho = now(), pendiente = false where id = p_id; end $$;

create or replace function incidencia(p_k text, p_apartamento text, p_descripcion text, p_urgente boolean) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo; obrero text;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_descripcion, ''))) = 0 then raise exception 'falta_descripcion'; end if;
  -- Si solo hay un obrero de mantenimiento activo, la avería se le asigna directamente.
  select case when count(*) = 1 then min(id) end into obrero from equipo where rol = 'mantenimiento' and activo;
  insert into partes(apartamento, descripcion, urgente, reporta, asignado, estado)
  values (p_apartamento, left(trim(p_descripcion), 600), coalesce(p_urgente, false), yo.nombre, obrero,
          case when obrero is null then 'pendiente' else 'asignado' end);
end $$;

create or replace function falta_material(p_k text, p_texto text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_texto, ''))) = 0 then raise exception 'falta_texto'; end if;
  insert into material(texto, persona) values (left(trim(p_texto), 200), yo.id);
end $$;

create or replace function mensaje(p_k text, p_apartamento text, p_texto text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_texto, ''))) = 0 then raise exception 'falta_texto'; end if;
  insert into mensajes(de, para, apartamento, texto) values (yo.id, 'recepcion', nullif(p_apartamento, ''), left(trim(p_texto), 1000));
end $$;

-- Agenda: lo que viene (hoy + 6 semanas), SIN códigos. Para la vista semanal y el calendario.
create or replace function mi_agenda(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; h date := _hoy();
begin
  yo := _quien(p_k);
  return jsonb_build_object('hoy', h, 'hasta', h + 41,
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'fecha', t.fecha, 'apartamento', t.apartamento, 'tipo', t.tipo, 'edificio', a.edificio,
        'hora_salida', t.hora_salida, 'hora_entrada', t.hora_entrada, 'minutos', a.minutos, 'nota', t.nota
      ) order by t.fecha, a.edificio, t.apartamento)
      from tareas_limpieza t join apartamentos a on a.id = t.apartamento
      where t.fecha between h and h + 41 and (yo.id = any(t.personas) or yo.id = any(t.solo_camas))), '[]'));
end $$;

-- ───────── MANTENIMIENTO ─────────
-- Los obreros ven los partes abiertos (sin códigos: la puerta la abre limpieza) y los suyos cerrados del mes.
create or replace function mis_partes(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre, 'rol', yo.rol),
    'tarifa', (select valor from ajustes where clave = 'tarifa_mantenimiento'),
    'apartamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'edificio', a.edificio) order by a.edificio, a.id), '[]') from apartamentos a),
    'partes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'creado', p.creado, 'apartamento', p.apartamento, 'descripcion', p.descripcion,
        'urgente', p.urgente, 'reporta', p.reporta, 'estado', p.estado,
        'asignado', (select e.nombre from equipo e where e.id = p.asignado), 'mio', p.asignado = yo.id,
        'horas', p.horas, 'materiales', p.materiales, 'coste_materiales', p.coste_materiales,
        'notas', p.notas, 'cerrado', p.cerrado,
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta
      ) order by p.urgente desc, p.creado)
      from partes p join apartamentos a on a.id = p.apartamento
      where p.estado <> 'terminado' or p.cerrado > now() - interval '31 days'), '[]'));
end $$;

create or replace function parte_actualizar(p_k text, p_id bigint, p_estado text, p_horas numeric,
  p_materiales text, p_coste_materiales numeric, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  update partes set
    estado = coalesce(p_estado, estado),
    asignado = case when p_estado in ('en_curso', 'terminado') and asignado is null and yo.rol = 'mantenimiento' then yo.id else asignado end,
    horas = coalesce(p_horas, horas),
    materiales = coalesce(p_materiales, materiales),
    coste_materiales = coalesce(p_coste_materiales, coste_materiales),
    notas = case when length(trim(coalesce(p_nota, ''))) > 0
                 then notas || jsonb_build_object('ts', now(), 'por', yo.nombre, 'texto', left(trim(p_nota), 600)) else notas end,
    cerrado = case when p_estado = 'terminado' then now() when p_estado is not null then null else cerrado end
  where id = p_id;
  if not found then raise exception 'parte_no_existe'; end if;
end $$;

-- Permisos: el público (anon) solo puede llamar a estas funciones.
revoke all on function _quien(text) from public, anon, authenticated;
grant execute on function mi_dia(text), jornada(text, text), tarea(text, bigint, text), peticion(text, bigint, text, boolean),
  reposicion(text, text, text, numeric, boolean), reposicion_llevada(text, bigint), incidencia(text, text, text, boolean),
  falta_material(text, text), mensaje(text, text, text), mis_partes(text), mi_agenda(text),
  parte_actualizar(text, bigint, text, numeric, text, numeric, text) to anon;
notify pgrst, 'reload schema';
