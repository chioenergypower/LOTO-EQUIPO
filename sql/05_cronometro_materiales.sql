-- 05 · Mantenimiento: cronómetro (Empezar / Pausa / Terminar), materiales por líneas
--      y cargo al apartamento para la liquidación mensual (Chio 14/11/2026).
-- Tarifa: ajustes.tarifa_mantenimiento (30 €/h). Se cobra el tiempo exacto en minutos.
-- Se cobra al propietario: apartamentos de propietario (propio = false) + Edén, Amanecer y Blossom.

alter table partes
  add column if not exists inicio timestamptz,             -- reloj en marcha desde… (null = parado)
  add column if not exists minutos numeric not null default 0, -- minutos trabajados acumulados
  add column if not exists tarifa numeric,                 -- €/h aplicada (se fija al empezar)
  add column if not exists coste_mano_obra numeric not null default 0;
alter table partes add column if not exists total numeric
  generated always as (coalesce(coste_mano_obra,0) + coalesce(coste_materiales,0)) stored;

create table if not exists partes_materiales (
  id bigserial primary key,
  parte_id bigint not null references partes(id) on delete cascade,
  concepto text not null check (length(trim(concepto)) between 1 and 120),
  precio numeric not null check (precio >= 0 and precio <= 2000),
  por text,
  creado timestamptz not null default now()
);
alter table partes_materiales enable row level security;
create index if not exists partes_materiales_parte on partes_materiales(parte_id);

alter table apartamentos add column if not exists cobrar_mantenimiento boolean;
update apartamentos set cobrar_mantenimiento = (not propio) or id in ('Edén','Amanecer','Blossom')
 where cobrar_mantenimiento is null;
alter table apartamentos alter column cobrar_mantenimiento set default true;

