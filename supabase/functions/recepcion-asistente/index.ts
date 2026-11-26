// Asistente de recepción (burbuja de la app de Sete y Santi).
// Comprueba el enlace personal, consulta la base del equipo y responde con Claude.
// Necesita el secreto ANTHROPIC_API_KEY (lo pega Chio en Supabase → Edge Functions → Secrets).
// 🔴 Nunca devuelve códigos de cajetín, wifi, IBAN ni datos de propietarios.

const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const AK = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = Deno.env.get("RECEPCION_MODELO") ?? "claude-sonnet-5-5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { ...cors, "content-type": "application/json" } });

async function rest(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const t = await r.text();
  if (!r.ok) throw new Error(t.slice(0, 300));
  return t ? JSON.parse(t) : null;
}
const rpc = (fn: string, args: Record<string, unknown>) => rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });
const enc = encodeURIComponent;

const FICHA_COLS = "id,nombre_icnea,categoria,plazas_junta,dormitorios,banos,altillo,camas,camas_matrimonio,camas_individuales,sofas_cama,literas,ascensor,parada_telesilla,enlace_fotos,tostadora,microondas,horno,lavadora,secadora,lavavajillas,cafetera,vitro_induccion,tv,calefaccion,terraza,guardaesquis,cuna,trona,mascotas,equipamiento_otros,notas,pendiente,m2,plancha,secador,wifi,wifi_datos,parking_icnea";

const tools = [
  { name: "buscar_conocimiento", description: "Busca en las respuestas validadas por Chio (bot_conocimiento) y en las reglas del proyecto. Úsalo para normas, horarios, política, carretera, servicios, cómo actuar.", input_schema: { type: "object", properties: { texto: { type: "string", description: "1-3 palabras clave" }, apartamento: { type: "string" } }, required: ["texto"] } },
  { name: "ficha_apartamento", description: "Ficha de un apartamento: plazas de la Junta, camas, equipamiento (tostadora, lavavajillas, cuna...), mascotas, telesilla, fotos.", input_schema: { type: "object", properties: { nombre: { type: "string" } }, required: ["nombre"] } },
  { name: "disponibilidad", description: "Apartamentos libres entre dos fechas para N personas, con plazas y precio total si hay tarifa cargada.", input_schema: { type: "object", properties: { llegada: { type: "string", description: "YYYY-MM-DD" }, salida: { type: "string", description: "YYYY-MM-DD" }, personas: { type: "integer" } }, required: ["llegada", "salida", "personas"] } },
  { name: "estado_pisos", description: "Estado de los pisos en una fecha: ocupado, llega, sale, limpio, limpiando, por limpiar, bloqueado, partes abiertos. Sin fecha = hoy.", input_schema: { type: "object", properties: { fecha: { type: "string" }, apartamento: { type: "string" } } } },
  { name: "parte_nieve_carretera", description: "Información actual de Sierra Nevada (pistas, remontes, nieve) y enlaces de carretera DGT/AEMET.", input_schema: { type: "object", properties: {} } },
  { name: "proponer_reserva", description: "Cuando el recepcionista ya ha cerrado con el cliente, prepara la ficha de reserva para que la confirme con un botón. No crea nada por sí sola.", input_schema: { type: "object", properties: { apartamento: { type: "string" }, llegada: { type: "string" }, salida: { type: "string" }, adultos: { type: "integer" }, ninos: { type: "integer" }, bebes: { type: "integer" }, nombre: { type: "string" }, apellidos: { type: "string" }, email: { type: "string" }, telefono: { type: "string" }, precio_total: { type: "number" }, notas: { type: "string" } }, required: ["apartamento", "llegada", "salida", "precio_total"] } },
  { name: "crear_parte", description: "Crea un parte de mantenimiento (avería) asignado a José Matador.", input_schema: { type: "object", properties: { apartamento: { type: "string" }, descripcion: { type: "string" }, urgente: { type: "boolean" } }, required: ["apartamento", "descripcion"] } },
  { name: "buscar_documentos", description: "Busca en las hojas de ruta, la chuleta de recepción, los procedimientos (cerrar reserva, pagos Santander, reubicaciones, limpieza, IVA…) y el conocimiento por apartamento. Úsalo para cualquier '¿cómo hago…?'.", input_schema: { type: "object", properties: { texto: { type: "string", description: "1-2 palabras clave, p. ej. 'factura', 'pago', 'reubicar'" } }, required: ["texto"] } },
  { name: "guardar_conocimiento", description: "Guarda en la base lo que el recepcionista enseña o corrige («esto no es así, es de esta manera»). Úsalo SIEMPRE que te corrijan o te den un dato nuevo, después de confirmarlo con él.", input_schema: { type: "object", properties: { tema: { type: "string" }, pregunta: { type: "string", description: "situación o pregunta tipo" }, respuesta_correcta: { type: "string" }, apartamento: { type: "string" } }, required: ["tema", "respuesta_correcta"] } },
  { name: "pedir_factura", description: "El recepcionista pide una factura para un cliente. Crea la tarea para que Claude (recepción automática) la haga en Holded y se la envíe al cliente.", input_schema: { type: "object", properties: { cliente: { type: "string" }, reserva: { type: "string", description: "nº de reserva ICNEA o apartamento y fechas" }, datos_fiscales: { type: "string", description: "nombre/razón social, NIF/CIF, dirección, email (si los tiene)" }, notas: { type: "string" } }, required: ["cliente", "reserva"] } },
  { name: "consultar_a_chio", description: "Cuando no sabes algo, o el recepcionista tampoco lo sabe, deja la pregunta apuntada para Chio y Claude.", input_schema: { type: "object", properties: { pregunta: { type: "string" }, apartamento: { type: "string" } }, required: ["pregunta"] } },
  { name: "avisar_equipo", description: "Cuando el recepcionista pide hablar con Chio o con alguien del equipo (Yudi, Julieta, José Matador, Sete, Santi), o pide pasarle un recado: deja el mensaje para que Claude se lo mande por WhatsApp. Escribe el mensaje ya redactado, claro y completo, como lo leerá esa persona.", input_schema: { type: "object", properties: { para: { type: "string", enum: ["Chio", "Yudi", "Julieta", "José Matador", "Sete", "Santi"] }, mensaje: { type: "string" }, apartamento: { type: "string" }, urgente: { type: "boolean" } }, required: ["para", "mensaje"] } },
  { name: "nota_traspaso", description: "Deja una nota para el otro recepcionista (traspaso de turno).", input_schema: { type: "object", properties: { texto: { type: "string" }, apartamento: { type: "string" }, importante: { type: "boolean" } }, required: ["texto"] } },
];

