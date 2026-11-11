-- LOTO EQUIPO · bandeja única de recepción y WhatsApp propio (versión 2, 11/11/2026)
-- ✅ APLICADO el 11/11/2026 con el OK de Chio, como migración «bandeja_whatsapp_y_recepcion_con_2fa».
-- Se aplica después de 05b_permiso_rls_auto_enable.sql.
-- Solo AÑADE: no borra ni cambia ninguna tabla, columna ni dato de los que ya hay.
--
-- Requisitos de seguridad de Chio (11/11), y cómo se cumplen aquí:
--   · Nombres, teléfonos y conversaciones en tablas separadas con RLS y sin acceso anónimo
--       → esquema «privado», que la API de Supabase no publica. Las funciones de limpieza y
--         mantenimiento no lo tocan, y la clave pública no tiene ningún permiso sobre él.
--   · El panel de recepción entra con usuario, contraseña y segundo paso (2FA), no con enlace
--       → las funciones del panel solo responden a una sesión de Supabase Auth de nivel «aal2»
--         (contraseña + código) de una persona dada de alta como recepción.
--   · Tabla de auditoría → «privado.accesos»: quién abre, contesta, atiende o borra, y cuándo.
--   · Borrado ajustable → dos ajustes (días) y una función de limpieza. Vacío = no se borra.
--   · Nada de esto escribe datos personales en registros.

create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

-- ───────── quién es de recepción (cuenta de Supabase Auth ↔ persona del equipo) ─────────
create table if not exists privado.recepcion_usuarios (
  auth_id uuid primary key references auth.users(id) on delete cascade,
  persona text not null unique references public.equipo(id),
  admin   boolean not null default false,      -- administración (Chio): además puede borrar contactos
  activo  boolean not null default true,
  creado  timestamptz not null default now()
);

-- ───────── datos de huéspedes (cerrados) ─────────
create table if not exists privado.contactos (
  id             bigint generated always as identity primary key,
  telefono       text not null unique check (telefono ~ '^[0-9]{6,15}$'),  -- solo dígitos con prefijo de país, como lo da WhatsApp
  nombre         text,                                                     -- nombre del perfil de WhatsApp
  idioma         text,
  notas          text,
  creado         timestamptz not null default now(),
  ultimo_mensaje timestamptz
);

-- ───────── bandeja única (sin datos personales) ─────────
create table if not exists public.bandeja (
  id           bigint generated always as identity primary key,
  canal        text not null check (canal in ('whatsapp', 'booking', 'airbnb', 'correo')),
  apartamento  text references public.apartamentos(id),            -- vacío = «sin identificar»
  estancia     bigint references public.estancias(id) on delete set null,
  recibido     timestamptz not null default now(),
  tipo         text not null default 'mensaje',                    -- mensaje | cancelacion | cambio_fecha | pregunta…
  estado       text not null default 'pendiente' check (estado in ('pendiente', 'atendido')),
  atendido_por text references public.equipo(id),
  atendido_en  timestamptz,
  contacto     bigint references privado.contactos(id) on delete set null,   -- solo el número interno del contacto
  ref_externa  text,                                               -- identificador del correo en Outlook; NUNCA el nº de reserva
  sin_leer     int not null default 0
);
create index if not exists bandeja_estado on public.bandeja (estado, recibido desc);
-- Una sola conversación de WhatsApp abierta por contacto.
create unique index if not exists bandeja_wa_abierta on public.bandeja (contacto) where canal = 'whatsapp' and estado = 'pendiente';

create table if not exists privado.wa_mensajes (
  id          bigint generated always as identity primary key,
  wa_id       text unique,                                         -- identificador del mensaje en WhatsApp: evita guardarlo dos veces
  contacto    bigint not null references privado.contactos(id) on delete cascade,
  bandeja     bigint references public.bandeja(id) on delete set null,
  direccion   text not null check (direccion in ('entrante', 'saliente')),
  tipo        text not null default 'text',
  texto       text,                                                -- en las plantillas solo se guarda su nombre, nunca los datos (códigos)
  plantilla   text,
  estado      text,                                                -- sent | delivered | read | failed (solo salientes)
  enviado_por text references public.equipo(id),
  ts          timestamptz not null default now()
);
create index if not exists wa_mensajes_contacto on privado.wa_mensajes (contacto, ts);

