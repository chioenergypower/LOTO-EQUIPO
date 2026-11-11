-- LOTO EQUIPO · consultas del panel de recepción (11/11/2026)
-- ⚠️ PENDIENTE DE APLICAR: necesita el OK de Chio. Se aplica después de 06_bandeja_whatsapp.sql.
-- No crea ni cambia ninguna tabla: solo añade funciones.
-- Todas exigen sesión de recepción con segundo paso (2FA). La clave pública y los enlaces del equipo no pueden llamarlas.
-- Recepción NO ve nada de propietarios: aquí no salen horas, costes, precios, cargos ni liquidaciones.
-- Tampoco salen códigos de cajetín ni de acceso.

-- El día de hoy: entradas, salidas, estado de cada apartamento, limpieza, averías, mensajes y equipo.
create or replace function public.recepcion_hoy() returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; h date := _hoy();
begin
  yo := _recepcion();
  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre,
          'admin', exists (select 1 from privado.recepcion_usuarios r where r.auth_id = auth.uid() and r.admin)),
    'hoy', h, 'ahora', now(),
    'apartamentos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'edificio', a.edificio,
        -- Una salida o una entrada de hoy manda sobre un cierre: recepción tiene que verla aunque el piso se cierre hoy.
        'estado', case when sa.id is not null and en.id is not null then 'sale_entra'
                       when sa.id is not null then 'sale'
                       when en.id is not null then 'entra'
                       when den.id is not null then 'ocupado'
                       when b.id is not null then 'cerrado'
                       else 'libre' end,
        'cerrado', b.id is not null,
        'hora_entrada', coalesce(en.hora_entrada, (select t.hora_entrada from tareas_limpieza t where t.apartamento = a.id and t.fecha = h and t.hora_entrada is not null limit 1)),
        'hasta', coalesce(den.salida, en.salida, b.hasta),
        'motivo', b.motivo
      ) order by a.edificio, a.id), '[]')
      from apartamentos a
      left join lateral (select x.id, x.hasta, x.motivo from bloqueos x where x.apartamento = a.id and x.desde <= h and x.hasta >= h order by x.hasta desc limit 1) b on true
      left join lateral (select s.id, s.salida from estancias s where s.apartamento = a.id and s.llegada < h and s.salida > h limit 1) den on true
      left join lateral (select s.id from estancias s where s.apartamento = a.id and s.salida = h limit 1) sa on true
      left join lateral (select s.id, s.salida, s.hora_entrada from estancias s where s.apartamento = a.id and s.llegada = h limit 1) en on true),
    'limpieza', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'apartamento', t.apartamento, 'edificio', a.edificio, 'tipo', t.tipo,
        'hora_salida', t.hora_salida, 'hora_entrada', t.hora_entrada,
        'personas', (select coalesce(jsonb_agg(e.nombre order by e.nombre), '[]') from equipo e where e.id = any(t.personas) or e.id = any(t.solo_camas)),
        'peticiones', t.peticiones, 'peticiones_hechas', t.peticiones_hechas,
        'inicio', t.inicio, 'fin', t.fin, 'nota', t.nota
      ) order by a.edificio, t.apartamento)
      from tareas_limpieza t join apartamentos a on a.id = t.apartamento where t.fecha = h), '[]'),
    'partes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'creado', p.creado, 'apartamento', p.apartamento, 'edificio', a.edificio,
        'descripcion', p.descripcion, 'urgente', p.urgente, 'estado', p.estado, 'reporta', p.reporta,
        'asignado', (select e.nombre from equipo e where e.id = p.asignado),
        'notas', (select coalesce(jsonb_agg(jsonb_build_object('ts', n -> 'ts', 'por', n -> 'por', 'texto', n -> 'texto')), '[]') from jsonb_array_elements(p.notas) n)
      ) order by p.urgente desc, p.creado desc)
      from partes p join apartamentos a on a.id = p.apartamento where p.estado <> 'terminado'), '[]'),
    'mensajes', coalesce((select jsonb_agg(x order by x ->> 'ts' desc) from (
        select jsonb_build_object('id', m.id, 'ts', m.ts, 'de', m.de, 'para', m.para,
               'nombre', (select e.nombre from equipo e where e.id = case when m.de = 'recepcion' then m.para else m.de end),
               'mio', m.de = 'recepcion', 'apartamento', m.apartamento, 'texto', m.texto, 'leido', m.leido is not null) x
        from mensajes m order by m.ts desc limit 60) s), '[]'),
    'material', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'texto', m.texto, 'creado', m.creado,
        'persona', (select e.nombre from equipo e where e.id = m.persona)) order by m.creado) from material m where m.comprado is null), '[]'),
    'llevar', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'apartamento', r.apartamento, 'objeto', r.objeto, 'creado', r.creado) order by r.creado)
        from reposiciones r where r.pendiente and r.hecho is null), '[]'),
    'equipo', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'rol', e.rol,
        'inicio', j.inicio, 'fin', j.fin,
        'tareas', (select count(*) from tareas_limpieza t where t.fecha = h and (e.id = any(t.personas) or e.id = any(t.solo_camas)))
      ) order by e.rol, e.nombre)
      from equipo e left join jornadas j on j.persona = e.id and j.fecha = h
      where e.activo and (e.rol in ('mantenimiento', 'recepcion') or j.persona is not null
            or exists (select 1 from tareas_limpieza t where t.fecha = h and (e.id = any(t.personas) or e.id = any(t.solo_camas))))), '[]'),
    'bandeja_pendientes', (select count(*) from bandeja where estado = 'pendiente'));
