// Configurazione della pagina TV: stanze, sensori, soglie.
// La logica sta in tv.js; qui solo i dati che cambiano con la casa.
// I nomi sono quelli degli Item in openhab/items/.

window.TV_CONFIG = {
  // Scala colori delle stanze: grigio al centro, blu sotto, rosso sopra.
  temperatura: { centro: 20, freddo: 16, caldo: 24 },

  // Stanze della mappa. Per ogni misura si usa il primo Item con un valore:
  // quando arrivano le testine tado basta metterle in testa all'elenco.
  //   riscalda:  Item (o elenco di Item, basta uno) che vale 1 (o ON) quando la stanza chiede calore
  //   impostata: temperatura richiesta (tado)
  //   esterno:   terrazzo e simili (solo contorno, niente riscaldamento)
  //   transito:  ingresso, disimpegno: solo il nome
  //   area:      rettangolo sulla pianta { x, y, w, h } in unita' della pianta, oppure
  //              { rettangoli: [...], testo: {...} } per una stanza a L
  //   note:      letture di altri sensori scritte in un punto della stanza
  //              (temperatura e, se c'e', umidita'; larghezza in unita' della pianta)
  // Pianta ricavata dal progetto (foto del 10/10/2026), girata di 90 gradi per
  // stare nello schermo: il nord e' a sinistra, l'est in alto. La fascia a destra
  // e' la veranda (sul progetto "tettoia", chiusa e riscaldata) e il terrazzo
  // scoperto, piu' piccolo, lato bagno a est. 1 unita' = circa 1,2 cm.
  stanze: [
    { id: "camera", nome: "Camera",
      temperatura: ["Tado_Camera_Temperatura"],
      umidita: ["Tado_Camera_Umidita"],
      impostata: "Tado_Camera_Impostata",
      riscalda: "Tado_Camera_Riscaldamento",
      area: { x: 377, y: 42, w: 298, h: 278 } },
    { id: "bagno", nome: "Bagno",
      temperatura: ["Tado_Bagno_Temperatura"],
      umidita: ["Tado_Bagno_Umidita"],
      impostata: "Tado_Bagno_Impostata",
      riscalda: "Tado_Bagno_Riscaldamento",
      area: { x: 687, y: 42, w: 125, h: 375 } },
    { id: "disimpegno", nome: "Disimpegno", transito: true,
      area: { x: 375, y: 330, w: 307, h: 87 } },
    { id: "ingresso", nome: "Ingresso", transito: true,
      area: { x: 240, y: 427, w: 266, h: 95 } },
    // sala e angolo cottura: un solo ambiente, un termosifone con testina tado
    { id: "sala", nome: "Sala",
      // la stanza la governa la testina (:7), come le altre; il termostato a muro (:2)
      // comanda la caldaia per tutte le zone: resta solo come riserva per la temperatura
      temperatura: ["Tado_SalaTestina_Temperatura", "Tado_Sala_Temperatura", "SonoffSala_Temperatura"],
      umidita: ["Tado_SalaTestina_Umidita", "Tado_Sala_Umidita", "SonoffSala_Umidita"],
      impostata: "Tado_SalaTestina_Impostata",
      riscalda: "Tado_SalaTestina_Riscaldamento",
      area: { rettangoli: [{ x: 514, y: 427, w: 298, h: 283 },     // soggiorno
                           { x: 362, y: 532, w: 160, h: 221 }],    // angolo cottura
              testo: { x: 514, y: 427, w: 298, h: 283 } },
      note: [{ testo: "Cucina", item: "SwitchBotCucina_Temperatura", umidita: "SwitchBotCucina_Umidita",
               x: 376, y: 572, larghezza: 158 }] },
    { id: "luca", nome: "Camera di Luca",
      temperatura: ["Tado_Luca_Temperatura"],
      umidita: ["Tado_Luca_Umidita"],
      impostata: "Tado_Luca_Impostata",
      riscalda: "Tado_Luca_Riscaldamento",
      area: { x: 18, y: 543, w: 328, h: 167 } },
    // la "tettoia" del progetto, chiusa e riscaldata: testina tado dal 12/10/2026
    { id: "veranda", nome: "Veranda",
      temperatura: ["Tado_Veranda_Temperatura"],
      umidita: ["Tado_Veranda_Umidita"],
      impostata: "Tado_Veranda_Impostata",
      riscalda: "Tado_Veranda_Riscaldamento",
      area: { x: 842, y: 178, w: 236, h: 512 } },
    // la "terrazza" del progetto: scoperta, c'e' il sensore esterno
    // (gli Item si chiamano ancora SwitchBotBalcone_*: il nome tiene lo storico)
    { id: "terrazzo", nome: "Terrazzo", esterno: true,
      temperatura: ["SwitchBotBalcone_Temperatura"],
      umidita: ["SwitchBotBalcone_Umidita"],
      area: { x: 842, y: 15, w: 236, h: 155 } }
  ],

  // Dimensioni della pianta (unita' della pianta) e bussola: posizione e
  // direzione del nord in gradi (0 = in alto, -90 = a sinistra).
  // pianta: null disegna le stanze come riquadri in griglia.
  pianta: { larghezza: 1090, altezza: 770, nord: { x: 90, y: 80, angolo: -90 } },

  // Corrente delle batterie del camper: positiva = in carica (da verificare
  // la prima volta che il camper e' fermo senza 230 V: deve risultare "in uso").
  camperCorrentePositivaInCarica: true,

  // Avvisi in alto a destra.
  avvisi: {
    batterieSensori: [
      { item: "SwitchBotCucina_Batteria",    nome: "sensore cucina" },
      { item: "SwitchBotBalcone_Batteria",   nome: "sensore terrazzo" },
      { item: "Camper_LeoTemp_Batteria",     nome: "sensore LeoTemp (camper)" },
      { item: "Camper_Frigo_Batteria",       nome: "sensore frigo (camper)" },
      { item: "Camper_Allagamento_Batteria", nome: "sensore allagamento (camper)" }
    ],
    sogliaBatteriaSensore: 20,      // %
    sensoriVisti: [
      { item: "SwitchBotCucina_UltimoAnnuncio",  nome: "Sensore cucina" },
      { item: "SwitchBotBalcone_UltimoAnnuncio", nome: "Sensore terrazzo" }
    ],
    sensoreMuto: 30,                // minuti senza annunci Bluetooth
    camperBatteriaAttenzione: 30,   // %
    camperBatteriaCritica: 15,      // %
    camperDatiVecchi: 10,           // minuti senza dati -> camper non raggiungibile
    backupOre: 36                   // ore dall'ultimo backup riuscito prima dell'avviso
  }
};
