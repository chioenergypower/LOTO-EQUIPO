-- Web de mantenimiento: vistas Hoy / Mañana / Semana (libre · con horario · ocupado)
-- y datos de acceso de cada apartamento (cajetín, parking, edificio).
-- Los códigos NO se guardan en este repositorio (es público): se cargan solo en la base de datos.

alter table apartamentos add column if not exists parking text;

create table if not exists edificios (
  id     text primary key,          -- mismo texto que apartamentos.edificio
  acceso text                       -- barrera / puerta del parking / indicaciones del edificio
);

create table if not exists estancias (
  id           bigserial primary key,
  apartamento  text not null references apartamentos(id),
  llegada      date not null,
  salida       date not null,
  hora_entrada text,
  origen       text not null default 'icnea',
  actualizado  timestamptz not null default now()
);
create index if not exists estancias_apt_fechas on estancias (apartamento, llegada, salida);

create table if not exists bloqueos (
  id          bigserial primary key,
  apartamento text not null references apartamentos(id),
  desde       date not null,
  hasta       date not null,
  motivo      text
);

alter table edificios enable row level security;
alter table estancias enable row level security;
alter table bloqueos  enable row level security;

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
        'notas', p.notas, 'cerrado', p.cerrado,
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta
      ) order by p.urgente desc, p.creado)
      from partes p join apartamentos a on a.id = p.apartamento
      where p.estado <> 'terminado' or p.cerrado > now() - interval '31 days'), '[]'));
end $$;

grant execute on function mis_partes(text) to anon;
notify pgrst, 'reload schema';

-- Tipo de bloqueo (Chio 10/11): cierre | propietario | mantenimiento | obra.
-- propietario => tarea 'activar' el día que empieza y 'salida' el día que sale el propietario.
alter table bloqueos add column if not exists tipo text not null default 'cierre';
