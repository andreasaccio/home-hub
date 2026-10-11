# Home Hub

Raspberry Pi 4 `homehub` (192.168.133.251, openHABian, openHAB 5.2) a San Giovanni in Persiceto:
server OpenVPN di casa, collettore dei dati e storico delle metriche di casa e di Camper Hub.

Piano e stato dei lavori: documento di progetto `claude/home-hub-piano.md` (progetto Claude "Camper HUB").

## Struttura

| Percorso | Contenuto |
|---|---|
| `openhab/things/` | Thing di openHAB (`.things`) |
| `openhab/items/` | Item (`.items`) |
| `openhab/persistence/` | Strategie di persistenza (`.persist`) |
| `openhab/services/` | Solo i file che gestiamo noi: `addons.cfg`, `network.cfg` |
| `openhab/sitemaps/` | Pagina del Home Hub (`homehub.sitemap`); i gruppi dei grafici sono in `items/pagina.items` |
| `openhab/html/tv/` | Pagina per la TV della sala (HTML/JS, dati via REST): `config.js` ha stanze, pianta e soglie degli avvisi |
| `install/deploy-openhab.sh` | Copia `openhab/` in `/etc/openhab` sul Pi |
| `mosquitto/` | Broker MQTT: `homehub.conf` (listener) e `acl` (permessi per utente) |
| `install/setup-mosquitto.sh` | Installa Mosquitto e copia `mosquitto/` in `/etc/mosquitto`; con `--utente` crea un utente o ne cambia la password |
| `camper/` | Copia incrementale di `history.db` di Camper Hub: `camper-export.py` e `setup-camper-export.sh` (vanno su LeoRaspy), `camper-sync.py` con `.service` e `.timer` (Home Hub) |
| `install/setup-camper-sync.sh` | Installa sul Home Hub il timer di `camper-sync` e crea `/var/lib/homehub` |
| `switchbot/` | Ponte Bluetooth → MQTT per i termoigrometri SwitchBot: `switchbot-mqtt.py`, `switchbot.toml` (sensori e MAC), `.service` |
| `install/setup-switchbot.sh` | Installa pacchetti, script, configurazione e servizio `switchbot-mqtt` |
| `kiosk/` | Chiosco sulla TV: `kiosk.service` (cage + Chromium su tty1), `kiosk-browser.sh`, `pam-kiosk` |
| `install/setup-kiosk.sh` | Installa il chiosco e fissa l'uscita HDMI a 1920x1080; `--stop` lo disattiva |
| `tools/` | Script di servizio: ricognizione, backup cifrato, ripristino VPN |
| `backup/` | Backup notturno: `homehub-backup-auto.sh`, `.service`, `.timer`, `backup.conf`, chiave **pubblica** gpg `homehub-backup.pub.asc` |
| `install/setup-backup.sh` | Installa il backup notturno e prova il collegamento al Synology; `--prova` fa subito un backup |
| `system/` | Drop-in systemd installati a mano (copia di riferimento): `openvpn@server.service.d/logdir.conf` ricrea `/var/log/openvpn`, che su openHABian sta in zram e si svuota a ogni riavvio |

## Flusso di lavoro

1. Modifica sul Surface, nel repo su OneDrive, poi `git commit` e `git push`.
2. Sul Pi:
   ```bash
   cd ~/home-hub && git pull
   sudo bash install/deploy-openhab.sh --check   # mostra cosa cambierebbe
   sudo bash install/deploy-openhab.sh           # applica
   ```
   openHAB rilegge da solo i file modificati, senza riavvio.
3. Lo script salva i file sostituiti o rimossi in `/var/backups/homehub-openhab/<data>/`.
4. Per Mosquitto:
   ```bash
   sudo bash install/setup-mosquitto.sh                     # dopo ogni modifica a mosquitto/
   sudo bash install/setup-mosquitto.sh --utente <nome>     # nuovo dispositivo o cambio password
   ```
   Ogni utente deve avere le sue righe in `mosquitto/acl`, altrimenti si collega ma non vede nessun topic.
   File sostituiti in `/var/backups/homehub-mosquitto/<data>/`.

## MQTT

| Porta | Dove | Accesso |
|---|---|---|
| 1883 | LAN e VPN | utente e password, permessi da `mosquitto/acl` |
| 1884 | solo 127.0.0.1 | senza password: openHAB e prove sul Pi |

Prova dal Pi: `mosquitto_sub -h 127.0.0.1 -p 1884 -v -t '#' -W 60`.

## Pagina

- Browser: `http://192.168.133.251:8080/basicui/app?sitemap=homehub` (da casa o in VPN). Serve l'add-on Basic UI (`ui = basic` in `services/addons.cfg`): senza, Main UI risponde "Not Found".
- App openHAB per iPhone: indirizzo `http://192.168.133.251:8080`, sitemap predefinita `homehub`, utente e password vuoti (openHAB 5 rifiuta l'autenticazione Basic: con le credenziali compilate l'app riceve 401).
- Grafici dallo storico rrd4j. Per aggiungere una linea a un grafico: mettere l'Item nel gruppo `gGraf...` corrispondente.

## Pagina TV

