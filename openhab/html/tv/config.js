// Configurazione della pagina TV: stanze, sensori, soglie.
// La logica sta in tv.js; qui solo i dati che cambiano con la casa.
// I nomi sono quelli degli Item in openhab/items/.

window.TV_CONFIG = {
  // Scala colori delle stanze: grigio al centro, blu sotto, rosso sopra.
  temperatura: { centro: 20, freddo: 16, caldo: 24 },

  // Stanze della mappa. Per ogni misura si usa il primo Item con un valore:
  // quando arrivano le testine tado basta metterle in testa all'elenco.
  //   riscalda:  Item che vale 1 (o ON) quando la stanza chiede calore
  //   impostata: temperatura richiesta (tado)
  //   esterno:   balcone e simili (solo contorno, niente riscaldamento)
  //   transito:  ingresso, disimpegno: solo il nome
  //   area:      rettangolo sulla pianta { x, y, w, h } in unita' della pianta, oppure
  //              { rettangoli: [...], testo: {...} } per una stanza a L
  //   note:      letture di altri sensori scritte in un punto della stanza
  // Pianta ricavata dal progetto (foto del 10/10/2026), ruotata con il nord in
  // alto: balcone a est (destra), ingresso a ovest. 1 unita' = circa 1,2 cm.
  stanze: [
    { id: "camera", nome: "Camera",
      temperatura: [], umidita: [],
      area: { x: 377, y: 42, w: 298, h: 278 } },
    { id: "bagno", nome: "Bagno",
      temperatura: [], umidita: [],
      area: { x: 687, y: 42, w: 125, h: 375 } },
    { id: "disimpegno", nome: "Disimpegno", transito: true,
      area: { x: 375, y: 330, w: 307, h: 87 } },
    { id: "ingresso", nome: "Ingresso", transito: true,
      area: { x: 240, y: 427, w: 266, h: 95 } },
    // sala e angolo cottura: un solo ambiente, un termosifone con testina tado
    { id: "sala", nome: "Sala e cucina",
      temperatura: ["Tado_Sala_Temperatura", "SonoffSala_Temperatura", "SwitchBotCucina_Temperatura"],
      umidita: ["Tado_Sala_Umidita", "SonoffSala_Umidita", "SwitchBotCucina_Umidita"],
      impostata: "Tado_Sala_Impostata",
      riscalda: "Tado_Sala_Riscaldamento",
      area: { rettangoli: [{ x: 514, y: 427, w: 298, h: 283 },     // soggiorno
                           { x: 362, y: 532, w: 160, h: 221 }],    // angolo cottura
              testo: { x: 514, y: 427, w: 298, h: 283 } },
      note: [{ testo: "cucina", item: "SwitchBotCucina_Temperatura", x: 376, y: 572 }] },
    { id: "luca", nome: "Camera di Luca",
      temperatura: [], umidita: [],
      area: { x: 18, y: 543, w: 328, h: 167 } },
    { id: "balcone", nome: "Balcone", esterno: true,
      temperatura: ["SwitchBotBalcone_Temperatura"],
      umidita: ["SwitchBotBalcone_Umidita"],
      area: { x: 842, y: 15, w: 236, h: 675 } }
  ],

  // Dimensioni della pianta (unita' della pianta) e posizione della bussola.
  // pianta: null disegna le stanze come riquadri in griglia.
  pianta: { larghezza: 1090, altezza: 770, nord: [60, 70] },

  // Corrente delle batterie del camper: positiva = in carica (da verificare
  // la prima volta che il camper e' fermo senza 230 V: deve risultare "in uso").
  camperCorrentePositivaInCarica: true,

  // Avvisi in alto a destra.
  avvisi: {
    batterieSensori: [
      { item: "SwitchBotCucina_Batteria",    nome: "sensore cucina" },
      { item: "SwitchBotBalcone_Batteria",   nome: "sensore balcone" },
      { item: "Camper_LeoTemp_Batteria",     nome: "sensore LeoTemp (camper)" },
      { item: "Camper_Frigo_Batteria",       nome: "sensore frigo (camper)" },
      { item: "Camper_Allagamento_Batteria", nome: "sensore allagamento (camper)" }
    ],
    sogliaBatteriaSensore: 20,      // %
    sensoriVisti: [
      { item: "SwitchBotCucina_UltimoAnnuncio",  nome: "Sensore cucina" },
      { item: "SwitchBotBalcone_UltimoAnnuncio", nome: "Sensore balcone" }
    ],
    sensoreMuto: 30,                // minuti senza annunci Bluetooth
    camperBatteriaAttenzione: 30,   // %
    camperBatteriaCritica: 15,      // %
    camperDatiVecchi: 10            // minuti senza dati -> camper non raggiungibile
  }
};
