-- 06 · Web de limpieza (Chio 14/11/2026 20:51):
--   · Seba en el equipo (hace camas).
--   · Incidencias con foto (van a mantenimiento como partes).
--   · Reposiciones con foto del objeto roto y del nuevo.
--   · Daños del cliente para abrir incidencia en Booking/Airbnb: mínimo 4 fotos → aviso URGENTE a Recepción.
--   · mi_dia: equipo de hoy, tiempo estimado y datos para «lo importante de hoy».

insert into equipo(id, nombre, rol, lider, clave, activo)
values ('seba', 'Seba', 'limpieza', false, replace(gen_random_uuid()::text, '-', ''), true)
on conflict (id) do update set activo = true;

alter table reposiciones add column if not exists foto_roto text, add column if not exists foto_nuevo text;

create table if not exists danos (
  id bigserial primary key,
  creado timestamptz not null default now(),
  apartamento text not null references apartamentos(id),
  plataforma text,                 -- Booking / Airbnb / Directa / No lo sé
  descripcion text not null,
  persona text,
  enviado timestamptz,             -- cuando tiene ≥4 fotos y se manda a Recepción
  atendido timestamptz,            -- Recepción lo ha abierto en la plataforma
  nota text
);
create table if not exists danos_fotos (
  id bigserial primary key,
  dano_id bigint not null references danos(id) on delete cascade,
  datos text not null,
  creado timestamptz not null default now()
);
alter table danos enable row level security;
alter table danos_fotos enable row level security;

create or replace function _foto_ok(p_datos text) returns void language plpgsql as $$
begin
  if p_datos is null or p_datos !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'foto_no_valida'; end if;
  if length(p_datos) > 1500000 then raise exception 'foto_muy_grande'; end if;
end $$;

-- Incidencia que devuelve el nº de parte, para poder añadirle fotos (parte_foto) y que las vea mantenimiento.
create or replace function incidencia_v2(p_k text, p_apartamento text, p_descripcion text, p_urgente boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare yo equipo; obrero text; nid bigint;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_descripcion, ''))) = 0 then raise exception 'falta_descripcion'; end if;
  select case when count(*) = 1 then min(id) end into obrero from equipo where rol = 'mantenimiento' and activo;
  insert into partes(apartamento, descripcion, urgente, reporta, asignado, estado)
  values (p_apartamento, left(trim(p_descripcion), 600), coalesce(p_urgente, false), yo.nombre, obrero,
          case when obrero is null then 'pendiente' else 'asignado' end)
  returning id into nid;
  return nid;
end $$;

-- Reposición con fotos (roto y nuevo). Devuelve el id.
create or replace function reposicion_v2(p_k text, p_apartamento text, p_objeto text, p_precio numeric, p_pendiente boolean,
                                         p_foto_roto text, p_foto_nuevo text) returns bigint
language plpgsql security definer set search_path = public as $$
declare yo equipo; nid bigint;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_objeto, ''))) = 0 then raise exception 'falta_objeto'; end if;
  if p_foto_roto is not null then perform _foto_ok(p_foto_roto); end if;
  if p_foto_nuevo is not null then perform _foto_ok(p_foto_nuevo); end if;
  insert into reposiciones(apartamento, objeto, precio, persona, pendiente, hecho, foto_roto, foto_nuevo)
  values (p_apartamento, left(trim(p_objeto), 120), greatest(coalesce(p_precio, 0), 0), yo.id, coalesce(p_pendiente, false),
          case when coalesce(p_pendiente, false) then null else now() end, p_foto_roto, p_foto_nuevo)
  returning id into nid;
  return nid;
end $$;

-- Foto del objeto nuevo cuando se lleva más tarde.
create or replace function reposicion_foto(p_k text, p_id bigint, p_tipo text, p_datos text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k); perform _foto_ok(p_datos);
  if p_tipo = 'roto' then update reposiciones set foto_roto = p_datos where id = p_id;
  elsif p_tipo = 'nuevo' then update reposiciones set foto_nuevo = p_datos where id = p_id;
  else raise exception 'tipo_no_valido'; end if;
  if not found then raise exception 'no_existe'; end if;
end $$;

-- Daños del cliente (incidencia para Booking/Airbnb).
create or replace function dano_crear(p_k text, p_apartamento text, p_plataforma text, p_descripcion text) returns bigint
language plpgsql security definer set search_path = public as $$
declare yo equipo; nid bigint;
begin
  yo := _quien(p_k);
  if length(trim(coalesce(p_descripcion, ''))) = 0 then raise exception 'falta_descripcion'; end if;
  insert into danos(apartamento, plataforma, descripcion, persona)
  values (p_apartamento, left(coalesce(p_plataforma, 'No lo sé'), 30), left(trim(p_descripcion), 800), yo.id)
  returning id into nid;
  return nid;
end $$;

create or replace function dano_foto(p_k text, p_id bigint, p_datos text) returns int
language plpgsql security definer set search_path = public as $$
declare yo equipo; n int;
begin
  yo := _quien(p_k); perform _foto_ok(p_datos);
  if not exists (select 1 from danos where id = p_id and enviado is null) then raise exception 'no_existe'; end if;
  select count(*) into n from danos_fotos where dano_id = p_id;
  if n >= 12 then raise exception 'maximo_12_fotos'; end if;
  insert into danos_fotos(dano_id, datos) values (p_id, p_datos);
  return n + 1;
