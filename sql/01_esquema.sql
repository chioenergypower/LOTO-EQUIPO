-- LOTO EQUIPO · esquema de la base de datos (Supabase / Postgres)
-- Todas las tablas quedan cerradas (RLS sin políticas). Las webs solo usan las funciones
-- de 02_funciones.sql, que comprueban la clave del enlace personal antes de responder.
-- Claude y las tareas programadas entran con la clave de servicio (secreto de GitHub).

create table if not exists equipo (
  id text primary key,                       -- 'yudi', 'julieta'…
  nombre text not null,
  rol text not null check (rol in ('limpieza','mantenimiento','recepcion')),
  lider boolean not null default false,
  clave text not null unique default replace(gen_random_uuid()::text,'-',''),
  activo boolean not null default true
);

create table if not exists apartamentos (
  id text primary key,                       -- nombre: 'Cielo', 'Nieve'…
  edificio text, planta text, puerta text,
  cajetin text, codigo text,                 -- 🔴 sensible: solo sale por la función mi_dia
  minutos int not null default 60,           -- tiempo previsto de limpieza
  propio boolean not null default true
);

create table if not exists tareas_limpieza (
  id bigint generated always as identity primary key,
  fecha date not null,
  apartamento text not null references apartamentos(id),
  tipo text not null check (tipo in ('salida','entrada','salida-entrada','activar')),
  hora_salida text, hora_entrada text,
  energia text check (energia in ('off','on','router')),
  peticiones jsonb not null default '[]',          -- ["Cuna","Trona"]
  peticiones_hechas jsonb not null default '[]',
  personas text[] not null default '{}',           -- ids de equipo
  solo_camas text[] not null default '{}',         -- apoyo: solo hacen camas
  camas_hechas boolean not null default false,
  inicio timestamptz, fin timestamptz,
  nota text,
  unique (fecha, apartamento)
);
create index if not exists tareas_fecha on tareas_limpieza(fecha);

create table if not exists jornadas (
  persona text not null references equipo(id),
  fecha date not null,
  inicio timestamptz not null default now(),
  fin timestamptz,
  primary key (persona, fecha)
);

create table if not exists reposiciones (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  apartamento text not null references apartamentos(id),
  objeto text not null,
  precio numeric(8,2) not null default 0,
  persona text references equipo(id),
  pendiente boolean not null default false,   -- true = falta llevarlo
  hecho timestamptz,                           -- cuándo se llevó
  liquidado text                               -- mes en que se descontó al propietario (2026-11)
);

create table if not exists partes (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  apartamento text not null references apartamentos(id),
  descripcion text not null,
  urgente boolean not null default false,
  reporta text,                                -- nombre o 'Recepción', 'Cliente', 'Propietario'
  estado text not null default 'pendiente' check (estado in ('pendiente','asignado','en_curso','terminado')),
  asignado text references equipo(id),
  horas numeric(6,2) not null default 0,       -- 30 €/h
  materiales text,
  coste_materiales numeric(8,2) not null default 0,
  cargo_propietario boolean not null default false,
  notas jsonb not null default '[]',           -- [{ts, por, texto}]
  cerrado timestamptz,
  liquidado text
);

create table if not exists material (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  texto text not null,
  persona text references equipo(id),
  comprado timestamptz
);

create table if not exists mensajes (
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  de text not null,                            -- id de equipo o 'recepcion'
  para text not null,                          -- id de equipo o 'recepcion'
  apartamento text,
  texto text not null,
  leido timestamptz
);

create table if not exists ajustes (clave text primary key, valor jsonb not null);
insert into ajustes values ('tarifa_limpieza', '9'), ('tarifa_mantenimiento', '30') on conflict do nothing;

alter table equipo enable row level security;
alter table apartamentos enable row level security;
alter table tareas_limpieza enable row level security;
alter table jornadas enable row level security;
alter table reposiciones enable row level security;
alter table partes enable row level security;
alter table material enable row level security;
alter table mensajes enable row level security;
alter table ajustes enable row level security;
