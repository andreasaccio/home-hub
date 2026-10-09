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

## Regole

- Tutti i file di testo hanno fine riga LF (vedi `.gitattributes`). Gli script `.sh` si lanciano con `bash`, quindi il bit di esecuzione non è indispensabile.
- Nel repo non vanno segreti: password, token, chiavi e archivi di backup sono esclusi da `.gitignore`.
- `/etc/openhab/services/runtime.cfg` non è gestito dal repo. Contiene `org.apache.karaf.shell:sshHost = 127.0.0.1`, la console di openHAB solo locale: non riportarlo a `0.0.0.0`.