end $$;

create or replace function dano_enviar(p_k text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo; d danos; n int;
begin
  yo := _quien(p_k);
  select * into d from danos where id = p_id;
  if not found then raise exception 'no_existe'; end if;
  select count(*) into n from danos_fotos where dano_id = p_id;
  if n < 4 then raise exception 'minimo_4_fotos'; end if;
  update danos set enviado = coalesce(enviado, now()) where id = p_id;
  insert into mensajes(de, para, apartamento, texto)
  values (yo.id, 'recepcion', d.apartamento,
          '🔴 URGENTE · DAÑOS DEL CLIENTE (abrir incidencia en ' || coalesce(d.plataforma, '¿plataforma?') || '): ' || d.descripcion || ' · ' || n || ' fotos (daño nº ' || d.id || ')');
end $$;

-- Recepción: ver daños y sus fotos.
create or replace function recepcion_danos() returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo;
begin
  yo := _recepcion();
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'creado', d.creado, 'apartamento', d.apartamento,
      'plataforma', d.plataforma, 'descripcion', d.descripcion, 'persona', (select e.nombre from equipo e where e.id = d.persona),
      'enviado', d.enviado, 'atendido', d.atendido,
      'fotos', (select coalesce(jsonb_agg(f.datos order by f.id), '[]') from danos_fotos f where f.dano_id = d.id)) order by d.creado desc)
    from danos d where d.enviado is not null and (d.atendido is null or d.atendido > now() - interval '7 days')), '[]');
end $$;

revoke all on function incidencia_v2(text, text, text, boolean), reposicion_v2(text, text, text, numeric, boolean, text, text),
  reposicion_foto(text, bigint, text, text), dano_crear(text, text, text, text), dano_foto(text, bigint, text), dano_enviar(text, bigint) from public;
grant execute on function incidencia_v2(text, text, text, boolean), reposicion_v2(text, text, text, numeric, boolean, text, text),
  reposicion_foto(text, bigint, text, text), dano_crear(text, text, text, text), dano_foto(text, bigint, text), dano_enviar(text, bigint) to anon, authenticated;
revoke all on function recepcion_danos() from public, anon;
grant execute on function recepcion_danos() to authenticated;
revoke all on function _foto_ok(text) from public, anon, authenticated;

-- mi_dia: añade equipo de hoy, minutos para el tiempo estimado y datos de reposiciones con id.
create or replace function public.mi_dia(p_k text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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
    'equipo_hoy', coalesce((select jsonb_agg(x order by x->>'nombre') from (
        select jsonb_build_object('id', e.id, 'nombre', e.nombre,
          'camas', not exists (select 1 from tareas_limpieza t where t.fecha = h and e.id = any(t.personas))) x
        from equipo e where e.activo and exists (select 1 from tareas_limpieza t where t.fecha = h and (e.id = any(t.personas) or e.id = any(t.solo_camas)))) s), '[]'),
    'minutos_dia', (select coalesce(sum(a.minutos), 0) from tareas_limpieza t join apartamentos a on a.id = t.apartamento
        where t.fecha = h and t.tipo in ('salida', 'salida-entrada', 'obra')),
    'llevar', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'apartamento', r.apartamento, 'objeto', r.objeto) order by r.creado)
      from reposiciones r where r.pendiente and r.hecho is null), '[]'),
    'reposiciones', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'apartamento', r.apartamento, 'objeto', r.objeto, 'precio', r.precio, 'pendiente', r.pendiente,
        'foto_roto', r.foto_roto is not null, 'foto_nuevo', r.foto_nuevo is not null) order by r.creado)
      from reposiciones r where (r.creado at time zone 'Europe/Madrid')::date = h), '[]'),
    'incidencias', coalesce((select jsonb_agg(jsonb_build_object('apartamento', p.apartamento, 'descripcion', p.descripcion, 'urgente', p.urgente, 'estado', p.estado,
        'nfotos', (select count(*) from partes_fotos f where f.parte_id = p.id)) order by p.creado)
      from partes p where (p.creado at time zone 'Europe/Madrid')::date = h and p.reporta = yo.nombre), '[]'),
    'danos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'apartamento', d.apartamento, 'plataforma', d.plataforma, 'descripcion', d.descripcion,
        'enviado', d.enviado, 'nfotos', (select count(*) from danos_fotos f where f.dano_id = d.id)) order by d.creado)
      from danos d where (d.creado at time zone 'Europe/Madrid')::date = h and d.persona = yo.id), '[]'),
    'partes_hoy', coalesce((select jsonb_agg(jsonb_build_object('apartamento', p.apartamento, 'descripcion', p.descripcion, 'urgente', p.urgente))
      from partes p where p.estado <> 'terminado' and p.urgente
        and exists (select 1 from tareas_limpieza t where t.fecha = h and t.apartamento = p.apartamento)), '[]'),
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
end $function$;