-- ───────── auditoría ─────────
create table if not exists privado.accesos (
  id       bigint generated always as identity primary key,
  ts       timestamptz not null default now(),
  persona  text,                                                   -- id de equipo
  accion   text not null,                                          -- ver | enviar | atender | reabrir | asignar | borrar_contacto | limpieza_automatica
  bandeja  bigint,
  contacto bigint
);

alter table privado.recepcion_usuarios enable row level security;
alter table privado.contactos          enable row level security;
alter table privado.wa_mensajes        enable row level security;
alter table privado.accesos            enable row level security;
alter table public.bandeja             enable row level security;
revoke all on all tables    in schema privado from public, anon, authenticated;
revoke all on all sequences in schema privado from public, anon, authenticated;
revoke all on public.bandeja from public, anon, authenticated;

-- Borrado ajustable (días). Vacío (null) = no se borra. Lo decide Chio.
insert into public.ajustes values ('huespedes_borrar_conversaciones_dias', 'null'), ('huespedes_borrar_contactos_dias', 'null')
  on conflict do nothing;

-- ───────── quién llama: sesión de Supabase Auth con segundo paso, de alguien de recepción ─────────
create or replace function public._recepcion() returns public.equipo
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; u uuid := auth.uid();
begin
  if u is null then raise exception 'sin_sesion' using errcode = 'P0001'; end if;
  if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then raise exception 'falta_segundo_paso' using errcode = 'P0001'; end if;
  select e.* into yo from privado.recepcion_usuarios r join equipo e on e.id = r.persona
   where r.auth_id = u and r.activo and e.activo and e.rol = 'recepcion';
  if not found then raise exception 'sin_permiso' using errcode = 'P0001'; end if;
  return yo;
end $$;

-- ───────── lo que llama el webhook (solo con la clave de servicio) ─────────
create or replace function public.wa_entrante(p_wa_id text, p_telefono text, p_nombre text, p_tipo text, p_texto text, p_ts timestamptz)
returns bigint
language plpgsql security definer set search_path = public, privado as $$
declare c bigint; b bigint; cuando timestamptz := coalesce(p_ts, now());
begin
  if coalesce(p_telefono, '') !~ '^[0-9]{6,15}$' then raise exception 'telefono_no_valido'; end if;
  if coalesce(p_wa_id, '') = '' then raise exception 'falta_id'; end if;
  insert into privado.contactos (telefono, nombre, ultimo_mensaje)
    values (p_telefono, nullif(left(trim(coalesce(p_nombre, '')), 120), ''), cuando)
    on conflict (telefono) do update
      set nombre = coalesce(excluded.nombre, privado.contactos.nombre),
          ultimo_mensaje = greatest(privado.contactos.ultimo_mensaje, excluded.ultimo_mensaje)
    returning id into c;
  select id into b from bandeja where canal = 'whatsapp' and contacto = c and estado = 'pendiente';
  if b is null then
    begin
      insert into bandeja (canal, contacto, recibido) values ('whatsapp', c, cuando) returning id into b;
    exception when unique_violation then   -- otro mensaje del mismo cliente la abrió a la vez
      select id into b from bandeja where canal = 'whatsapp' and contacto = c and estado = 'pendiente';
    end;
  end if;
  insert into privado.wa_mensajes (wa_id, contacto, bandeja, direccion, tipo, texto, ts)
    values (p_wa_id, c, b, 'entrante', left(coalesce(p_tipo, 'text'), 30), left(p_texto, 4096), cuando)
    on conflict (wa_id) do nothing;
  if found then   -- si WhatsApp repite el aviso, no cuenta dos veces
    update bandeja set recibido = greatest(recibido, cuando), sin_leer = sin_leer + 1 where id = b;
  end if;
  return b;
end $$;

create or replace function public.wa_estado(p_wa_id text, p_estado text) returns void
language sql security definer set search_path = public, privado as $$
  update privado.wa_mensajes set estado = left(p_estado, 20) where wa_id = p_wa_id and direccion = 'saliente';
$$;