-- Recalcula horas y costes de un parte a partir de los minutos y de las líneas de material.
create or replace function _parte_recalc(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update partes p set
    horas = round(p.minutos / 60.0, 2),
    coste_mano_obra = round(p.minutos / 60.0 * coalesce(p.tarifa, (select (valor#>>'{}')::numeric from ajustes where clave = 'tarifa_mantenimiento'), 30), 2),
    coste_materiales = coalesce((select sum(m.precio) from partes_materiales m where m.parte_id = p.id), 0),
    materiales = (select string_agg(m.concepto || ' (' || to_char(m.precio, 'FM999990.00') || ' €)', ', ' order by m.id)
                    from partes_materiales m where m.parte_id = p.id)
  where p.id = p_id;
$$;

-- Para el reloj de un parte y suma los minutos.
create or replace function _parte_parar(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update partes set minutos = minutos + round(extract(epoch from now() - inicio) / 60.0, 1), inicio = null
   where id = p_id and inicio is not null;
  select _parte_recalc(p_id);
$$;

create or replace function _puede_mant(yo equipo) returns void
language plpgsql as $$
begin
  if yo.rol <> 'mantenimiento' and not yo.lider then raise exception 'sin_permiso'; end if;
end $$;

-- ▶ EMPEZAR / SEGUIR: pone el reloj en marcha. Si había otro en marcha, lo pausa solo.
create or replace function parte_empezar(p_k text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; otro text;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  if not exists (select 1 from partes where id = p_id and estado <> 'terminado') then raise exception 'parte_no_existe'; end if;
  select apartamento into otro from partes where inicio is not null and id <> p_id and asignado = yo.id limit 1;
  perform _parte_parar(id) from partes where inicio is not null and id <> p_id and asignado = yo.id;
  update partes set estado = 'en_curso', asignado = coalesce(asignado, yo.id),
         inicio = coalesce(inicio, now()),
         tarifa = coalesce(tarifa, (select (valor#>>'{}')::numeric from ajustes where clave = 'tarifa_mantenimiento'), 30)
   where id = p_id;
  return jsonb_build_object('pausado', otro);
end $$;

-- ⏸ PAUSA (me voy y vuelvo otro día): para el reloj, el parte sigue abierto.
create or replace function parte_pausar(p_k text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  perform _parte_parar(p_id);
end $$;

-- ⏹ TERMINAR: para el reloj, calcula mano de obra + materiales y deja el cargo listo para la liquidación.
create or replace function parte_terminar(p_k text, p_id bigint, p_nota text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo equipo; r partes;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  perform _parte_parar(p_id);
  update partes p set estado = 'terminado', cerrado = now(), asignado = coalesce(p.asignado, yo.id),
         tarifa = coalesce(p.tarifa, (select (valor#>>'{}')::numeric from ajustes where clave = 'tarifa_mantenimiento'), 30),
         cargo_propietario = coalesce((select a.cobrar_mantenimiento from apartamentos a where a.id = p.apartamento), true),
         notas = case when length(trim(coalesce(p_nota, ''))) > 0
                      then p.notas || jsonb_build_object('ts', now(), 'por', yo.nombre, 'texto', 'Hecho: ' || left(trim(p_nota), 600))
                      else p.notas end
   where p.id = p_id and p.estado <> 'terminado';
  if not found then raise exception 'parte_no_existe'; end if;
  perform _parte_recalc(p_id);
  select * into r from partes where id = p_id;
  return jsonb_build_object('minutos', r.minutos, 'mano_obra', r.coste_mano_obra, 'materiales', r.coste_materiales, 'total', r.total);
end $$;

-- 🧾 Material: añadir y quitar líneas (qué es + cuánto ha costado).
create or replace function parte_material(p_k text, p_id bigint, p_concepto text, p_precio numeric) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  if length(trim(coalesce(p_concepto, ''))) = 0 then raise exception 'falta_concepto'; end if;
  if p_precio is null or p_precio < 0 or p_precio > 2000 then raise exception 'precio_no_valido'; end if;
  if not exists (select 1 from partes where id = p_id and (estado <> 'terminado' or cerrado > now() - interval '2 days' and liquidado is null)) then
    raise exception 'parte_no_existe'; end if;
  insert into partes_materiales(parte_id, concepto, precio, por) values (p_id, left(trim(p_concepto), 120), round(p_precio, 2), yo.nombre);
  perform _parte_recalc(p_id);
end $$;

create or replace function parte_material_borrar(p_k text, p_mid bigint) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo; pid bigint;
begin
  yo := _quien(p_k); perform _puede_mant(yo);
  delete from partes_materiales m using partes p
   where m.id = p_mid and p.id = m.parte_id and p.liquidado is null
   returning m.parte_id into pid;
  if pid is null then raise exception 'no_existe'; end if;
  perform _parte_recalc(pid);
end $$;

-- Recepción/Chio puede corregir el tiempo (p. ej. si se olvidó de pulsar Terminar).
create or replace function parte_corregir_tiempo(p_k text, p_id bigint, p_minutos numeric) returns void
language plpgsql security definer set search_path = public as $$
declare yo equipo;
begin
  yo := _quien(p_k);
  if not yo.lider then raise exception 'sin_permiso'; end if;
  if p_minutos is null or p_minutos < 0 or p_minutos > 24*60*5 then raise exception 'minutos_no_validos'; end if;
  update partes set minutos = p_minutos, inicio = null,
         notas = notas || jsonb_build_object('ts', now(), 'por', yo.nombre, 'texto', 'Tiempo corregido a ' || p_minutos || ' min')
   where id = p_id and liquidado is null;
  perform _parte_recalc(p_id);
end $$;

-- Cargos de mantenimiento por apartamento y mes (para la liquidación mensual a propietarios).
create or replace view privado.mantenimiento_cargos as
select p.id as parte, p.apartamento, to_char(p.cerrado at time zone 'Europe/Madrid', 'YYYY-MM') as mes,
       (p.cerrado at time zone 'Europe/Madrid')::date as fecha, p.descripcion,
       p.minutos, p.horas, p.tarifa, p.coste_mano_obra as mano_obra, p.coste_materiales as materiales,
       p.materiales as detalle_materiales, p.total, p.cargo_propietario as se_cobra, p.liquidado
  from partes p where p.estado = 'terminado';

create or replace view privado.mantenimiento_por_mes as
select apartamento, mes, count(*) as trabajos, sum(minutos) as minutos, sum(mano_obra) as mano_obra,
       sum(materiales) as materiales, sum(total) as total,
       string_agg(to_char(fecha, 'DD/MM') || ' ' || descripcion || ' — ' || to_char(total, 'FM999990.00') || ' €', ' · ' order by fecha) as detalle
  from privado.mantenimiento_cargos where se_cobra and liquidado is null
 group by apartamento, mes;

revoke all on function parte_empezar(text, bigint), parte_pausar(text, bigint), parte_terminar(text, bigint, text),
  parte_material(text, bigint, text, numeric), parte_material_borrar(text, bigint), parte_corregir_tiempo(text, bigint, numeric) from public;
grant execute on function parte_empezar(text, bigint), parte_pausar(text, bigint), parte_terminar(text, bigint, text),
  parte_material(text, bigint, text, numeric), parte_material_borrar(text, bigint), parte_corregir_tiempo(text, bigint, numeric) to anon, authenticated;
revoke all on function _parte_recalc(bigint), _parte_parar(bigint), _puede_mant(equipo) from public, anon, authenticated;

-- mis_partes: añade reloj, costes y líneas de material.
create or replace function public.mis_partes(p_k text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
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
