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
| `install/deploy-openhab.sh` | Copia `openhab/` in `/etc/openhab` sul Pi |
| `mosquitto/` | Broker MQTT: `homehub.conf` (listener) e `acl` (permessi per utente) |
| `install/setup-mosquitto.sh` | Installa Mosquitto e copia `mosquitto/` in `/etc/mosquitto`; con `--utente` crea un utente o ne cambia la password |
| `camper/` | Copia incrementale di `history.db` di Camper Hub: `camper-export.py` e `setup-camper-export.sh` (vanno su LeoRaspy), `camper-sync.py` con `.service` e `.timer` (Home Hub) |
| `install/setup-camper-sync.sh` | Installa sul Home Hub il timer di `camper-sync` e crea `/var/lib/homehub` |
| `tools/` | Script di servizio: ricognizione, backup cifrato, ripristino VPN |

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

## Regole

- Tutti i file di testo hanno fine riga LF (vedi `.gitattributes`). Gli script `.sh` si lanciano con `bash`, quindi il bit di esecuzione non è indispensabile.
- Nel repo non vanno segreti: password, token, chiavi e archivi di backup sono esclusi da `.gitignore`.
- Le password MQTT stanno solo sul Pi, in `/etc/mosquitto/passwd` (hash), e nel gestore di password.
- `/etc/openhab/services/runtime.cfg` non è gestito dal repo. Contiene `org.apache.karaf.shell:sshHost = 127.0.0.1`, la console di openHAB solo locale: non riportarlo a `0.0.0.0`.