-- Apunta lo enviado. Solo la clave de servicio: la función de envío ya ha comprobado quién envía.
create or replace function public.wa_saliente(p_persona text, p_bandeja bigint, p_wa_id text, p_texto text, p_plantilla text) returns void
language plpgsql security definer set search_path = public, privado as $$
declare c bigint;
begin
  select contacto into c from bandeja where id = p_bandeja and canal = 'whatsapp';
  if c is null then raise exception 'conversacion_no_existe'; end if;
  insert into privado.wa_mensajes (wa_id, contacto, bandeja, direccion, tipo, texto, plantilla, estado, enviado_por)
    values (p_wa_id, c, p_bandeja, 'saliente', case when p_plantilla is null then 'text' else 'template' end,
            left(p_texto, 4096), left(p_plantilla, 120), 'sent', p_persona);
  insert into privado.accesos (persona, accion, bandeja, contacto) values (p_persona, 'enviar', p_bandeja, c);
end $$;

-- ───────── lo que usa el panel de recepción (sesión con usuario, contraseña y segundo paso) ─────────
-- Antes de enviar: comprueba la sesión y devuelve el teléfono y quién envía.
create or replace function public.wa_preparar_envio(p_bandeja bigint) returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; c privado.contactos; ultimo timestamptz;
begin
  yo := _recepcion();
  select co.* into c from bandeja b join privado.contactos co on co.id = b.contacto where b.id = p_bandeja and b.canal = 'whatsapp';
  if not found then raise exception 'conversacion_no_existe'; end if;
  select max(ts) into ultimo from privado.wa_mensajes where contacto = c.id and direccion = 'entrante';
  return jsonb_build_object('telefono', c.telefono, 'persona', yo.id,
    'dentro_24h', coalesce(ultimo > now() - interval '24 hours', false));   -- fuera de 24 h WhatsApp solo admite plantillas
end $$;

create or replace function public.bandeja_lista() returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo;
begin
  yo := _recepcion();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'canal', b.canal, 'apartamento', b.apartamento, 'recibido', b.recibido, 'tipo', b.tipo,
      'estado', b.estado, 'sin_leer', b.sin_leer, 'atendido_en', b.atendido_en,
      'atendido_por', (select e.nombre from equipo e where e.id = b.atendido_por),
      'nombre', c.nombre, 'telefono', c.telefono
    ) order by (b.estado = 'pendiente') desc, b.recibido desc)
    from bandeja b left join privado.contactos c on c.id = b.contacto
    where b.estado = 'pendiente' or b.atendido_en > now() - interval '7 days'), '[]');
end $$;

create or replace function public.conversacion(p_bandeja bigint) returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; c bigint; res jsonb;
begin
  yo := _recepcion();
  select contacto into c from bandeja where id = p_bandeja;
  if not found then raise exception 'conversacion_no_existe'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('ts', m.ts, 'entrante', m.direccion = 'entrante', 'tipo', m.tipo,
      'texto', m.texto, 'plantilla', m.plantilla, 'estado', m.estado,
      'por', (select e.nombre from equipo e where e.id = m.enviado_por)) order by m.ts), '[]')
    into res from (select * from privado.wa_mensajes where contacto = c order by ts desc limit 200) m;
  update bandeja set sin_leer = 0 where id = p_bandeja;
  insert into privado.accesos (persona, accion, bandeja, contacto) values (yo.id, 'ver', p_bandeja, c);
  return res;
end $$;

create or replace function public.bandeja_atender(p_id bigint, p_atendido boolean) returns void
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo;
begin
  yo := _recepcion();
  update bandeja set estado = case when p_atendido then 'atendido' else 'pendiente' end,
                     atendido_por = case when p_atendido then yo.id end,
                     atendido_en = case when p_atendido then now() end
    where id = p_id;
  if not found then raise exception 'conversacion_no_existe'; end if;
  insert into privado.accesos (persona, accion, bandeja) values (yo.id, case when p_atendido then 'atender' else 'reabrir' end, p_id);
end $$;

create or replace function public.bandeja_asignar(p_id bigint, p_apartamento text) returns void
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo;
begin
  yo := _recepcion();
  update bandeja set apartamento = nullif(p_apartamento, '') where id = p_id;   -- la clave ajena comprueba que el apartamento existe
  if not found then raise exception 'conversacion_no_existe'; end if;
  insert into privado.accesos (persona, accion, bandeja) values (yo.id, 'asignar', p_id);
