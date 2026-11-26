-- LOTO EQUIPO · 10 · App de RECEPCIÓN (Sete y Santi)
-- Estado de todos los pisos, llegadas/salidas, traspaso entre recepcionistas,
-- disponibilidad con precio, cola de reservas para ICNEA, partes y mensajes a limpieza.
-- Nada de propietarios. Sin códigos de cajetín.

-- ── Tablas nuevas ──
create table if not exists rec_notas (
  id bigserial primary key,
  ts timestamptz not null default now(),
  de text not null,
  para text,                 -- null = para todo recepción
  apartamento text,
  texto text not null,
  importante boolean not null default false,
  hecho timestamptz,
  hecho_por text
);
alter table rec_notas enable row level security;

create table if not exists tarifas (
  id bigserial primary key,
  apartamento text not null,
  desde date not null,
  hasta date not null,       -- incluido
  precio_noche numeric not null,
  min_noches int default 1,
  nota text
);
alter table tarifas enable row level security;

create table if not exists rec_chat (
  id bigserial primary key,
  ts timestamptz not null default now(),
  persona text not null,
  pregunta text not null,
  respuesta text
);
alter table rec_chat enable row level security;

-- Datos del cliente: esquema privado, solo vía funciones.
create table if not exists privado.rec_reservas (
  id bigserial primary key,
  creado timestamptz not null default now(),
  creado_por text not null,
  apartamento text not null,
  llegada date not null,
  salida date not null,
  adultos int not null default 1,
  ninos int not null default 0,
  bebes int not null default 0,
  nombre text not null,
  apellidos text,
  email text not null,
  telefono text not null,
  precio_total numeric not null,
  canal text not null default 'Teléfono',
  notas text,
  estado text not null default 'pendiente', -- pendiente · creada · error · anulada
  icnea_id text,
  error text,
  revisado_chio boolean not null default false
);
alter table privado.rec_reservas enable row level security;

-- ── Ayudantes ──
create or replace function _rec(p_k text) returns equipo
language plpgsql security definer set search_path = public as $$
declare r equipo;
begin
  r := _quien(p_k);
  if r.rol <> 'recepcion' then raise exception 'solo_recepcion' using errcode = 'P0001'; end if;
  return r;
end $$;

-- Estado de un piso en una fecha
create or replace function _estado_piso(p_apto text, p_f date) returns jsonb
language sql stable security definer set search_path = public as $$
  with e as (
    select
      exists(select 1 from estancias s where s.apartamento = p_apto and s.llegada <= p_f and s.salida > p_f) ocupado_noche,
      exists(select 1 from estancias s where s.apartamento = p_apto and s.llegada = p_f) llega,
      exists(select 1 from estancias s where s.apartamento = p_apto and s.salida = p_f) sale,
      (select s.hora_entrada from estancias s where s.apartamento = p_apto and s.llegada = p_f limit 1) hora_llegada,
      (select b.motivo from bloqueos b where b.apartamento = p_apto and b.desde <= p_f and b.hasta >= p_f limit 1) bloqueo,
      (select t.tipo from tareas_limpieza t where t.apartamento = p_apto and t.fecha = p_f order by t.id limit 1) t_tipo,
      (select t.inicio from tareas_limpieza t where t.apartamento = p_apto and t.fecha = p_f order by t.id limit 1) t_inicio,
      (select t.fin from tareas_limpieza t where t.apartamento = p_apto and t.fecha = p_f order by t.id limit 1) t_fin,
      (select t.hora_salida from tareas_limpieza t where t.apartamento = p_apto and t.fecha = p_f order by t.id limit 1) t_hs,
      (select t.nota from tareas_limpieza t where t.apartamento = p_apto and t.fecha = p_f order by t.id limit 1) t_nota,
      (select count(*) from partes p where p.apartamento = p_apto and p.estado not in ('hecho','cerrado','terminado','anulado')) partes
  )
  select jsonb_build_object(
    'apartamento', p_apto,
    'ocupado', ocupado_noche, 'llega', llega, 'sale', sale, 'hora_llegada', hora_llegada,
    'bloqueo', bloqueo, 'partes_abiertos', partes,
    'limpieza', case when t_tipo is null then null else jsonb_build_object(
        'tipo', t_tipo, 'inicio', t_inicio, 'fin', t_fin, 'hora_salida', t_hs, 'nota', t_nota) end,
    'estado', case
      when bloqueo is not null and not ocupado_noche then 'bloqueado'
      when t_tipo is not null and t_fin is not null then 'limpio'
      when t_tipo is not null and t_inicio is not null then 'limpiando'
      when sale and t_tipo is not null then 'por_limpiar'
      when ocupado_noche and not llega then 'ocupado'
      when llega then 'listo_para_entrar'
      else 'libre' end
  ) from e
