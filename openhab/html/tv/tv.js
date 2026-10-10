// Pagina TV del Home Hub: legge gli stati da openHAB (REST, stessa origine) e
// lo storico di 24 ore da rrd4j. Nessuna libreria esterna.
//   stati      ogni 5 s   GET /rest/items?fields=name,state
//   storico    ogni 5 min GET /rest/persistence/items/<Item>?serviceId=rrd4j
//   pagina     se cambiano i file (deploy) si ricarica da sola
// Con ?demo usa dati finti (anteprima su qualsiasi browser, anche da file).
(function () {
  "use strict";

  var C = window.TV_CONFIG;
  var DEMO = /[?&]demo\b/.test(location.search);
  var S = {};          // stati: nome Item -> stringa
  var H = {};          // storico: nome Item -> [{t, v}]
  var okAt = 0;        // ultimo caricamento riuscito degli stati
  var failed = false;

  var STORICO = ["SwitchBotBalcone_Temperatura", "Rete_Potenza", "Rete_Energia",
                 "Camper_Batt1_Livello", "Camper_Batt2_Livello"];

  // --- utilita' ---------------------------------------------------------------
  var nf1 = new Intl.NumberFormat("it-IT", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  var nf0 = new Intl.NumberFormat("it-IT", { maximumFractionDigits: 0 });
  var nf2 = new Intl.NumberFormat("it-IT", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  var hhmm = new Intl.DateTimeFormat("it-IT", { hour: "2-digit", minute: "2-digit" });
  var giorno = new Intl.DateTimeFormat("it-IT", { weekday: "long", day: "numeric", month: "long" });

  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function str(n) { var s = S[n]; return (s == null || s === "NULL" || s === "UNDEF") ? null : s; }
  function num(n) { var s = str(n); if (s == null) return null; var v = parseFloat(s); return isFinite(v) ? v : null; }
  function on(n) { var s = str(n); return s === "ON" || s === "1" || s === "HEAT"; }
  function when(n) {
    var s = str(n); if (!s) return null;
    var d = new Date(s.replace(/([+-]\d\d)(\d\d)$/, "$1:$2"));   // +0200 -> +02:00
    return isNaN(d) ? null : d;
  }
  function primo(lista) {
    for (var i = 0; lista && i < lista.length; i++) { var v = num(lista[i]); if (v != null) return v; }
    return null;
  }
  function gradi(v) { return v == null ? "—" : nf1.format(v) + "°"; }
  function watt(v) {
    if (v == null) return { n: "—", u: "" };
    return Math.abs(v) >= 1000 ? { n: nf2.format(v / 1000), u: "kW" } : { n: nf0.format(v), u: "W" };
  }
  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }
  function svgEl(tag, attrs, parent) {
    var e = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function mezzanotte() { var d = new Date(); d.setHours(0, 0, 0, 0); return d.getTime(); }

  // --- icone (sempre accanto a un testo) --------------------------------------
  var ICON = {
    good: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#0ca30c"/><path d="M7 12.4l3.3 3.3L17.2 8.8" fill="none" stroke="#0d0d0d" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    warning: '<svg viewBox="0 0 24 24"><path d="M12 2.5L22.5 21h-21z" fill="#fab219" stroke="#fab219" stroke-width="1.5" stroke-linejoin="round"/><path d="M12 9v5.5" stroke="#0d0d0d" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="17.8" r="1.4" fill="#0d0d0d"/></svg>',
    critical: '<svg viewBox="0 0 24 24"><path d="M8 2h8l6 6v8l-6 6H8l-6-6V8z" fill="#d03b3b"/><path d="M12 7v6.5" stroke="#f0efec" stroke-width="2.4" stroke-linecap="round"/><circle cx="12" cy="17" r="1.4" fill="#f0efec"/></svg>',
    flame: '<svg viewBox="0 0 24 24"><path d="M12 2.2c.9 3.3 4.9 5.6 4.9 10.6a4.9 4.9 0 0 1-9.8 0c0-2.3 1-3.9 2.2-5 .2 1.7 1 2.8 2.1 3.3-.3-3.2-.4-5.8.6-8.9z" fill="#d95926"/></svg>'
  };
  var FLAME_PATH = "M12 2.2c.9 3.3 4.9 5.6 4.9 10.6a4.9 4.9 0 0 1-9.8 0c0-2.3 1-3.9 2.2-5 .2 1.7 1 2.8 2.1 3.3-.3-3.2-.4-5.8.6-8.9z";

  // --- colore delle stanze: divergente blu - grigio - rosso -------------------
  var NEUTRO = [0x38, 0x38, 0x35], FREDDO = [0x2a, 0x78, 0xd6], CALDO = [0xe3, 0x49, 0x48];
  function hex(c) { return "#" + c.map(function (x) { return ("0" + Math.round(x).toString(16)).slice(-2); }).join(""); }
  function colore(t) {
    var T = C.temperatura;
    var k = t >= T.centro ? clamp((t - T.centro) / (T.caldo - T.centro), 0, 1)
                          : -clamp((T.centro - t) / (T.centro - T.freddo), 0, 1);
    var polo = k >= 0 ? CALDO : FREDDO, m = Math.abs(k) * 0.7;   // max 0.7: testo chiaro sempre leggibile
    return hex(NEUTRO.map(function (x, i) { return x + (polo[i] - x) * m; }));
  }

  // --- adattamento alla finestra ------------------------------------------------
  function adatta() {
    var s = Math.min(innerWidth / 1920, innerHeight / 1080);
    $("stage").style.transform = "translate(" + (innerWidth - 1920 * s) / 2 + "px," + (innerHeight - 1080 * s) / 2 + "px) scale(" + s + ")";
  }

  // --- orologio -----------------------------------------------------------------
  function orologio() {
    var d = new Date();
    $("ora").textContent = hhmm.format(d);
    var g = giorno.format(d);
    $("data").textContent = g.charAt(0).toUpperCase() + g.slice(1);
  }

  // --- caricamento dati -----------------------------------------------------------
  function caricaStati() {
    if (DEMO) { demoStati(); okAt = Date.now(); failed = false; return Promise.resolve(); }
    return fetch("/rest/items?fields=name,state", { cache: "no-store", headers: { Accept: "application/json" } })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (a) { a.forEach(function (it) { S[it.name] = it.state; }); okAt = Date.now(); failed = false; })
      .catch(function () { failed = true; });
  }
  function caricaStorico() {
    if (DEMO) { STORICO.forEach(function (n) { H[n] = demoStorico(n); }); return Promise.resolve(); }
    return Promise.all(STORICO.map(function (n) {
      return fetch("/rest/persistence/items/" + encodeURIComponent(n) + "?serviceId=rrd4j", { cache: "no-store", headers: { Accept: "application/json" } })
        .then(function (r) { return r.ok ? r.json() : { data: [] }; })
        .then(function (j) {
          H[n] = (j.data || []).map(function (p) { return { t: +p.time, v: parseFloat(p.state) }; })
                               .filter(function (p) { return isFinite(p.v) && isFinite(p.t); })
                               .sort(function (a, b) { return a.t - b.t; });
        })
        .catch(function () { H[n] = H[n] || []; });
    }));
  }

  // --- grafico di andamento (una o due serie, 24 ore) ---------------------------
  // Linee da 2 px, velatura al 10% con una sola serie, punto finale con anello,
  // linea spezzata dove mancano dati (es. camper non raggiungibile).
  function andamento(el, serie, opt) {
    opt = opt || {};
    el.innerHTML = "";
    var W = el.clientWidth, Hh = el.clientHeight;
    if (!W || !Hh) return;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + Hh }, el);
    var t1 = Date.now(), t0 = t1 - 24 * 3600e3;
    var padT = 10, padB = 26, padR = opt.etichettaY ? 64 : 10;
    var ph = Hh - padT - padB, pw = W - padR;
    var tutti = [];
    serie.forEach(function (s) { s.pts = (s.pts || []).filter(function (p) { return p.t >= t0; }); tutti = tutti.concat(s.pts); });

    svgEl("line", { x1: 0, x2: pw, y1: padT + ph + 0.5, y2: padT + ph + 0.5, stroke: "#383835", "stroke-width": 1 }, svg);
    [["−24 h", 0, "start"], ["−12 h", pw / 2, "middle"], ["ora", pw, "end"]].forEach(function (a) {
      var t = svgEl("text", { x: a[1], y: Hh - 4, "text-anchor": a[2], "class": "ax" }, svg); t.textContent = a[0];
    });
    if (tutti.length < 2) {
      var n = svgEl("text", { x: pw / 2, y: padT + ph / 2 + 6, "text-anchor": "middle", "class": "none" }, svg);
      n.textContent = "storico in costruzione";
      return;
    }
    var lo = Infinity, hi = -Infinity;
    tutti.forEach(function (p) { lo = Math.min(lo, p.v); hi = Math.max(hi, p.v); });
    if (opt.da0) lo = Math.min(lo, 0);                       // consumi: base a zero
    var minR = opt.minRange || 1;
    if (hi - lo < minR) { var c = (hi + lo) / 2; lo = c - minR / 2; hi = c + minR / 2; }
    var pad = (hi - lo) * 0.08; lo -= pad; hi += pad;
    if (opt.da0) lo = Math.max(lo, 0);
    if (opt.limiti) {                                        // es. percentuali 0-100
      if (lo < opt.limiti[0]) { hi += opt.limiti[0] - lo; lo = opt.limiti[0]; }
      if (hi > opt.limiti[1]) { lo -= hi - opt.limiti[1]; hi = opt.limiti[1]; }
      lo = Math.max(lo, opt.limiti[0]);
    }
    function X(t) { return (t - t0) / (t1 - t0) * pw; }
    function Y(v) { return padT + (1 - (v - lo) / (hi - lo)) * ph; }
    if (opt.etichettaY) {   // valori in cima e in fondo alla scala, a destra
      svgEl("line", { x1: 0, x2: pw, y1: padT + 0.5, y2: padT + 0.5, stroke: "#2c2c2a", "stroke-width": 1 }, svg);
      [[hi, padT + 6], [lo, padT + ph + 1]].forEach(function (a) {
        var e = svgEl("text", { x: W, y: a[1], "text-anchor": "end", "class": "ax" }, svg);
        e.textContent = opt.etichettaY(a[0]);
      });
    }
    var GAP = 20 * 60e3;

    serie.forEach(function (s, si) {
      var pts = s.pts; if (!pts.length) return;
      var segs = [], cur = [];
      pts.forEach(function (p, i) {
        if (i && p.t - pts[i - 1].t > GAP) { segs.push(cur); cur = []; }
        cur.push(p);
      });
      segs.push(cur);
      segs.forEach(function (seg) {
        if (seg.length < 2) return;
        var d = seg.map(function (p, i) { return (i ? "L" : "M") + X(p.t).toFixed(1) + " " + Y(p.v).toFixed(1); }).join("");
        if (serie.length === 1) {
          svgEl("path", { d: d + "L" + X(seg[seg.length - 1].t).toFixed(1) + " " + (padT + ph) + "L" + X(seg[0].t).toFixed(1) + " " + (padT + ph) + "Z",
                          fill: s.color, "fill-opacity": 0.10, stroke: "none" }, svg);
        }
        svgEl("path", { d: d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }, svg);
      });
      var last = pts[pts.length - 1];
      if (t1 - last.t < GAP) {
        svgEl("circle", { cx: X(last.t), cy: Y(last.v), r: 5, fill: s.color, stroke: "#1a1a19", "stroke-width": 2 }, svg);
      }
    });
  }

  // --- mappa ------------------------------------------------------------------------
  function datiStanza(st) {
    return {
      t: primo(st.temperatura),
      u: primo(st.umidita),
      imp: st.impostata ? num(st.impostata) : null,
      heat: st.riscalda ? on(st.riscalda) : false,
      haRisc: !!st.riscalda
    };
  }

  // Testi della stanza nel suo rettangolo b = {x, y, w, h} (unita' della pianta).
  // k = unita' della pianta per pixel: i testi restano della stessa misura sullo
  // schermo. Le stanze strette (bagno, cucina) hanno una disposizione compatta.
  function largo(t, px) { return t.length * px * 0.56; }
  function testo(g, txt, x, y, px, k, cls, anchor) {
    var e = svgEl("text", { x: x, y: y, "class": cls, "font-size": px * k }, g);
    if (anchor) e.setAttribute("text-anchor", anchor);
    e.textContent = txt;
    return e;
  }
  function fiamma(g, x, y, px, k) {
    svgEl("path", { d: FLAME_PATH, fill: "#d95926", transform: "translate(" + x + "," + y + ") scale(" + (px * k / 24) + ")" }, g);
  }
  function testiStanza(g, st, d, b, k) {
    var wpx = b.w / k, hpx = b.h / k, ampio = wpx >= 200;
    var pad = ampio ? 22 : 12, avail = wpx - 2 * pad;
    var x = b.x + pad * k, fN = ampio ? 26 : 22;
    var y = b.y + (pad + fN) * k;
    testo(g, st.nome, x, y, st.transito ? 22 : fN, k, st.transito ? "room-none" : "room-name");
    if (st.transito) return;
    if (d.t == null) {
      if (largo("nessun sensore", 20) <= avail) testo(g, "nessun sensore", x, y + 32 * k, 20, k, "room-none");
      else { testo(g, "nessun", x, y + 30 * k, 20, k, "room-none"); testo(g, "sensore", x, y + 54 * k, 20, k, "room-none"); }
      return;
    }
    var heatRiga = false;   // fiamma: in alto a destra, o in una riga sotto, o accanto al nome
    if (d.heat) {
      if (ampio && largo(st.nome, fN) + 150 <= avail) {
        testo(g, "riscalda", b.x + b.w - pad * k, y, 22, k, "room-heat", "end");
        fiamma(g, b.x + b.w - (pad + 92 + 34) * k, y - 23 * k, 28, k);
      } else if (ampio) heatRiga = true;
      else fiamma(g, x + (largo(st.nome, fN) + 8) * k, y - 22 * k, 26, k);
    }
    var fT = Math.max(32, Math.min(64, avail / 2.7));
    y += (fT + 6) * k;
    testo(g, gradi(d.t), x, y, fT, k, "room-temp");
    var righe = [];
    if (d.u != null) righe.push(["umidità " + nf0.format(d.u) + " %", nf0.format(d.u) + " %"]);
    if (d.imp != null) righe.push(["richiesta " + gradi(d.imp), "→ " + gradi(d.imp)]);
    var fS = ampio ? 22 : 20;
    if (ampio && righe.length === 2 && largo(righe[0][0] + " · " + righe[1][0], fS) <= avail) righe = [[righe[0][0] + " · " + righe[1][0]]];
    righe.forEach(function (r) {
      var t = largo(r[0], fS) <= avail ? r[0] : r[r.length - 1];
      if ((y - b.y) / k + fS + 12 > hpx) return;
      y += (fS + 10) * k;
      testo(g, t, x, y, fS, k, "room-sub");
    });
    if (heatRiga && (y - b.y) / k + 50 <= hpx) {
      y += 40 * k;
      fiamma(g, x, y - 23 * k, 28, k);
      testo(g, "riscalda", x + 34 * k, y, 22, k, "room-heat");
    }
  }

  // b: rettangolo, oppure { rettangoli: [...], testo: {...} } per le stanze a L
  // (rettangoli sovrapposti dello stesso colore: angoli esterni arrotondati).
  function stanza(svg, st, b, k) {
    var d = datiStanza(st), g = svgEl("g", {}, svg);
    var rett = b.rettangoli || [b];
    rett.forEach(function (q) {
      var r = { x: q.x, y: q.y, width: q.w, height: q.h, rx: 12 * k };
      if (st.esterno) { r.fill = "none"; r.stroke = "#4a4a46"; r["stroke-width"] = 1.5 * k; }
      else if (st.transito || d.t == null) { r.fill = "#232321"; }
      else r.fill = colore(d.t);
      svgEl("rect", r, g);
    });
    testiStanza(g, st, d, b.testo || b, k);
    (st.note || []).forEach(function (n) {   // letture di altri sensori nella stanza
      var v = num(n.item); if (v == null) return;
      testo(g, n.testo, n.x, n.y, 20, k, "room-sub");
      testo(g, gradi(v), n.x, n.y + 40 * k, 34, k, "room-name");
    });
  }

  function bussola(svg, P, k) {
    var x = P.nord[0], y = P.nord[1];
    svgEl("path", { d: "M" + x + " " + (y - 30 * k) + "L" + (x + 12 * k) + " " + (y + 4 * k) + "L" + x + " " + (y - 4 * k) + "L" + (x - 12 * k) + " " + (y + 4 * k) + "Z", fill: "#c3c2b7" }, svg);
    testo(svg, "N", x, y + 30 * k, 22, k, "room-sub", "middle");
  }

  function mappa() {
    var el = $("pianta"), W = el.clientWidth, Hh = el.clientHeight;
    if (!W || !Hh) return;
    el.innerHTML = "";
    var P = C.pianta;
    if (P) {   // pianta disegnata
      var svg = svgEl("svg", { viewBox: "0 0 " + P.larghezza + " " + P.altezza, preserveAspectRatio: "xMidYMid meet" }, el);
      var k = Math.max(P.larghezza / W, P.altezza / Hh);
      C.stanze.forEach(function (st) { if (st.area) stanza(svg, st, st.area, k); });
      if (P.nord) bussola(svg, P, k);
      return;
    }
    // senza pianta: riquadri in griglia, esterni in una fascia sotto
    var svg2 = svgEl("svg", { viewBox: "0 0 " + W + " " + Hh }, el);
    var dentro = C.stanze.filter(function (s) { return !s.esterno; });
    var fuori = C.stanze.filter(function (s) { return s.esterno; });
    var gap = 18, fascia = fuori.length ? Math.round(Hh * 0.24) : 0;
    var hIn = Hh - (fascia ? fascia + gap : 0);
    var n = dentro.length, cols = n <= 3 ? n : (n === 4 ? 2 : 3), rows = Math.ceil(n / cols) || 1;
    var cw = (W - gap * (cols - 1)) / cols, ch = (hIn - gap * (rows - 1)) / rows;
    dentro.forEach(function (st, i) {
      stanza(svg2, st, { x: (i % cols) * (cw + gap), y: Math.floor(i / cols) * (ch + gap), w: cw, h: ch }, 1);
    });
    if (fascia) {
      var fw = (W - gap * (fuori.length - 1)) / fuori.length;
      fuori.forEach(function (st, i) { stanza(svg2, st, { x: i * (fw + gap), y: hIn + gap, w: fw, h: fascia }, 1); });
    }
  }

  function legenda() {
    var T = C.temperatura, el = $("legenda");
    var stops = [];
    for (var i = 0; i <= 8; i++) { var t = T.freddo + (T.caldo - T.freddo) * i / 8; stops.push(colore(t) + " " + (i * 12.5) + "%"); }
    var ticks = "";
    for (var v = T.freddo; v <= T.caldo; v += 2) {
      ticks += '<span style="left:' + ((v - T.freddo) / (T.caldo - T.freddo) * 100) + '%">' + v + "°</span>";
    }
    el.innerHTML =
      '<div class="scala"><span>Temperatura</span><div><div class="barra" style="background:linear-gradient(90deg,' + stops.join(",") + ')"></div>' +
      '<div class="ticks">' + ticks + "</div></div></div>" +
      '<span class="voce">' + ICON.flame + "la stanza chiede calore</span>";
  }

  // --- riquadri casa ----------------------------------------------------------------
  function casa() {
    var tf = num("SwitchBotBalcone_Temperatura");
    $("fuori-v").innerHTML = tf == null ? "—" : nf1.format(tf) + "<small>°C</small>";
    var hf = (H.SwitchBotBalcone_Temperatura || []).filter(function (p) { return p.t >= Date.now() - 24 * 3600e3; });
    if (hf.length) {
      var lo = Math.min.apply(null, hf.map(function (p) { return p.v; })), hi = Math.max.apply(null, hf.map(function (p) { return p.v; }));
      $("fuori-m").textContent = "minima " + gradi(lo) + " · massima " + gradi(hi);
    } else $("fuori-m").textContent = "";
    andamento($("fuori-s"), [{ pts: hf, color: "#3987e5" }], { minRange: 3 });

    var p = watt(num("Rete_Potenza"));
    $("consumo-v").innerHTML = esc(p.n) + (p.u ? "<small>" + p.u + "</small>" : "");
    var meta = [], e = H.Rete_Energia || [], m0 = mezzanotte(), eNow = num("Rete_Energia");
    var e0 = null;
    for (var i = 0; i < e.length; i++) if (e[i].t >= m0) { e0 = e[i].v; break; }
    if (e0 != null && eNow != null && eNow >= e0) meta.push("oggi " + nf1.format(eNow - e0) + " kWh");
    var hp = (H.Rete_Potenza || []).filter(function (q) { return q.t >= Date.now() - 24 * 3600e3; });
    if (hp.length) { var mx = watt(Math.max.apply(null, hp.map(function (q) { return q.v; }))); meta.push("massimo " + mx.n + " " + mx.u); }
    $("consumo-m").textContent = meta.join(" · ");
    andamento($("consumo-s"), [{ pts: hp, color: "#3987e5" }], { da0: true, minRange: 300 });

    var cald = $("caldaia");
    if (str("Caldaia_Comando") == null) cald.innerHTML = "";
    else if (on("Caldaia_Comando")) cald.innerHTML = ICON.flame + "<span>Caldaia accesa</span>";
    else cald.innerHTML = "<span>Caldaia spenta</span>";
  }

  // --- camper --------------------------------------------------------------------------
  function camperOnline() {
    var d = when("Camper_Aggiornato");
    return { d: d, ok: !!d && (Date.now() - d.getTime()) < C.avvisi.camperDatiVecchi * 60e3 };
  }
  function batteria(i) {
    var pct = num("Camper_Batt" + i + "_Livello"), v = num("Camper_Batt" + i + "_Tensione");
    var f = $("b" + i + "-fill");
    f.style.width = (pct == null ? 0 : clamp(pct, 0, 100)) + "%";
    f.className = "fill" + (pct == null ? "" : pct < C.avvisi.camperBatteriaCritica ? " critical" : pct < C.avvisi.camperBatteriaAttenzione ? " warning" : "");
    $("b" + i + "-pct").textContent = pct == null ? "—" : nf0.format(pct) + " %";
    $("b" + i + "-v").textContent = v == null ? "—" : nf1.format(v) + " V";
  }
  function camper() {
    var o = camperOnline(), chip = $("camper-stato");
    if (o.ok) chip.innerHTML = ICON.good + "<span>collegato · dati delle " + hhmm.format(o.d) + "</span>";
    else chip.innerHTML = ICON.warning + "<span>non raggiungibile" + (o.d ? " · ultimo dato " + hhmm.format(o.d) : "") + "</span>";

    batteria(1); batteria(2);
    var a = num("Camper_Batt_Corrente"), info = [];
    if (a != null) {
      var carica = C.camperCorrentePositivaInCarica ? a : -a;
      var verso = carica > 0.2 ? "in carica" : carica < -0.2 ? "in uso" : "a riposo";
      info.push("<b>" + (a > 0 ? "+" : "") + nf1.format(a) + " A</b> " + verso);
    }
    var uso = str("Camper_Batt_InUso"); if (uso) info.push("in uso: " + esc(uso));
    var aut = str("Camper_Batt_Autonomia"); if (aut) info.push("autonomia: " + esc(aut));
    $("b-info").innerHTML = info.join(" · ");

    $("c-temp").textContent = gradi(num("Camper_Temperatura"));
    var u = num("Camper_Umidita"); $("c-umid").textContent = u == null ? "" : "umidità " + nf0.format(u) + " %";
    $("c-frigo").textContent = gradi(num("Camper_Frigo_Temperatura"));
    $("c-frigo-stato").textContent = str("Camper_Frigo_Stato") || "";
    var g = watt(num("Camper_Generale_Potenza"));
    $("c-230").textContent = g.n + (g.u ? " " + g.u : "");
    var gu = str("Camper_Generale_Uscita");
    $("c-230-sub").textContent = gu == null ? "" : (gu === "ON" ? "generale acceso" : "generale spento");
    $("c-4g").textContent = str("Camper_LTE_Segnale") || "—";
    var rsrp = num("Camper_LTE_RSRP"); $("c-4g-sub").textContent = rsrp == null ? "" : "RSRP " + nf0.format(rsrp) + " dBm";

    andamento($("camper-s"), [
      { pts: H.Camper_Batt1_Livello || [], color: "#3987e5" },
      { pts: H.Camper_Batt2_Livello || [], color: "#d95926" }
    ], { limiti: [0, 100], minRange: 25, etichettaY: function (v) { return nf0.format(v) + " %"; } });
  }

  // --- avvisi --------------------------------------------------------------------------
  function avvisi() {
    var A = C.avvisi, L = [];
    if (failed || (okAt && Date.now() - okAt > 60e3)) L.push(["critical", "openHAB non risponde"]);
    var o = camperOnline();
    if (!o.ok) L.push(["warning", "Camper non raggiungibile" + (o.d ? " dalle " + hhmm.format(o.d) : "")]);
    [1, 2].forEach(function (i) {
      var p = num("Camper_Batt" + i + "_Livello"); if (p == null) return;
      if (p < A.camperBatteriaCritica) L.push(["critical", "Camper: batteria " + i + " al " + nf0.format(p) + " %"]);
      else if (p < A.camperBatteriaAttenzione) L.push(["warning", "Camper: batteria " + i + " al " + nf0.format(p) + " %"]);
    });
    if (on("Caldaia_Comando") && str("Caldaia_RichiestaTado") === "OFF") L.push(["warning", "Caldaia forzata a mano"]);
    A.batterieSensori.forEach(function (s) {
      var v = num(s.item); if (v != null && v < A.sogliaBatteriaSensore) L.push(["warning", "Batteria " + s.nome + " al " + nf0.format(v) + " %"]);
    });
    A.sensoriVisti.forEach(function (s) {
      var d = when(s.item);
      if (d && Date.now() - d.getTime() > A.sensoreMuto * 60e3) L.push(["warning", s.nome + ": nessun dato dalle " + hhmm.format(d)]);
    });
    if (str("SonoffSala_Online") === "OFF") L.push(["warning", "Sonoff sala non collegato"]);

    var ord = { critical: 0, warning: 1 };
    L.sort(function (a, b) { return ord[a[0]] - ord[b[0]]; });
    var html = "";
    if (!L.length) html = "<li>" + ICON.good + "<span>Tutto regolare</span></li>";
    L.slice(0, 4).forEach(function (a) { html += "<li>" + ICON[a[0]] + "<span>" + esc(a[1]) + "</span></li>"; });
    if (L.length > 4) html += "<li><span>altri " + (L.length - 4) + "</span></li>";
    $("avvisi").innerHTML = html;
    $("stage").classList.toggle("stale", failed);
  }

  function disegna() { casa(); camper(); mappa(); avvisi(); }

  // --- ricarica automatica dopo un deploy ------------------------------------------------
  var firma = null;
  function controllaFile() {
    if (DEMO || location.protocol === "file:") return;
    Promise.all(["index.html", "tv.css", "tv.js", "config.js"].map(function (f) {
      return fetch(f, { method: "HEAD", cache: "no-store" }).then(function (r) {
        return (r.headers.get("last-modified") || "") + (r.headers.get("etag") || "") + (r.headers.get("content-length") || "");
      });
    })).then(function (a) {
      var f = a.join("|");
      if (firma && f !== firma) location.reload();
      firma = f;
    }).catch(function () {});
  }

  // --- dati finti per l'anteprima --------------------------------------------------------
  function demoStati() {
    var now = new Date(), min1 = new Date(now - 60e3).toISOString();
    S = {
      Tado_Sala_Temperatura: "21.3 °C", Tado_Sala_Umidita: "56 %", Tado_Sala_Impostata: "21.0 °C", Tado_Sala_Riscaldamento: "1",
      SonoffSala_Temperatura: "21.8 °C", SonoffSala_Umidita: "58 %", SonoffSala_Online: "ON",
      SwitchBotCucina_Temperatura: "22.4 °C", SwitchBotCucina_Umidita: "61 %", SwitchBotCucina_Batteria: "15 %",
      SwitchBotCucina_UltimoAnnuncio: min1,
      SwitchBotBalcone_Temperatura: "12.6 °C", SwitchBotBalcone_Umidita: "78 %", SwitchBotBalcone_Batteria: "100 %",
      SwitchBotBalcone_UltimoAnnuncio: min1,
      Caldaia_Comando: "ON", Caldaia_RichiestaTado: "ON",
      Rete_Potenza: "312 W", Rete_Energia: "11252.4 kWh",
      Camper_Aggiornato: min1,
      Camper_Batt1_Livello: "100 %", Camper_Batt1_Tensione: "14.2 V", Camper_Batt2_Livello: "100 %", Camper_Batt2_Tensione: "14.1 V",
      Camper_Batt_Corrente: "5.5 A", Camper_Batt_InUso: "Batterie 1 + 2", Camper_Batt_Autonomia: "Non disponibile",
      Camper_Temperatura: "18.4 °C", Camper_Umidita: "64 %", Camper_Frigo_Temperatura: "4.1 °C", Camper_Frigo_Stato: "Acceso",
      Camper_Generale_Potenza: "86 W", Camper_Generale_Uscita: "ON", Camper_LTE_Segnale: "Buono", Camper_LTE_RSRP: "-96",
      Camper_LeoTemp_Batteria: "88 %", Camper_Frigo_Batteria: "74 %", Camper_Allagamento_Batteria: "91 %"
    };
    if (/offline/.test(location.search)) {   // ?demo=offline: camper spento, nessun avviso in casa
      Object.keys(S).forEach(function (n) { if (n.indexOf("Camper_") === 0) S[n] = "UNDEF"; });
      S.Camper_Aggiornato = new Date(now - 3 * 3600e3).toISOString();
      S.SwitchBotCucina_Batteria = "80 %"; S.Tado_Sala_Riscaldamento = "0"; S.Caldaia_Comando = "OFF";
    }
  }
  function demoStorico(n) {
    var out = [], t1 = Date.now(), step = 4 * 60e3, kwh = 11246.0;
    for (var t = t1 - 24 * 3600e3; t <= t1; t += step) {
      var h = new Date(t).getHours() + new Date(t).getMinutes() / 60;
      var v;
      if (n === "SwitchBotBalcone_Temperatura") v = 11 + 4.5 * Math.sin((h - 9) / 24 * 2 * Math.PI) + 0.3 * Math.sin(t / 7e5);
      else if (n === "Rete_Potenza") v = 220 + 80 * Math.sin(t / 9e5) + ((h > 19 && h < 21.5) ? 1900 : 0) + ((h > 12.5 && h < 13.3) ? 1400 : 0);
      else if (n === "Rete_Energia") { kwh += 0.025; v = kwh; }
      else if (n.indexOf("Camper_Batt") === 0) {
        if (h > 3 && h < 13.2 && t < t1 - 3600e3) continue;       // buco: VPN giu'
        v = clamp(78 + (h < 3 ? -h * 2 : (h - 13) * 6) + (n.indexOf("2") > 0 ? -1.5 : 0), 0, 100);
      }
      out.push({ t: t, v: v });
    }
    return out;
  }

  // --- avvio ---------------------------------------------------------------------------
  addEventListener("resize", function () { adatta(); disegna(); });
  adatta(); orologio(); legenda();
  caricaStati().then(caricaStorico).then(disegna);
  setInterval(orologio, 5e3);
  setInterval(function () { caricaStati().then(disegna); }, 5e3);
  setInterval(function () { caricaStorico().then(disegna); }, 5 * 60e3);
  setInterval(controllaFile, 60e3); controllaFile();
  setTimeout(function () { location.reload(); }, 6 * 3600e3);   // ogni 6 ore, per sicurezza
})();