end $$;

-- Contestar a alguien del equipo (le sale en su web, en «Mensajes»).
create or replace function public.recepcion_mensaje(p_para text, p_apartamento text, p_texto text) returns void
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo;
begin
  yo := _recepcion();
  if length(trim(coalesce(p_texto, ''))) = 0 then raise exception 'falta_texto'; end if;
  if not exists (select 1 from equipo where id = p_para and activo) then raise exception 'persona_no_existe'; end if;
  insert into mensajes (de, para, apartamento, texto) values ('recepcion', p_para, nullif(p_apartamento, ''), left(trim(p_texto), 1000));
end $$;

-- Marcar como leídos los mensajes que el equipo ha mandado a recepción.
create or replace function public.recepcion_mensajes_leidos() returns void
language plpgsql security definer set search_path = public, privado as $$
begin
  perform _recepcion();
  update mensajes set leido = now() where para = 'recepcion' and leido is null;
end $$;

-- Avisar de una avería desde recepción (igual que desde limpieza: se asigna al obrero si solo hay uno).
create or replace function public.recepcion_incidencia(p_apartamento text, p_descripcion text, p_urgente boolean) returns void
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; obrero text;
begin
  yo := _recepcion();
  if length(trim(coalesce(p_descripcion, ''))) = 0 then raise exception 'falta_descripcion'; end if;
  select case when count(*) = 1 then min(id) end into obrero from equipo where rol = 'mantenimiento' and activo;
  insert into partes (apartamento, descripcion, urgente, reporta, asignado, estado)
  values (p_apartamento, left(trim(p_descripcion), 600), coalesce(p_urgente, false), 'Recepción (' || yo.nombre || ')', obrero,
          case when obrero is null then 'pendiente' else 'asignado' end);
end $$;

-- Marcar como comprado algo de la lista de material que falta.
create or replace function public.recepcion_material_comprado(p_id bigint) returns void
language plpgsql security definer set search_path = public, privado as $$
begin
  perform _recepcion();
  update material set comprado = now() where id = p_id and comprado is null;
  if not found then raise exception 'material_no_existe'; end if;
end $$;

revoke execute on function public.recepcion_hoy(), public.recepcion_mensaje(text, text, text), public.recepcion_mensajes_leidos(),
  public.recepcion_incidencia(text, text, boolean), public.recepcion_material_comprado(bigint) from public, anon, authenticated;
grant execute on function public.recepcion_hoy(), public.recepcion_mensaje(text, text, text), public.recepcion_mensajes_leidos(),
  public.recepcion_incidencia(text, text, boolean), public.recepcion_material_comprado(bigint) to authenticated;
notify pgrst, 'reload schema';