$$;

-- ── Panel del día ──
create or replace function rec_panel(p_k text, p_fecha date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; f date;
begin
  yo := _rec(p_k);
  f := coalesce(p_fecha, _hoy());
  return jsonb_build_object(
    'yo', jsonb_build_object('id', yo.id, 'nombre', yo.nombre),
    'fecha', f, 'ahora', now(),
    'pisos', (select coalesce(jsonb_agg(_estado_piso(a.id, f) || jsonb_build_object('edificio', a.edificio, 'propio', a.propio)
                order by a.edificio, a.id), '[]') from apartamentos a),
    'llegadas_manana', (select coalesce(jsonb_agg(jsonb_build_object('apartamento', s.apartamento, 'hora', s.hora_entrada, 'noches', s.salida - s.llegada) order by s.hora_entrada nulls last), '[]')
                from estancias s where s.llegada = f + 1),
    'salidas_manana', (select coalesce(jsonb_agg(jsonb_build_object('apartamento', s.apartamento)), '[]') from estancias s where s.salida = f + 1),
    'notas', (select coalesce(jsonb_agg(to_jsonb(n) order by n.importante desc, n.ts desc), '[]') from rec_notas n
                where n.hecho is null or n.hecho > now() - interval '2 days'),
    'reservas', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'creado', r.creado, 'creado_por', r.creado_por,
                 'apartamento', r.apartamento, 'llegada', r.llegada, 'salida', r.salida, 'nombre', r.nombre,
                 'precio_total', r.precio_total, 'estado', r.estado, 'error', r.error) order by r.creado desc), '[]')
                from privado.rec_reservas r where r.creado > now() - interval '14 days'),
    'partes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'apartamento', p.apartamento, 'descripcion', p.descripcion,
                 'urgente', p.urgente, 'estado', p.estado, 'creado', p.creado) order by p.urgente desc, p.creado desc), '[]')
                from partes p where p.estado not in ('hecho','cerrado','terminado','anulado')),
    'mensajes_equipo', (select coalesce(jsonb_agg(to_jsonb(m) order by m.ts desc), '[]') from (
                select * from mensajes m where m.ts > now() - interval '3 days' order by m.ts desc limit 40) m),
    'ultima_sync', (select max(actualizado) from estancias)
  );
end $$;

-- ── Disponibilidad con precio ──
create or replace function rec_disponibles(p_k text, p_desde date, p_hasta date, p_personas int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; noches int := p_hasta - p_desde;
begin
  yo := _rec(p_k);
  if noches < 1 then raise exception 'fechas_no_validas' using errcode = 'P0001'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'precio_total') is null, (x->>'precio_total')::numeric, x->>'apartamento'), '[]') from (
    select jsonb_build_object(
      'apartamento', f.id, 'plazas', f.plazas_junta, 'dormitorios', f.dormitorios, 'camas', f.camas,
      'categoria', f.categoria, 'propio', a.propio, 'edificio', a.edificio, 'mascotas', f.mascotas,
      'noches', noches,
      'precio_total', (select case when count(*) = noches then sum(t.precio_noche) end
                         from generate_series(p_desde, p_hasta - 1, interval '1 day') d
                         join lateral (select precio_noche from tarifas t where t.apartamento = f.id and d::date between t.desde and t.hasta order by t.id desc limit 1) t on true),
      'enlace_fotos', f.enlace_fotos
    ) x
    from apartamentos_ficha f join apartamentos a on a.id = f.id
    where coalesce(f.plazas_junta, 0) >= p_personas
      and not exists (select 1 from estancias s where s.apartamento = f.id and s.llegada < p_hasta and s.salida > p_desde)
      and not exists (select 1 from bloqueos b where b.apartamento = f.id and b.desde < p_hasta and b.hasta >= p_desde)
  ) q);
end $$;