async function apto(nombre: string): Promise<string | null> {
  const r = await rest(`apartamentos_ficha?select=id&id=ilike.*${enc(nombre.trim())}*&limit=1`);
  return r?.[0]?.id ?? null;
}

async function runTool(name: string, i: any, k: string, propuestas: any[]) {
  switch (name) {
    case "buscar_conocimiento": {
      const q = enc(`*${String(i.texto).trim()}*`);
      const or = `(tema.ilike.${q},pregunta_tipo.ilike.${q},respuesta_buena.ilike.${q})`;
      const a = await rest(`bot_conocimiento?select=tema,pregunta_tipo,respuesta_buena,apartamento,temporada&or=${or}&limit=8`);
      const reg = await rpc("rec_reglas_buscar", { p_texto: i.texto }).catch(() => []);
      return { conocimiento: a, reglas: reg };
    }
    case "buscar_documentos":
      return await rpc("rec_docs_buscar", { p_texto: String(i.texto).trim() });
    case "guardar_conocimiento": {
      const yo = (await rest(`equipo?select=nombre&clave=eq.${enc(k)}&limit=1`))?.[0]?.nombre ?? "Recepción";
      const f = new Date().toLocaleString("es-ES", { timeZone: "Europe/Madrid", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
      await rest("bot_conocimiento", { method: "POST", body: JSON.stringify({ tema: i.tema, pregunta_tipo: i.pregunta ?? null, respuesta_buena: i.respuesta_correcta, apartamento: i.apartamento ?? null, origen: `${yo} ${f}`, notas: "Enseñado desde la app de recepción" }) });
      return { ok: true };
    }
    case "pedir_factura": {
      const id = await rpc("rec_nota", { p_k: k, p_texto: `🧾 FACTURA para ${i.cliente} · ${i.reserva}${i.datos_fiscales ? "\nDatos: " + i.datos_fiscales : ""}${i.notas ? "\n" + i.notas : ""}`, p_apartamento: null, p_para: "Claude", p_importante: true });
      await rest(`rec_notas?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ tipo: "factura" }) });
      return { ok: true, aviso: "Tarea creada: Claude se pone con la factura en 1-2 minutos." };
    }
    case "consultar_a_chio": {
      const id = await rpc("rec_nota", { p_k: k, p_texto: `❓ ${i.pregunta}`, p_apartamento: i.apartamento ?? null, p_para: "Chio", p_importante: true });
      await rest(`rec_notas?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ tipo: "consulta" }) });
      return { ok: true };
    }
    case "ficha_apartamento": {
      const r = await rest(`apartamentos_ficha?select=${FICHA_COLS}&id=ilike.*${enc(String(i.nombre).trim())}*&limit=2`);
      if (!r?.length) return { error: "No encuentro ese apartamento" };
      for (const f of r) {
        const u = (await rest(`apartamentos?select=edificio,planta,puerta,parking,propio&id=eq.${enc(f.id)}&limit=1`))?.[0];
        if (u) Object.assign(f, { edificio: u.edificio, planta: u.planta, puerta: u.puerta, plaza_parking: u.parking, de_loto: u.propio });
      }
      return r;
    }
    case "disponibilidad": {
      const pisos = await rpc("rec_disponibles", { p_k: k, p_desde: i.llegada, p_hasta: i.salida, p_personas: i.personas });
      const sync = (await rest("estancias?select=actualizado&order=actualizado.desc&limit=1"))?.[0]?.actualizado ?? null;
      const min = sync ? Math.round((Date.now() - new Date(sync).getTime()) / 60000) : null;
      return { pisos, datos_icnea_hace_minutos: min, aviso: min == null || min > 20 ? "Datos de ICNEA antiguos: di que lo confirme en el calendario de ICNEA antes de dar el piso." : "Datos de ICNEA recientes." };
    }
    case "estado_pisos": {
      const p = await rpc("rec_panel", { p_k: k, p_fecha: i.fecha ?? null });
      let pisos = p.pisos;
      if (i.apartamento) pisos = pisos.filter((x: any) => x.apartamento.toLowerCase().includes(String(i.apartamento).toLowerCase()));
      return { fecha: p.fecha, ultima_sincronizacion_icnea: p.ultima_sync, pisos, llegadas_manana: p.llegadas_manana };
    }
    case "parte_nieve_carretera": {
      let texto = "";
      try {
        const r = await fetch("https://sierranevada.es/es/", { headers: { "user-agent": "Mozilla/5.0" } });
        const h = await r.text();
        texto = h.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, " ").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").slice(0, 3500);
      } catch { texto = "No he podido leer la web de Sierra Nevada ahora."; }
      return { web_sierra_nevada: texto, enlaces: { estacion: "https://sierranevada.es/es/", carreteras_dgt: "https://infocar.dgt.es/etraffic/", dgt_telefono: "011", aemet: "https://www.aemet.es/es/eltiempo/prediccion/montana?w=1&p=nev1" } };
    }
    case "proponer_reserva": {
      const id = await apto(i.apartamento);
      const p = { ...i, apartamento: id ?? i.apartamento };
      propuestas.push(p);
      return { ok: true, nota: "Ficha preparada. El recepcionista debe revisarla y pulsar «Cerrar reserva». Faltan datos si no hay nombre, email o teléfono." };
    }
    case "crear_parte": {
      const id = await apto(i.apartamento);
      if (!id) return { error: "Apartamento no encontrado" };
      const n = await rpc("rec_parte", { p_k: k, p_apartamento: id, p_descripcion: i.descripcion, p_urgente: !!i.urgente });
      return { ok: true, parte: n };
    }
    case "avisar_equipo": {
      const id = await rpc("rec_nota", { p_k: k, p_texto: `📲 WhatsApp para ${i.para}: ${i.mensaje}`, p_apartamento: i.apartamento ?? null, p_para: i.para === "Sete" || i.para === "Santi" ? i.para : "Claude", p_importante: true });
      await rest(`rec_notas?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ tipo: "whatsapp" }) });
      return { ok: true, aviso: `Mensaje apuntado. Claude se lo envía por WhatsApp a ${i.para} en 1-2 minutos y lo marcará como enviado en Traspaso.` };
    }
    case "nota_traspaso": {
      const n = await rpc("rec_nota", { p_k: k, p_texto: i.texto, p_apartamento: i.apartamento ?? null, p_para: null, p_importante: !!i.importante });
      return { ok: true, nota: n };
    }
  }
  return { error: "herramienta desconocida" };
}

const SISTEMA = (yo: string, hoy: string) => `Eres el asistente de recepción de Loto Group (apartamentos turísticos en Sierra Nevada, Pradollano). Hablas con ${yo}, recepcionista, que muchas veces está al teléfono con un cliente: responde en español, MUY corto y directo, primero el dato que necesita (sí/no, lista de pisos con precio), luego lo mínimo. Hoy es ${hoy} (hora de Madrid).

Usa SIEMPRE las herramientas antes de afirmar algo sobre un apartamento, disponibilidad, limpieza o normas. Si la información no está, dilo claramente («no lo tengo registrado») y sugiere preguntar a Chio; nunca inventes.

Reglas que no se rompen:
- Cada vez que nombres un apartamento di SIEMPRE dónde está: edificio (Alpes 1 = P1, Alpes 2 = P2, Alpes 3 = P3, Galatinos, Atlas abajo en la plaza, Montaire, Alcazaba, Slalom, Montreal…), planta y puerta (p. ej. «Valle · Alpes 2, 1º K»). Saca esos datos de ficha_apartamento o de disponibilidad (edificio, planta, puerta). Wifi: está en el campo wifi_datos de la ficha.\n- Capacidad: pisos de propietarios, nunca más personas que las plazas de la Junta (plazas_junta). Pisos de Loto en reserva directa: hasta 1 persona más que la Junta (campo duermen de disponibilidad), dicho solo de palabra; en ICNEA se apuntan siempre las plazas de la Junta. Di siempre las camas reales del piso.
- Al ofrecer pisos libres: primero los de Loto (de LUX a 3ª), luego los de propietarios de LUX/1ª/2ª, y los de 3ª (Blessed, Sunny, Terralta, Queen) solo si no queda otra. Da siempre el precio total si está; si no hay tarifa cargada, dilo («precio: consultar a Chio/ICNEA»).
- Precios (también de más de 7 noches), excepciones y reembolsos: los decide el recepcionista (Sete/Santi) con su criterio; ayúdale con los datos. Foto de Booking con precio → 10 % de descuento sobre ese total si reserva directo.
- Para cerrar reserva se pide: nombre completo, email, teléfono y número de huéspedes. NUNCA el DNI. Sin email no hay reserva.
- Check-in 17:00, check-out 11:00. Entrada antes / salida tarde sin coste según limpieza del día.
- Cancelaciones fuera de 30 días: primero NO. Reembolsos, compensaciones y excepciones: los decide el recepcionista.
- Recomendar siempre cadenas; nosotros no salimos a ayudar en carretera. «Cerca de la plaza» = solo Atlas.
- Nunca des códigos de cajetín, parking, teléfonos del equipo, IBAN ni nada de propietarios. Las claves wifi SÍ se pueden dar (Chio 26/11).
- Disponibilidad: usa SIEMPRE la herramienta disponibilidad para las fechas exactas que te pidan, justo antes de responder (nunca de memoria ni de una respuesta anterior). Di siempre de hace cuántos minutos son los datos de ICNEA; si son de hace más de 20 min, avisa de que lo confirme en el calendario de ICNEA antes de dar el piso al cliente.
- Actúas como Chio, la responsable: todo lo que ella ha enseñado está en buscar_conocimiento y buscar_documentos. Ante un «¿cómo hago…?» busca SIEMPRE en los dos antes de responder y da los pasos numerados. Las reglas más recientes (fecha más nueva) mandan sobre las antiguas.
- Pagos de reservas directas: SIEMPRE a la cuenta de Santander de Loto Nevada SL, plazo 72 h; al recibir la captura se registra en ICNEA (Transacciones → Añadir pago, concepto PAGO SANTANDER). Sin pago a las 72 h y sin respuesta tras llamar: el recepcionista cancela y abre fechas.
- Si te corrigen o te enseñan algo nuevo, confírmalo en una frase y guárdalo con guardar_conocimiento. Así aprendemos todos.
- Si no lo sabes, NO inventes: pregunta al recepcionista, y si tampoco lo sabe, usa consultar_a_chio.
- Si piden hablar con Chio o con alguien del equipo, o pasarle un recado («dile a Chio…», «dile a Yudi…»), usa avisar_equipo con el mensaje ya redactado y muestra en tu respuesta el texto exacto que se va a enviar y a quién. No preguntes si quiere añadir algo: envíalo con lo que haya dicho.
- Wifi / internet: busca SIEMPRE en buscar_conocimiento con «wifi». Muchos pisos reciben el wifi del router de otro piso (p. ej. Sol ← Luna); explica de qué piso viene el router y que, si hay que tocarlo, hay que coordinarlo con el cliente de ese piso. Las claves wifi sí se pueden dar; si no las tienes registradas, di que están en las instrucciones de llegada del piso en ICNEA o pídeselas a Claude con avisar_equipo.
- Si piden una factura para un cliente, recoge cliente, reserva y datos fiscales que tengan y usa pedir_factura.
- Cuando el recepcionista diga que ha cerrado con el cliente, usa proponer_reserva con todos los datos que tengas; la reserva se crea al pulsar el botón.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { k, pregunta, historial } = await req.json();
    if (!k || !pregunta) return json({ error: "faltan_datos" }, 400);
    const yo = (await rest(`equipo?select=id,nombre,rol,activo&clave=eq.${enc(k)}&limit=1`))?.[0];
    if (!yo || !yo.activo || yo.rol !== "recepcion") return json({ error: "enlace_no_valido" }, 403);
    if (!AK) return json({ respuesta: "⚠️ El asistente aún no está activado: falta la clave de Claude en Supabase (Chio)." });

    const hoy = new Date().toLocaleString("es-ES", { timeZone: "Europe/Madrid", dateStyle: "full", timeStyle: "short" });
    const msgs: any[] = [];
    for (const h of (historial ?? []).slice(-6)) {
      if (h.pregunta && h.respuesta) { msgs.push({ role: "user", content: h.pregunta }); msgs.push({ role: "assistant", content: h.respuesta }); }
    }
    msgs.push({ role: "user", content: String(pregunta).slice(0, 4000) });
    const propuestas: any[] = [];
    let respuesta = "";
    for (let paso = 0; paso < 6; paso++) {
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": AK, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: MODEL, max_tokens: 1200, system: SISTEMA(yo.nombre, hoy), tools, messages: msgs }),
      });
      const d = await r.json();
      if (!r.ok) throw new Error(d?.error?.message ?? "error_claude");
      msgs.push({ role: "assistant", content: d.content });
      const usos = d.content.filter((c: any) => c.type === "tool_use");
      respuesta = d.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n").trim();
      if (!usos.length || d.stop_reason !== "tool_use") break;
      const res = [];
      for (const u of usos) {
        let out;
        try { out = await runTool(u.name, u.input, k, propuestas); } catch (e) { out = { error: String((e as Error).message) }; }
        res.push({ type: "tool_result", tool_use_id: u.id, content: JSON.stringify(out).slice(0, 15000) });
      }
      msgs.push({ role: "user", content: res });
    }
    await rest("rec_chat", { method: "POST", body: JSON.stringify({ persona: yo.id, pregunta: String(pregunta).slice(0, 4000), respuesta }) }).catch(() => {});
    return json({ respuesta, propuestas });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
