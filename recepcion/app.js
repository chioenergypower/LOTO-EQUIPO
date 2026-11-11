// Panel de recepción de Loto. Entra con usuario, contraseña y segundo paso (Supabase Auth).
// No usa enlaces personales ni librerías de terceros. Todo el texto que se pinta pasa por esc().
(function () {
  "use strict";
  var CFG = window.LOTO, DEMO = /[?&]demo=1(&|$)/.test(location.search);
  var S = null, D = null, B = null, TAB = "hoy", MOD = false, BUSY = false, FACTOR = null, CONV = null, relojSesion = null;
  var DAY = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
  var MON = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
  var EST = { libre: "Libre", ocupado: "Ocupado", entra: "Entra hoy", sale: "Sale hoy", sale_entra: "Sale y entra", cerrado: "Cerrado" };
  var TIPO = { "salida-entrada": "Salida + entrada", salida: "Salida", entrada: "Entrada", activar: "Activar", apagar: "Solo apagar", obra: "Limpieza de obra" };
  var CANAL = { whatsapp: "WhatsApp", booking: "Booking", airbnb: "Airbnb", correo: "Correo" };
  var ERR = { sin_sesion: "Tu sesión ha caducado. Vuelve a entrar.", falta_segundo_paso: "Falta el código del segundo paso.",
    sin_permiso: "Esta cuenta no está dada de alta en recepción. Habla con administración.", solo_administracion: "Esto solo lo puede hacer administración." };

  function $(i) { return document.getElementById(i); }
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function toast(m) { var t = $("toast"); t.textContent = m; t.classList.add("show"); clearTimeout(toast.t); toast.t = setTimeout(function () { t.classList.remove("show"); }, 3200); }
  function hm(ts) { return ts ? new Date(ts).toLocaleTimeString("es-ES", { hour: "2-digit", minute: "2-digit" }) : ""; }
  function dm(ts) { var d = new Date(ts); return d.getDate() + " " + MON[d.getMonth()].slice(0, 3) + " " + hm(ts); }
  function fecha(iso) { var d = new Date(iso + "T12:00:00"); return DAY[d.getDay()] + " " + d.getDate() + " de " + MON[d.getMonth()]; }

  // ───────── sesión ─────────
  function guardar(s) {
    S = s ? { access_token: s.access_token, refresh_token: s.refresh_token, caduca: Date.now() + (s.expires_in || 3600) * 1000 } : null;
    try { if (S) sessionStorage.setItem("loto_rec", JSON.stringify(S)); else sessionStorage.removeItem("loto_rec"); } catch (e) {}
    clearTimeout(relojSesion);
    if (S) relojSesion = setTimeout(renovar, Math.max(30000, S.caduca - Date.now() - 300000));
  }
  async function llamar(base, ruta, cuerpo, metodo) {
    var h = { apikey: CFG.anon, "Content-Type": "application/json" };
    if (S) h.Authorization = "Bearer " + S.access_token;
    var r;
    try { r = await fetch(CFG.url + base + ruta, { method: metodo || "POST", headers: h, body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) }); }
    catch (e) { var er = new Error("sin_conexion"); er.codigo = "sin_conexion"; throw er; }
    var t = await r.text(), j = null;
    try { j = t ? JSON.parse(t) : null; } catch (e) {}
    if (r.ok) return j;
    var err = new Error((j && (j.message || j.msg || j.error_description || j.error)) || "error");
    err.codigo = (j && (j.message || j.error_code || j.msg)) || "error"; err.estado = r.status; throw err;
  }
  function auth(ruta, cuerpo, metodo) { return llamar("/auth/v1", ruta, cuerpo, metodo); }
  function rpc(fn, args) { return llamar("/rest/v1/rpc/", fn, args || {}); }
  async function renovar() {
    if (!S) return;
    try { var viejo = S; S = null; guardar(await auth("/token?grant_type=refresh_token", { refresh_token: viejo.refresh_token })); }
    catch (e) { salir("Tu sesión ha caducado. Vuelve a entrar."); }
  }
  function paso(id) { ["pLogin", "pAlta", "pCod", "pEspera"].forEach(function (p) { $(p).hidden = p !== id; }); $("gate").hidden = false; $("app").hidden = true; }
  async function salir(aviso) {
    if (S && !DEMO) { try { await auth("/logout", {}); } catch (e) {} }
    guardar(null); D = null; B = null; CONV = null; FACTOR = null;
    $("iPass").value = ""; $("iCod").value = ""; $("iAlta").value = ""; $("eLogin").textContent = aviso || "";
    paso("pLogin");
  }

  async function entrar() {
    var mail = $("iMail").value.trim(), pass = $("iPass").value;
    $("eLogin").textContent = "";
    if (!mail || !pass) { $("eLogin").textContent = "Escribe tu correo y tu contraseña."; return; }
    $("bLogin").disabled = true;
    try {
      guardar(await auth("/token?grant_type=password", { email: mail, password: pass }));
      $("iPass").value = "";
      await segundoPaso();
    } catch (e) {
      guardar(null);
      $("eLogin").textContent = e.codigo === "sin_conexion" ? "No hay conexión. Inténtalo otra vez." : "Correo o contraseña incorrectos.";
    }
    $("bLogin").disabled = false;
  }
  // ¿Tiene ya el segundo paso activado? Si sí, se pide el código. Si no, se da de alta ahora.
  async function segundoPaso() {
    paso("pEspera");
    var u = await auth("/user", undefined, "GET"), fs = (u && u.factors) || [];
    var ok = fs.filter(function (f) { return f.factor_type === "totp" && f.status === "verified"; })[0];
    if (ok) { FACTOR = ok.id; $("eCod").textContent = ""; paso("pCod"); $("iCod").focus(); return; }
    for (var i = 0; i < fs.length; i++) { try { await auth("/factors/" + fs[i].id, undefined, "DELETE"); } catch (e) {} }   // altas a medias
    var alta = await auth("/factors", { factor_type: "totp", friendly_name: "Recepción " + Date.now() });
    FACTOR = alta.id; $("qr").src = alta.totp.qr_code; $("qrSec").textContent = alta.totp.secret; $("eAlta").textContent = "";
    paso("pAlta"); $("iAlta").focus();
  }
  async function verificar(campo, aviso, boton) {
    var cod = $(campo).value.replace(/\D/g, "");
    $(aviso).textContent = "";
    if (cod.length !== 6) { $(aviso).textContent = "El código tiene 6 cifras."; return; }
    $(boton).disabled = true;
    try {
      var reto = await auth("/factors/" + FACTOR + "/challenge", {});
      guardar(await auth("/factors/" + FACTOR + "/verify", { challenge_id: reto.id, code: cod }));
      $(campo).value = "";
      await cargar(false);
    } catch (e) {
      $(aviso).textContent = e.codigo === "sin_conexion" ? "No hay conexión. Inténtalo otra vez." : "Código incorrecto o caducado. Espera al siguiente y vuelve a probar.";
    }
    $(boton).disabled = false;
  }

  // ───────── datos ─────────
  async function cargar(silencio) {
    try {
      D = DEMO ? demoHoy() : await rpc("recepcion_hoy");
      if (TAB === "bandeja") B = DEMO ? demoBandeja() : await rpc("bandeja_lista");
      $("gate").hidden = true; $("app").hidden = false; $("sync").textContent = "Al día"; pintar();
    } catch (e) {
      if (e.codigo === "falta_segundo_paso") { try { await segundoPaso(); } catch (x) { salir("Vuelve a entrar."); } return; }
      if (ERR[e.codigo] || e.estado === 401) { salir(ERR[e.codigo] || ERR.sin_sesion); return; }
      if (!D) { salir("No hay conexión. Inténtalo otra vez."); return; }
      $("sync").textContent = "Sin conexión"; if (!silencio) toast("Sin conexión. Inténtalo otra vez.");
    }
  }
  async function hacer(fn, args, ok) {
    if (BUSY) return false; BUSY = true; $("sync").textContent = "Guardando…";
    try { if (!DEMO) await rpc(fn, args); if (ok) toast(DEMO ? ok + " (demostración: no se guarda)" : ok); BUSY = false; await cargar(true); return true; }
    catch (e) { BUSY = false; $("sync").textContent = "Sin guardar"; toast(ERR[e.codigo] || (e.codigo === "sin_conexion" ? "No se ha guardado: no hay conexión." : "No se ha podido guardar.")); return false; }
  }

  // ───────── pintar ─────────
  function pintar() {
    var d = new Date(D.ahora);
    $("uName").textContent = "Recepción · " + D.yo.nombre;
    $("uDate").textContent = fecha(D.hoy) + " · actualizado a las " + hm(d);
    $("demo").hidden = !DEMO;
    var sinLeer = D.mensajes.filter(function (m) { return !m.mio && !m.leido; }).length;
    var urg = D.partes.filter(function (p) { return p.urgente; }).length;
    var tabs = [["hoy", "🏠 Hoy", 0], ["limpieza", "🧹 Limpieza", 0], ["averias", "🔧 Averías", urg], ["mensajes", "💬 Equipo", sinLeer],
      ["bandeja", "📥 Clientes", D.bandeja_pendientes], ["equipo", "👥 Equipo de hoy", 0]];
    $("tabs").innerHTML = tabs.map(function (t) {
      return '<button data-tab="' + t[0] + '" class="' + (t[0] === TAB ? "on" : "") + '">' + esc(t[1]) + (t[2] ? ' <span class="pill">' + (+t[2]) + "</span>" : "") + "</button>";
    }).join("");
    $("vista").innerHTML = ({ hoy: vHoy, limpieza: vLimpieza, averias: vAverias, mensajes: vMensajes, bandeja: vBandeja, equipo: vEquipo }[TAB])();
  }
  function tile(n, l, color) { return '<div class="stt"><div class="n"' + (color ? ' style="color:var(--' + color + ')"' : "") + ">" + n + '</div><div class="l">' + esc(l) + "</div></div>"; }
  function lista(items, vacio) { return items.length ? '<ul class="il">' + items.join("") + "</ul>" : '<p class="empty">' + esc(vacio) + "</p>"; }

  function vHoy() {
    var A = D.apartamentos, por = function (s) { return A.filter(function (a) { return s.indexOf(a.estado) >= 0; }); };
    var entran = por(["entra", "sale_entra"]), salen = por(["sale", "sale_entra"]), ocu = por(["ocupado"]);
    var hechas = D.limpieza.filter(function (t) { return t.fin; }).length;
    var h = '<div class="stats">' + tile(entran.length, "Entradas", "acd") + tile(salen.length, "Salidas", "wn") + tile(ocu.length, "Ocupados", "info") +
      tile(hechas + "/" + D.limpieza.length, "Limpiezas hechas", "ok") + tile(D.partes.length, "Averías abiertas", D.partes.some(function (p) { return p.urgente; }) ? "dn" : "") +
      tile(D.bandeja_pendientes, "Clientes sin atender", D.bandeja_pendientes ? "dn" : "") + "</div>";
    h += '<div class="cols"><div class="fc"><h3>🟦 Entran hoy (' + entran.length + ")</h3>" + lista(entran.map(function (a) {
      return "<li><span><b>" + esc(a.id) + "</b><small>" + esc(a.edificio || "") + (a.estado === "sale_entra" ? " · antes sale otro cliente" : "") + '</small></span><span class="tag">' + (a.hora_entrada ? "llega " + esc(String(a.hora_entrada).slice(0, 5)) : "sin hora") + "</span></li>";
    }), "Hoy no entra nadie.") + "</div>";
    h += '<div class="fc"><h3>🟧 Salen hoy (' + salen.length + ")</h3>" + lista(salen.map(function (a) {
      var t = D.limpieza.filter(function (x) { return x.apartamento === a.id; })[0];
      return "<li><span><b>" + esc(a.id) + "</b><small>" + esc(a.edificio || "") + (a.cerrado ? " · después queda cerrado" : "") + '</small></span><span class="tag">' + (t ? (t.fin ? "limpio ✅" : t.inicio ? "limpiando" : "limpieza pendiente") : "sin limpieza hoy") + "</span></li>";
    }), "Hoy no sale nadie.") + "</div></div>";
    h += '<div class="fc"><h3>Todos los apartamentos</h3><div class="ley">' + Object.keys(EST).map(function (k) { return '<span class="s-' + k + '">' + EST[k] + " · " + por([k]).length + "</span>"; }).join("") + "</div>";
    var ed = null;
    A.forEach(function (a) {
      if (a.edificio !== ed) { if (ed !== null) h += "</div>"; ed = a.edificio; h += '<div class="sec">' + esc(ed || "Sin edificio") + '</div><div class="aps">'; }
      var det = a.estado === "ocupado" && a.hasta ? "hasta el " + esc(fecha(a.hasta).replace(/^\S+ /, "")) : a.estado === "cerrado" ? esc((a.motivo || "").slice(0, 28)) :
        (a.estado === "entra" || a.estado === "sale_entra") && a.hora_entrada ? "llega " + esc(String(a.hora_entrada).slice(0, 5)) : "";
      h += '<div class="ap s-' + a.estado + '">' + esc(a.id) + "<small>" + EST[a.estado] + (det ? " · " + det : "") + "</small></div>";
    });
    return h + (ed !== null ? "</div>" : "") + "</div>";
  }

  function vLimpieza() {
    var T = D.limpieza;
    if (!T.length) return '<div class="fc"><p class="empty">Hoy no hay limpiezas programadas.</p></div>';
    return '<div class="grid" style="margin-top:10px">' + T.map(function (t) {
      var est = t.fin ? ["ok", "Terminado " + hm(t.fin)] : t.inicio ? ["cur", "En curso desde " + hm(t.inicio)] : ["pen", "Sin empezar"];
      var falta = (t.peticiones || []).filter(function (p) { return (t.peticiones_hechas || []).indexOf(p) < 0; });
      return '<div class="apt ' + est[0] + '"><div class="apt-h"><span class="apt-n">' + esc(t.apartamento) + '</span><span class="badge b-' + est[0] + '">' + esc(est[1]) + "</span></div>" +
        '<div class="loc">📍 ' + esc(t.edificio || "") + " · " + esc(TIPO[t.tipo] || t.tipo) + (t.hora_salida ? " · sale " + esc(t.hora_salida) : "") + (t.hora_entrada ? " · entra " + esc(t.hora_entrada) : "") + "</div>" +
        '<div class="loc">👥 ' + (t.personas.length ? esc(t.personas.join(", ")) : "<b>Sin nadie asignado</b>") + "</div>" +
        ((t.peticiones || []).length ? '<div class="nt">🛏️ Peticiones: ' + esc(t.peticiones.join(", ")) + (falta.length ? " · <b>falta: " + esc(falta.join(", ")) + "</b>" : " · todo puesto ✅") + "</div>" : "") +
        (t.nota ? '<div class="nt">📝 ' + esc(t.nota) + "</div>" : "") + "</div>";
    }).join("") + "</div>";
  }

  function vAverias() {
    var h = '<button class="bsub" data-act="averia" style="max-width:420px;display:block;margin:10px auto">➕ Avisar de una avería</button>';
    if (!D.partes.length) return h + '<div class="fc"><p class="empty">🎉 No hay averías abiertas.</p></div>';
    return h + '<div class="grid">' + D.partes.map(function (p) {
      var e = p.estado === "en_curso" ? ["cur", "En curso"] : p.estado === "asignado" ? ["pen", "Asignado"] : ["pen", "Pendiente"];
      return '<div class="apt ' + (p.urgente ? "urg" : e[0]) + '"><div class="apt-h"><span class="apt-n">' + esc(p.apartamento) + '</span><span class="badge ' + (p.urgente ? "b-urg" : "b-" + e[0]) + '">' + (p.urgente ? "🔴 Urgente" : e[1]) + "</span></div>" +
        '<div class="loc">📍 ' + esc(p.edificio || "") + " · avisó " + esc(p.reporta || "—") + " · " + esc(dm(p.creado)) + (p.asignado ? " · 👷 " + esc(p.asignado) : " · sin asignar") + "</div>" +
        '<div class="desc">' + esc(p.descripcion) + "</div>" + (p.notas || []).map(function (n) { return '<div class="nt"><b>' + esc(n.por) + ":</b> " + esc(n.texto) + "</div>"; }).join("") + "</div>";
    }).join("") + "</div>";
  }

  function vMensajes() {
    var h = '<div class="cols"><div class="fc"><h3>💬 Mensajes con el equipo</h3><button class="bsub" data-act="escribir" data-para="" style="margin-bottom:12px">✏️ Escribir a alguien del equipo</button>';
    h += D.mensajes.length ? D.mensajes.map(function (m) {
      return '<div class="msg ' + (m.mio ? "out" : "in" + (m.leido ? "" : " new")) + '"><div class="h"><span>' + (m.mio ? "Recepción → " + esc(m.nombre || m.para) : esc(m.nombre || m.de)) + (m.apartamento ? " · " + esc(m.apartamento) : "") + "</span><span>" + esc(dm(m.ts)) + "</span></div>" + esc(m.texto) +
        (m.mio ? "" : '<div class="row"><button class="mini a" data-act="escribir" data-para="' + esc(m.de) + '" data-apt="' + esc(m.apartamento || "") + '">Contestar</button></div>') + "</div>";
    }).join("") : '<p class="empty">Sin mensajes todavía.</p>';
    h += '</div><div><div class="fc"><h3>🛒 Material que falta</h3>' + lista(D.material.map(function (m) {
      return "<li><span>" + esc(m.texto) + "<small>" + esc(m.persona || "") + " · " + esc(dm(m.creado)) + '</small></span><button class="mini" data-act="comprado" data-id="' + (+m.id) + '">Comprado ✅</button></li>';
    }), "No falta nada apuntado.") + '</div><div class="fc"><h3>📦 Pendiente de llevar a un apartamento</h3>' + lista(D.llevar.map(function (r) {
      return "<li><span>" + esc(r.objeto) + '</span><span class="tag">' + esc(r.apartamento) + "</span></li>";
    }), "Nada pendiente de llevar.") + "</div></div></div>";
    return h;
  }

  function vBandeja() {
    if (!B) return '<div class="fc"><p class="empty">Cargando…</p></div>';
    if (CONV) return vConversacion();
    var pen = B.filter(function (b) { return b.estado === "pendiente"; }), hechos = B.filter(function (b) { return b.estado !== "pendiente"; });
    var fila = function (b) {
      return '<li><span><b>' + esc(b.nombre || CANAL[b.canal] || b.canal) + "</b><small>" + esc(CANAL[b.canal] || b.canal) + (b.telefono ? " · +" + esc(b.telefono) : "") + " · " + esc(b.apartamento || "sin identificar") + " · " + esc(dm(b.recibido)) +
        (b.atendido_por ? " · atendió " + esc(b.atendido_por) : "") + "</small></span>" + (b.sin_leer ? '<span class="pill">' + (+b.sin_leer) + "</span>" : "") +
        '<button class="mini a" data-act="abrir" data-id="' + (+b.id) + '">Abrir</button></li>';
    };
    return '<div class="fc"><h3>📥 Clientes sin atender (' + pen.length + ")</h3>" + lista(pen.map(fila), "No hay ningún cliente esperando respuesta.") + "</div>" +
      '<div class="fc"><h3>Atendidos en los últimos 7 días</h3>' + lista(hechos.map(fila), "Nada todavía.") + "</div>";
  }
  function vConversacion() {
    var b = B.filter(function (x) { return x.id === CONV.id; })[0] || {};
    var h = '<div class="fc"><div class="row" style="justify-content:space-between;margin:0 0 10px"><button class="mini g" data-act="volver">← Volver</button>' +
      '<button class="mini' + (b.estado === "pendiente" ? "" : " g") + '" data-act="atender" data-id="' + (+CONV.id) + '" data-v="' + (b.estado === "pendiente" ? 1 : 0) + '">' + (b.estado === "pendiente" ? "Marcar atendido ✅" : "Volver a abrir") + "</button></div>" +
      "<h3>" + esc(b.nombre || "Cliente") + (b.telefono ? " · +" + esc(b.telefono) : "") + '</h3><div class="loc">' + esc(CANAL[b.canal] || "") + " · " + esc(b.apartamento || "apartamento sin identificar") + "</div>" +
      '<div class="row" style="margin-bottom:10px"><select class="fi" id="cApt" style="margin:0;flex:1"><option value="">Apartamento sin identificar</option>' + D.apartamentos.map(function (a) {
        return "<option" + (a.id === b.apartamento ? " selected" : "") + ">" + esc(a.id) + "</option>"; }).join("") + '</select><button class="mini a" data-act="asignar" data-id="' + (+CONV.id) + '">Guardar piso</button></div>';
    h += CONV.mensajes.length ? CONV.mensajes.map(function (m) {
      return '<div class="msg ' + (m.entrante ? "in" : "out") + '"><div class="h"><span>' + (m.entrante ? "Cliente" : "Recepción" + (m.por ? " · " + esc(m.por) : "")) + "</span><span>" + esc(dm(m.ts)) + (m.estado ? " · " + esc(m.estado) : "") + "</span></div>" + esc(m.texto || "") + "</div>";
    }).join("") : '<p class="empty">Sin mensajes.</p>';
    if (b.canal === "whatsapp") h += '<textarea class="fi" id="cTxt" rows="3" placeholder="Escribe la respuesta por WhatsApp…" style="margin-top:10px"></textarea><button class="bsub" data-act="responder" data-id="' + (+CONV.id) + '">Enviar por WhatsApp</button>';
    if (D.yo.admin) h += '<button class="blink" data-act="borrar" data-id="' + (+CONV.id) + '" style="color:var(--dn)">Borrar todos los datos de este cliente (si lo pide)</button>';
    return h + "</div>";
  }

  function vEquipo() {
    return '<div class="fc"><h3>👥 Equipo de hoy</h3>' + lista(D.equipo.map(function (e) {
      var est = e.fin ? ["g", "Terminó a las " + hm(e.fin)] : e.inicio ? ["", "Conectada desde las " + hm(e.inicio)] : ["g", "Sin empezar"];
      return "<li><span><b>" + esc(e.nombre) + "</b><small>" + esc(e.rol) + (e.tareas ? " · " + (+e.tareas) + (e.tareas === 1 ? " apartamento hoy" : " apartamentos hoy") : "") + '</small></span><span class="mini ' + est[0] + '">' + esc(est[1]) + "</span></li>";
    }), "Hoy no hay nadie con trabajo asignado.") + "</div>";
  }

  // ───────── ventanas ─────────
  function modal(html) { MOD = true; $("modal").hidden = false; $("modal").innerHTML = '<div class="modal-bg"><div class="modal">' + html + "</div></div>"; }
  function cerrar() { MOD = false; $("modal").hidden = true; $("modal").innerHTML = ""; }
  async function abrir(id) {
    try { CONV = { id: +id, mensajes: DEMO ? demoConv() : await rpc("conversacion", { p_bandeja: +id }) }; if (!DEMO) B = await rpc("bandeja_lista"); pintar(); window.scrollTo(0, 0); }
    catch (e) { toast(ERR[e.codigo] || "No se ha podido abrir la conversación."); }
  }
  async function responder(id) {
    var x = $("cTxt").value.trim(); if (!x) { toast("Escribe la respuesta"); return; }
    if (DEMO) { toast("Demostración: no se envía nada"); return; }
    try { await llamar("/functions/v1/", "whatsapp-enviar", { bandeja: +id, texto: x }); toast("📩 Enviado"); await abrir(id); }
    catch (e) { toast(e.estado === 404 ? "El envío por WhatsApp todavía no está activado." : (e.message && e.message !== "error" ? e.message : "No se ha podido enviar.")); }
  }

  document.addEventListener("click", async function (ev) {
    var t = ev.target.closest("[data-tab],[data-act]"); if (!t) return;
    if (t.dataset.tab) {
      TAB = t.dataset.tab; CONV = null; window.scrollTo(0, 0);
      if (TAB === "bandeja") { B = null; pintar(); await cargar(true); return; }
      pintar();
      if (TAB === "mensajes" && !DEMO && D.mensajes.some(function (m) { return !m.mio && !m.leido; })) { try { await rpc("recepcion_mensajes_leidos"); } catch (e) {} }
      return;
    }
    var a = t.dataset.act, id = t.dataset.id;
    if (a === "salir") salir();
    else if (a === "cerrar") cerrar();
    else if (a === "volver") { CONV = null; pintar(); }
    else if (a === "abrir") abrir(id);
    else if (a === "responder") responder(id);
    else if (a === "atender") { if (await hacer("bandeja_atender", { p_id: +id, p_atendido: t.dataset.v === "1" }, t.dataset.v === "1" ? "✅ Atendido" : "Reabierto")) { CONV = null; if (!DEMO) B = await rpc("bandeja_lista"); pintar(); } }
    else if (a === "asignar") { if (await hacer("bandeja_asignar", { p_id: +id, p_apartamento: $("cApt").value }, "Piso guardado") && !DEMO) { B = await rpc("bandeja_lista"); pintar(); } }
    else if (a === "borrar") modal("<h3>Borrar los datos de este cliente</h3><p style=\"font-size:13px;color:var(--mt);margin-bottom:12px\">Se borran su teléfono, su nombre y todos sus mensajes. No se puede deshacer.</p><button class=\"bsub\" data-act=\"borrarok\" data-id=\"" + (+id) + "\" style=\"background:var(--dn)\">Sí, borrar</button><button class=\"blink\" data-act=\"cerrar\">Cancelar</button>");
    else if (a === "borrarok") { cerrar(); if (await hacer("contacto_borrar", { p_bandeja: +id }, "Datos del cliente borrados")) { CONV = null; if (!DEMO) B = await rpc("bandeja_lista"); pintar(); } }
    else if (a === "comprado") hacer("recepcion_material_comprado", { p_id: +id }, "✅ Comprado");
    else if (a === "averia") modal('<h3>➕ Avería nueva</h3><label class="lb" for="mA">Apartamento</label><select class="fi" id="mA"><option value="">Elige el apartamento…</option>' + D.apartamentos.map(function (x) { return "<option>" + esc(x.id) + "</option>"; }).join("") +
      '</select><label class="lb" for="mD">Qué pasa</label><textarea class="fi" id="mD" rows="3" placeholder="Qué está roto o falla"></textarea><select class="fi" id="mU"><option value="0">Puede esperar</option><option value="1">🔴 Urgente: hay que arreglarlo hoy</option></select><button class="bsub" data-act="averiaok">Avisar a mantenimiento</button><button class="blink" data-act="cerrar">Cancelar</button>');
    else if (a === "averiaok") { var ap = $("mA").value, de = $("mD").value.trim(), ur = $("mU").value === "1"; if (!ap) { toast("Elige el apartamento"); return; } if (!de) { toast("Describe la avería"); return; } cerrar(); hacer("recepcion_incidencia", { p_apartamento: ap, p_descripcion: de, p_urgente: ur }, ur ? "🔴 Avería urgente enviada" : "🔧 Avería enviada"); }
    else if (a === "escribir") modal('<h3>💬 Mensaje al equipo</h3><label class="lb" for="mP">Para</label><select class="fi" id="mP">' + D.equipo.filter(function (e) { return e.rol !== "recepcion"; }).concat(D.mensajes.filter(function (m) { return !m.mio; }).map(function (m) { return { id: m.de, nombre: m.nombre || m.de }; }))
      .filter(function (e, i, l) { return l.map(function (x) { return x.id; }).indexOf(e.id) === i; }).map(function (e) { return '<option value="' + esc(e.id) + '"' + (e.id === t.dataset.para ? " selected" : "") + ">" + esc(e.nombre) + "</option>"; }).join("") +
      '</select><textarea class="fi" id="mT" rows="3" placeholder="Escribe el mensaje…"></textarea><button class="bsub" data-act="escribirok" data-apt="' + esc(t.dataset.apt || "") + '">Enviar</button><button class="blink" data-act="cerrar">Cancelar</button>');
    else if (a === "escribirok") { var pa = $("mP").value, tx = $("mT").value.trim(); if (!pa) { toast("Elige a quién"); return; } if (!tx) { toast("Escribe el mensaje"); return; } cerrar(); hacer("recepcion_mensaje", { p_para: pa, p_apartamento: t.dataset.apt || "", p_texto: tx }, "📩 Enviado"); }
  });
  $("bLogin").addEventListener("click", entrar);
  $("bCod").addEventListener("click", function () { verificar("iCod", "eCod", "bCod"); });
  $("bAlta").addEventListener("click", function () { verificar("iAlta", "eAlta", "bAlta"); });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Enter" || e.target.tagName === "TEXTAREA") return;
    if (e.target.id === "iMail" || e.target.id === "iPass") entrar();
    else if (e.target.id === "iCod") verificar("iCod", "eCod", "bCod");
    else if (e.target.id === "iAlta") verificar("iAlta", "eAlta", "bAlta");
  });
  setInterval(function () { if (D && !MOD && !BUSY && !CONV && document.visibilityState === "visible") cargar(true); }, 60000);
  document.addEventListener("visibilitychange", function () { if (D && document.visibilityState === "visible" && !MOD && !CONV) cargar(true); });

  // ───────── datos de ejemplo (solo con ?demo=1) ─────────
  function demoHoy() {
    var ahora = new Date(), hoy = ahora.getFullYear() + "-" + String(ahora.getMonth() + 1).padStart(2, "0") + "-" + String(ahora.getDate()).padStart(2, "0");
    var h = function (n) { return new Date(ahora.getTime() - n * 3600000).toISOString(); };
    var pisos = [["Cielo", "Alpes 1", "entra", "17:00"], ["Nieve", "Alpes 1", "ocupado"], ["Montaña", "Alpes 1", "libre"], ["Sunset", "Alpes 1", "sale"], ["Luna", "Alpes 2", "sale_entra", "18:30"],
      ["Sol", "Alpes 2", "ocupado"], ["Valle", "Alpes 2", "libre"], ["Loto", "Alpes 2", "cerrado"], ["Luz", "Alpes 3", "libre"], ["Hamsa", "Alpes 3", "entra", "16:00"],
      ["Nirvana", "Alpes 3", "ocupado"], ["Silencio", "Alpes 3", "libre"], ["Edén", "Galatinos", "ocupado"], ["Blossom", "Galatinos", "libre"], ["Shiva", "Galatinos", "sale"]];
    return { yo: { id: "laura", nombre: "Laura", admin: true }, hoy: hoy, ahora: ahora.toISOString(), bandeja_pendientes: 2,
      apartamentos: pisos.map(function (p) { return { id: p[0], edificio: p[1], estado: p[2], hora_entrada: p[3] || null, hasta: p[2] === "ocupado" ? hoy : null, motivo: p[2] === "cerrado" ? "Obra en el baño" : null, cerrado: p[2] === "cerrado" }; }),
      limpieza: [{ id: 1, apartamento: "Sunset", edificio: "Alpes 1", tipo: "salida", personas: ["Ana", "Luis"], hora_salida: "11:00", inicio: h(2), fin: h(1), peticiones: [], peticiones_hechas: [] },
        { id: 2, apartamento: "Luna", edificio: "Alpes 2", tipo: "salida-entrada", personas: ["Marta"], hora_salida: "11:00", hora_entrada: "18:30", inicio: h(0.5), fin: null, peticiones: ["Cuna", "Trona"], peticiones_hechas: ["Cuna"], nota: "Llegan con un bebé" },
        { id: 3, apartamento: "Shiva", edificio: "Galatinos", tipo: "salida", personas: [], hora_salida: "12:00", inicio: null, fin: null, peticiones: [], peticiones_hechas: [] }],
      partes: [{ id: 1, creado: h(3), apartamento: "Nieve", edificio: "Alpes 1", descripcion: "No sale agua caliente en la ducha", urgente: true, estado: "en_curso", reporta: "Ana", asignado: "Pedro", notas: [{ por: "Pedro", texto: "Voy a por el termo, vuelvo a las 13:00" }] },
        { id: 2, creado: h(30), apartamento: "Valle", edificio: "Alpes 2", descripcion: "Persiana del salón atascada", urgente: false, estado: "asignado", reporta: "Recepción (Laura)", asignado: "Pedro", notas: [] }],
      mensajes: [{ id: 3, ts: h(0.3), de: "marta", para: "recepcion", nombre: "Marta", mio: false, apartamento: "Luna", texto: "Terminado SIN poner: Trona", leido: false },
        { id: 2, ts: h(1.5), de: "recepcion", para: "ana", nombre: "Ana", mio: true, apartamento: "Sunset", texto: "El cliente sale a las 11, podéis entrar ya", leido: true },
        { id: 1, ts: h(2), de: "ana", para: "recepcion", nombre: "Ana", mio: false, apartamento: "Sunset", texto: "¿Se puede entrar ya en Sunset?", leido: true }],
      material: [{ id: 1, texto: "Lejía", persona: "Luis", creado: h(5) }, { id: 2, texto: "Papel higiénico", persona: "Ana", creado: h(26) }],
      llevar: [{ id: 1, apartamento: "Sol", objeto: "Hervidor", creado: h(20) }],
      equipo: [{ id: "marta", nombre: "Marta", rol: "limpieza", inicio: h(3), fin: null, tareas: 1 }, { id: "luis", nombre: "Luis", rol: "limpieza", inicio: h(3), fin: h(0.8), tareas: 1 },
        { id: "ana", nombre: "Ana", rol: "limpieza", inicio: h(3), fin: null, tareas: 1 }, { id: "pedro", nombre: "Pedro", rol: "mantenimiento", inicio: null, fin: null, tareas: 0 },
        { id: "laura", nombre: "Laura", rol: "recepcion", inicio: h(4), fin: null, tareas: 0 }] };
  }
  function demoBandeja() {
    var h = function (n) { return new Date(Date.now() - n * 3600000).toISOString(); };
    return [{ id: 1, canal: "whatsapp", apartamento: "Cielo", recibido: h(0.2), tipo: "mensaje", estado: "pendiente", sin_leer: 2, nombre: "Cliente de ejemplo", telefono: "34600000001" },
      { id: 2, canal: "whatsapp", apartamento: null, recibido: h(1), tipo: "mensaje", estado: "pendiente", sin_leer: 1, nombre: "Otro cliente", telefono: "34600000002" },
      { id: 3, canal: "whatsapp", apartamento: "Nieve", recibido: h(20), tipo: "mensaje", estado: "atendido", sin_leer: 0, nombre: "Cliente atendido", telefono: "34600000003", atendido_por: "Carlos", atendido_en: h(19) }];
  }
  function demoConv() {
    var h = function (n) { return new Date(Date.now() - n * 3600000).toISOString(); };
    return [{ ts: h(0.4), entrante: true, tipo: "text", texto: "Hola, ¿a qué hora podemos entrar hoy?" }, { ts: h(0.3), entrante: false, tipo: "text", texto: "Buenas tardes. A partir de las 17:00.", por: "Laura", estado: "read" },
      { ts: h(0.2), entrante: true, tipo: "text", texto: "Perfecto, ¿hay parking?" }];
  }

  // ───────── arranque ─────────
  if (DEMO) { cargar(false); }
  else {
    try { var g = JSON.parse(sessionStorage.getItem("loto_rec") || "null"); if (g && g.caduca > Date.now() + 60000) { S = g; guardar({ access_token: g.access_token, refresh_token: g.refresh_token, expires_in: (g.caduca - Date.now()) / 1000 }); } } catch (e) {}
    if (S) { paso("pEspera"); cargar(false); } else paso("pLogin");
  }
})();
