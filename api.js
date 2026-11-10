// Capa común de las webs del equipo: clave del enlace personal + llamadas a la base de datos.
(function () {
  var K = null;
  try {
    var m = /[#&]k=([A-Za-z0-9]+)/.exec(location.hash || "");
    if (m) { K = m[1]; try { localStorage.setItem("loto_k", K); } catch (e) {} }
    else { try { K = localStorage.getItem("loto_k"); } catch (e) {} }
  } catch (e) {}
  window.lotoClave = function () { return K; };
  window.lotoOlvidar = function () { try { localStorage.removeItem("loto_k"); } catch (e) {} K = null; };
  // rpc("mi_dia") o rpc("tarea", {p_id: 3, p_accion: "empezar"}). Devuelve los datos o lanza Error con .codigo
  window.rpc = async function (fn, args) {
    var body = Object.assign({ p_k: K }, args || {});
    var r;
    try {
      r = await fetch(window.LOTO.url + "/rest/v1/rpc/" + fn, {
        method: "POST",
        headers: { "Content-Type": "application/json", apikey: window.LOTO.anon },
        body: JSON.stringify(body)
      });
    } catch (e) { var er = new Error("sin_conexion"); er.codigo = "sin_conexion"; throw er; }
    if (r.ok) { var t = await r.text(); return t ? JSON.parse(t) : null; }
    var j = {}; try { j = await r.json(); } catch (e) {}
    var err = new Error(j.message || "error"); err.codigo = j.message || "error"; throw err;
  };
})();
