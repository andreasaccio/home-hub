#!/usr/bin/env bash
# =============================================================================
# setup-mosquitto.sh - installa Mosquitto e applica la configurazione del repo
#
#   mosquitto/homehub.conf -> /etc/mosquitto/conf.d/homehub.conf
#   mosquitto/acl          -> /etc/mosquitto/acl
#
# Le password non stanno nel repo: /etc/mosquitto/passwd contiene solo gli
# hash e si gestisce con l'opzione --utente.
# I file sostituiti vengono salvati in /var/backups/homehub-mosquitto/<data>/.
#
# Uso:  sudo bash install/setup-mosquitto.sh                installa o aggiorna
#       sudo bash install/setup-mosquitto.sh --utente NOME  crea l'utente o ne
#                                                           cambia la password
# =============================================================================

set -euo pipefail
export LC_ALL=C

UTENTE=""
case "${1:-}" in
  "") ;;
  --utente) UTENTE=${2:-}; [ -n "$UTENTE" ] || { echo "Manca il nome utente" >&2; exit 2; } ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/mosquitto"
CONF=/etc/mosquitto/conf.d/homehub.conf
ACL=/etc/mosquitto/acl
PW=/etc/mosquitto/passwd
BK=/var/backups/homehub-mosquitto/$(date +%Y%m%d-%H%M%S)

# Mosquitto legge passwd e acl come utente mosquitto: proprietario mosquitto e
# nessun accesso per gli altri (altrimenti avvisa, e le versioni future rifiutano).
proteggi() { chown mosquitto:mosquitto "$1"; chmod 600 "$1"; }

# --- solo gestione di un utente -----------------------------------------------
if [ -n "$UTENTE" ]; then
  [ -f "$PW" ] || { echo "$PW assente: lancia prima lo script senza opzioni" >&2; exit 1; }
  grep -q "^user $UTENTE\$" "$ACL" \
    || echo "ATTENZIONE: '$UTENTE' non compare in $ACL: potra' collegarsi ma non usare nessun topic"
  echo "Password per '$UTENTE' (non viene mostrata):"
  # mosquitto_passwd, lanciato da root, vuole un file di root; il broker invece
  # lo vuole di mosquitto. Si modifica una copia temporanea e la si rimette al
  # suo posto: il file vero non cambia mai proprietario.
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  cp "$PW" "$TMP"
  if ! mosquitto_passwd "$TMP" "$UTENTE"; then
    echo "Password non modificata" >&2
    exit 1
  fi
  install -m 600 -o mosquitto -g mosquitto "$TMP" "$PW"
  systemctl reload mosquitto
  echo "Utenti con password: $(cut -d: -f1 "$PW" | paste -sd' ')"
  exit 0
fi

# --- 1. pacchetti -------------------------------------------------------------
MANCANTI=()
for p in mosquitto mosquitto-clients; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || MANCANTI+=("$p")
done
if [ ${#MANCANTI[@]} -gt 0 ]; then
  echo "--- installo ${MANCANTI[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${MANCANTI[@]}"
fi
echo "Mosquitto $(dpkg-query -W -f='${Version}' mosquitto)"

# --- 2. file del repo ---------------------------------------------------------
CAMBIATI=0
copia() {  # sorgente destinazione
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "    $2 invariato"; return 0; fi
  if [ -f "$2" ]; then mkdir -p "$BK"; cp -a "$2" "$BK/"; fi
  cp "$1" "$2"
  CAMBIATI=1
  echo "    $2 aggiornato"
}
echo "--- configurazione dal repo (commit $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo '?'))"
copia "$SRC/homehub.conf" "$CONF"; chown root:root "$CONF"; chmod 644 "$CONF"
copia "$SRC/acl" "$ACL"; proteggi "$ACL"
if [ ! -f "$PW" ]; then
  install -m 600 -o mosquitto -g mosquitto /dev/null "$PW"
  CAMBIATI=1
  echo "    $PW creato vuoto: aggiungi gli utenti con --utente"
fi
proteggi "$PW"

# --- 3. riavvio se serve ------------------------------------------------------
if [ "$CAMBIATI" -eq 1 ] || ! systemctl is-active -q mosquitto; then
  echo "--- riavvio mosquitto"
  if ! systemctl restart mosquitto; then
    journalctl -u mosquitto -n 20 --no-pager
    echo "Mosquitto non riparte. I file sostituiti sono in $BK" >&2
    exit 1
  fi
  sleep 2
fi
systemctl enable -q mosquitto

# --- 4. controlli -------------------------------------------------------------
LAN=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
LAN=${LAN:-127.0.0.1}

echo "--- porte in ascolto"
ss -ltnH '( sport = :1883 or sport = :1884 )' | awk '{print "    " $4}'

echo "--- prova sul listener locale 1884 (senza password)"
R=$( { mosquitto_sub -h 127.0.0.1 -p 1884 -t homehub/test -C 1 -W 5 & sleep 1
       mosquitto_pub -h 127.0.0.1 -p 1884 -t homehub/test -m ok; wait; } 2>&1 )
[ "$R" = "ok" ] && echo "    ok, messaggio ricevuto" || echo "    ERRORE: $R"

echo "--- prova su $LAN:1883 senza password (deve essere rifiutata)"
if OUT=$(mosquitto_pub -h "$LAN" -p 1883 -t homehub/test -m x 2>&1); then
  echo "    ERRORE: accettato senza password"
else
  echo "    rifiutato come previsto: ${OUT%%$'\n'*}"
fi

echo "--- utenti con password: $( [ -s "$PW" ] && cut -d: -f1 "$PW" | paste -sd' ' || echo nessuno )"
echo "--- utenti nell'acl:     $(awk '$1=="user"{print $2}' "$ACL" | paste -sd' ')"
echo "--- ultime righe di /var/log/mosquitto/mosquitto.log"
tail -n 4 /var/log/mosquitto/mosquitto.log 2>/dev/null | sed 's/^/    /' || true
[ -d "$BK" ] && echo "File sostituiti salvati in $BK"
exit 0