end $$;

-- Derecho de supresión: si un cliente pide que se borren sus datos. Solo administración.
create or replace function public.contacto_borrar(p_bandeja bigint) returns void
language plpgsql security definer set search_path = public, privado as $$
declare yo equipo; c bigint;
begin
  yo := _recepcion();
  if not exists (select 1 from privado.recepcion_usuarios where auth_id = auth.uid() and admin) then
    raise exception 'solo_administracion' using errcode = 'P0001'; end if;
  select contacto into c from bandeja where id = p_bandeja;
  if c is null then raise exception 'conversacion_no_existe'; end if;
  delete from privado.contactos where id = c;                      -- arrastra sus mensajes
  update bandeja set estado = 'atendido', atendido_por = yo.id, atendido_en = now() where id = p_bandeja;
  insert into privado.accesos (persona, accion, bandeja, contacto) values (yo.id, 'borrar_contacto', p_bandeja, c);
end $$;

-- ───────── limpieza automática (no hace nada mientras los dos ajustes estén vacíos) ─────────
-- Los días se cuentan desde la salida de la estancia enlazada; si la conversación no está enlazada
-- a ninguna estancia, desde el último mensaje.
create or replace function public.huespedes_limpiar() returns jsonb
language plpgsql security definer set search_path = public, privado as $$
declare dc int; dk int; n_m int := 0; n_c int := 0;
begin
  select nullif(valor::text, 'null')::int into dc from ajustes where clave = 'huespedes_borrar_conversaciones_dias';
  select nullif(valor::text, 'null')::int into dk from ajustes where clave = 'huespedes_borrar_contactos_dias';
  if dc is not null then
    with borrados as (
      delete from privado.wa_mensajes m
       where coalesce((select s.salida::timestamptz from bandeja b join estancias s on s.id = b.estancia where b.id = m.bandeja),
                      (select max(x.ts) from privado.wa_mensajes x where x.contacto = m.contacto)) < now() - make_interval(days => dc)
      returning 1)
    select count(*) into n_m from borrados;
  end if;
  if dk is not null then
    with borrados as (
      delete from privado.contactos c
       where coalesce((select max(s.salida)::timestamptz from bandeja b join estancias s on s.id = b.estancia where b.contacto = c.id),
                      c.ultimo_mensaje, c.creado) < now() - make_interval(days => dk)
      returning 1)
    select count(*) into n_c from borrados;
  end if;
  if n_m + n_c > 0 then
    insert into privado.accesos (persona, accion) values (null, format('limpieza_automatica: %s mensajes, %s contactos', n_m, n_c));
  end if;
  return jsonb_build_object('mensajes_borrados', n_m, 'contactos_borrados', n_c);
end $$;

-- ───────── permisos ─────────
-- Nada es público. «anon» (la clave pública y los enlaces del equipo) no puede ejecutar NINGUNA de estas funciones.
--   · Panel de recepción → rol «authenticated», y además cada función exige sesión con segundo paso.
--   · Webhook, apunte de envíos y limpieza → solo la clave de servicio.
revoke execute on function
  public._recepcion(), public.wa_entrante(text, text, text, text, text, timestamptz), public.wa_estado(text, text),
  public.wa_saliente(text, bigint, text, text, text), public.wa_preparar_envio(bigint),
  public.bandeja_lista(), public.conversacion(bigint), public.bandeja_atender(bigint, boolean),
  public.bandeja_asignar(bigint, text), public.contacto_borrar(bigint), public.huespedes_limpiar()
  from public, anon, authenticated;
grant execute on function
  public.wa_entrante(text, text, text, text, text, timestamptz), public.wa_estado(text, text),
  public.wa_saliente(text, bigint, text, text, text), public.huespedes_limpiar()
  to service_role;
grant execute on function
  public.wa_preparar_envio(bigint), public.bandeja_lista(), public.conversacion(bigint),
  public.bandeja_atender(bigint, boolean), public.bandeja_asignar(bigint, text), public.contacto_borrar(bigint)
  to authenticated;
notify pgrst, 'reload schema';
