-- Fotos de los partes de mantenimiento (Chio 13/11/2026).
-- Las fotos se guardan reducidas (JPEG ~1280 px) dentro de la base de datos, en una tabla cerrada al público.
-- Solo se suben y se ven con un enlace personal válido (mismas funciones con clave que el resto de la web).
create table if not exists partes_fotos (
  id bigint generated always as identity primary key,
  parte_id bigint not null references partes(id) on delete cascade,
  creado timestamptz not null default now(),
  por text,
  datos text not null
);
create index if not exists partes_fotos_parte on partes_fotos(parte_id);
alter table partes_fotos enable row level security;

create or replace function parte_foto(p_k text, p_id bigint, p_datos text) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if p_datos is null or p_datos !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'foto_no_valida'; end if;
  if length(p_datos) > 1500000 then raise exception 'foto_muy_grande'; end if;
  if not exists (select 1 from partes where id = p_id) then raise exception 'parte_no_existe'; end if;
  if (select count(*) from partes_fotos where parte_id = p_id) >= 10 then raise exception 'maximo_10_fotos'; end if;
  insert into partes_fotos(parte_id, por, datos) values (p_id, yo.nombre, p_datos);
end $$;

create or replace function parte_fotos(p_k text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _quien(p_k);
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'creado', f.creado, 'por', f.por, 'datos', f.datos) order by f.creado)
    from partes_fotos f where f.parte_id = p_id), '[]');
end $$;

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
        'nfotos', (select count(*) from partes_fotos f where f.parte_id = p.id),
        'edificio', a.edificio, 'planta', a.planta, 'puerta', a.puerta
      ) order by p.urgente desc, p.creado)
      from partes p join apartamentos a on a.id = p.apartamento
      where p.estado <> 'terminado' or p.cerrado > now() - interval '31 days'), '[]'));
end $$;

grant execute on function parte_foto(text, bigint, text), parte_fotos(text, bigint), mis_partes(text) to anon;
notify pgrst, 'reload schema';