-- ── Notas de traspaso entre recepcionistas ──
create or replace function rec_nota(p_k text, p_texto text, p_apartamento text default null, p_para text default null, p_importante boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare yo equipo; nid bigint;
begin
  yo := _rec(p_k);
  if coalesce(trim(p_texto), '') = '' then raise exception 'texto_vacio' using errcode = 'P0001'; end if;
  insert into rec_notas(de, para, apartamento, texto, importante) values (yo.nombre, p_para, nullif(p_apartamento,''), p_texto, p_importante) returning id into nid;
  return nid;
end $$;

create or replace function rec_nota_hecha(p_k text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _rec(p_k);
  update rec_notas set hecho = now(), hecho_por = yo.nombre where id = p_id;
end $$;

-- ── Aviso a mantenimiento y mensaje a limpieza ──
create or replace function rec_parte(p_k text, p_apartamento text, p_descripcion text, p_urgente boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare yo equipo; nid bigint;
begin
  yo := _rec(p_k);
  insert into partes(apartamento, descripcion, urgente, reporta, estado, asignado)
  values (p_apartamento, p_descripcion, p_urgente, yo.nombre, 'asignado', 'jose_matador') returning id into nid;
  return nid;
end $$;

create or replace function rec_mensaje(p_k text, p_para text, p_apartamento text, p_texto text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _rec(p_k);
  insert into mensajes(de, para, apartamento, texto) values (yo.nombre, p_para, nullif(p_apartamento,''), p_texto);
end $$;

-- ── Cerrar reserva (queda en cola para ICNEA) ──
create or replace function rec_reserva(p_k text, p jsonb) returns bigint
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; nid bigint; d1 date := (p->>'llegada')::date; d2 date := (p->>'salida')::date;
begin
  yo := _rec(p_k);
  if coalesce(p->>'email','') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'falta_email' using errcode = 'P0001'; end if;
  if coalesce(p->>'nombre','') = '' or coalesce(p->>'telefono','') = '' then raise exception 'faltan_datos' using errcode = 'P0001'; end if;
  if d2 <= d1 then raise exception 'fechas_no_validas' using errcode = 'P0001'; end if;
  if (select coalesce(plazas_junta,0) from apartamentos_ficha where id = p->>'apartamento')
     < coalesce((p->>'adultos')::int,0) + coalesce((p->>'ninos')::int,0) then
    raise exception 'supera_plazas' using errcode = 'P0001'; end if;
  if exists (select 1 from estancias s where s.apartamento = p->>'apartamento' and s.llegada < d2 and s.salida > d1)
     or exists (select 1 from bloqueos b where b.apartamento = p->>'apartamento' and b.desde < d2 and b.hasta >= d1)
     or exists (select 1 from privado.rec_reservas r where r.apartamento = p->>'apartamento' and r.estado in ('pendiente','creada') and r.llegada < d2 and r.salida > d1) then
    raise exception 'no_disponible' using errcode = 'P0001'; end if;
  insert into privado.rec_reservas(creado_por, apartamento, llegada, salida, adultos, ninos, bebes, nombre, apellidos, email, telefono, precio_total, canal, notas)
  values (yo.nombre, p->>'apartamento', d1, d2, coalesce((p->>'adultos')::int,1), coalesce((p->>'ninos')::int,0), coalesce((p->>'bebes')::int,0),
          p->>'nombre', p->>'apellidos', p->>'email', p->>'telefono', (p->>'precio_total')::numeric, coalesce(p->>'canal','Teléfono'), p->>'notas')
  returning id into nid;
  -- Bloqueo provisional para que nadie más lo venda mientras se crea en ICNEA
  insert into bloqueos(apartamento, desde, hasta, motivo, tipo) values (p->>'apartamento', d1, d2 - 1, 'Reserva recepción #' || nid || ' (pendiente ICNEA)', 'recepcion');
  return nid;
end $$;

-- ── Historial del asistente ──
create or replace function rec_chat_historial(p_k text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _rec(p_k);
  return (select coalesce(jsonb_agg(jsonb_build_object('ts', ts, 'pregunta', pregunta, 'respuesta', respuesta) order by ts), '[]')
          from (select * from rec_chat where persona = yo.id order by ts desc limit 20) c);
end $$;

revoke all on function _rec(text), _estado_piso(text, date) from public, anon, authenticated;
grant execute on function rec_panel(text, date), rec_disponibles(text, date, date, int), rec_nota(text, text, text, text, boolean),
  rec_nota_hecha(text, bigint), rec_parte(text, text, text, boolean), rec_mensaje(text, text, text, text),
  rec_reserva(text, jsonb), rec_chat_historial(text) to anon, authenticated;