- Indirizzo: `http://192.168.133.251:8080/static/tv/index.html` (anche da PC, in casa o in VPN);
  con `?demo` usa dati finti, con `?demo=offline` simula il camper spento.
- Sul Pi la apre il servizio `kiosk` (Chromium a schermo intero sull'HDMI). Dopo un deploy
  la pagina si ricarica da sola entro un minuto. `sudo systemctl restart kiosk` la riapre.
- Mappa: stanze e rettangoli in `openhab/html/tv/config.js`, ricavati dalla pianta di progetto
  girata di 90 gradi (nord a sinistra, est in alto). La fascia a destra e' la veranda (sul
  progetto "tettoia", chiusa e riscaldata) e il terrazzo scoperto lato bagno, piu' piccolo, con
  il sensore esterno (Item `SwitchBotBalcone_*`). Colore: grigio a 20 °C, blu sotto, rosso sopra.
  Quando arrivano le testine tado: aggiungere i loro Item in testa a `temperatura`,
  `umidita` e in `riscalda`/`impostata` della stanza.

## Backup notturno

- Ogni notte alle 4:23 `homehub-backup.service` crea l'archivio (configurazione, OpenVPN con la CA,
  openHAB con lo storico rrd4j, copia di history.db, home di openhabian) e lo cifra con la
  chiave **pubblica** gpg: il Pi puo' cifrare ma non decifrare.
- Conservazione: l'ultimo di ciascuno degli ultimi 14 giorni, 8 settimane e 12 mesi, in
  `/var/backups/homehub`, copiato con rsync via SSH su `192.168.133.194:/volume1/homehub-backup`
  (utente `homehub-backup`, solo quella cartella). Cloud Sync del Synology la carica su OneDrive.
- Esito su MQTT (`homehub/backup/status`, `last_ok`, `message`): Item `Backup_*`, pagina
  Dispositivi della sitemap, avviso sulla pagina TV se l'ultimo riuscito ha piu' di 36 ore.
- La chiave **privata** e la sua passphrase stanno solo nel password manager (e nel portachiavi
  gpg di WSL sul Surface). Mai nel repo, mai su OneDrive, mai sul Pi.
- Decifrare (sul Surface, in WSL): `gpg -o backup.tar.gz -d homehub-backup-AAAAMMGG-HHMM.tar.gz.gpg`.
  Per ripristinare la VPN si passa il `.tar.gz` a `tools/homehub-restore-vpn.sh`.
- A mano: `sudo systemctl start homehub-backup` e `journalctl -u homehub-backup -n 30`.

## Storico di Camper Hub

- Database locale: `/var/lib/homehub/camper-history.db` (tabelle `samples`, `event_log`, `bds_events`, stesse colonne di LeoRaspy). Non si cancella nulla.
- `camper-sync.timer` alle 03:17, 09:17, 15:17 e 21:17: chiede a LeoRaspy solo le righe nuove. Se il camper è offline riprova al giro dopo.
- Accesso: chiave `~/.ssh/camper-export` di openhabian, autorizzata su LeoRaspy per l'utente `homehub-export` solo da 10.8.0.1 e solo per `/usr/local/bin/camper-export`.
- Comandi:
  ```bash
  python3 ~/home-hub/camper/camper-sync.py --info   # stato remoto e locale
  python3 ~/home-hub/camper/camper-sync.py          # sincronizza subito
  journalctl -u camper-sync -n 20                   # ultime esecuzioni
  ```
- Se cambia `camper-export.py`, va reinstallato su LeoRaspy con `setup-camper-export.sh`.

## SwitchBot

- `switchbot-mqtt` (utente di sistema `switchbot`, gruppo `bluetooth`) ascolta gli annunci Bluetooth dei sensori elencati in `switchbot/switchbot.toml` e pubblica su Mosquitto locale `switchbot/<nome>/temperature|humidity|battery|rssi|status|last_seen`.
- Trovare i sensori: `sudo python3 /usr/local/lib/homehub/switchbot-mqtt.py --scan 90`.
- Dopo ogni modifica a `switchbot/`: `sudo bash install/setup-switchbot.sh`. Log: `journalctl -u switchbot-mqtt`.

## Regole

- Tutti i file di testo hanno fine riga LF (vedi `.gitattributes`). Gli script `.sh` si lanciano con `bash`, quindi il bit di esecuzione non è indispensabile.
- Nel repo non vanno segreti: password, token, chiavi e archivi di backup sono esclusi da `.gitignore`.
- Le password MQTT stanno solo sul Pi, in `/etc/mosquitto/passwd` (hash), e nel gestore di password.
- **Eccezione:** i Thing di tado (binding HomeKit) si creano dalla Inbox della UI e stanno nel jsondb di openHAB, compreso nel backup. Il binding sconsiglia i Thing da file perché gli id dei canali si conoscono solo dopo la scoperta. Nel repo c'è solo `openhab/items/tado.items`.
- `/etc/openhab/services/runtime.cfg` non è gestito dal repo. Contiene `org.apache.karaf.shell:sshHost = 127.0.0.1`, la console di openHAB solo locale: non riportarlo a `0.0.0.0`.
