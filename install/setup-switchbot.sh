#!/usr/bin/env bash
# =============================================================================
# setup-switchbot.sh - installa sul Home Hub il ponte SwitchBot BLE -> MQTT
#
#   - pacchetti Debian python3-bleak e python3-paho-mqtt
#   - switchbot/switchbot-mqtt.py      -> /usr/local/lib/homehub/
#   - switchbot/switchbot.toml         -> /etc/homehub/switchbot.toml
#   - switchbot/switchbot-mqtt.service -> /etc/systemd/system/
#   - utente di sistema switchbot (gruppo bluetooth)
#   - avvia (o riavvia, se qualcosa e' cambiato) il servizio
#
# I file sostituiti vengono salvati in /var/backups/homehub-switchbot/<data>/.
# Uso:  sudo bash install/setup-switchbot.sh
# =============================================================================

set -euo pipefail
export LC_ALL=C

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/switchbot"
BK=/var/backups/homehub-switchbot/$(date +%Y%m%d-%H%M%S)

echo "--- pacchetti"
MANCANTI=()
for p in python3-bleak python3-paho-mqtt; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || MANCANTI+=("$p")
done
if [ ${#MANCANTI[@]} -gt 0 ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${MANCANTI[@]}"
fi
for p in python3-bleak python3-paho-mqtt; do
  echo "    $p $(dpkg-query -W -f='${Version}' "$p")"
done

echo "--- Bluetooth"
if ! systemctl is-active -q bluetooth; then
  echo "    ATTENZIONE: bluetooth.service non attivo" >&2
fi
if command -v bluetoothctl >/dev/null; then
  bluetoothctl show 2>/dev/null | grep -E 'Controller|Powered' | sed 's/^/    /'
fi
getent group bluetooth >/dev/null || { echo "Gruppo bluetooth assente" >&2; exit 1; }

echo "--- utente di servizio"
if ! id switchbot >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --user-group switchbot
  echo "    creato"
fi
usermod -a -G bluetooth switchbot
id switchbot | sed 's/^/    /'

echo "--- file del repo (commit $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo '?'))"
CAMBIATI=0
copia() {  # sorgente destinazione modo
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "    $2 invariato"; return 0; fi
  if [ -f "$2" ]; then mkdir -p "$BK"; cp -a "$2" "$BK/"; fi
  install -D -m "$3" -o root -g root "$1" "$2"
  CAMBIATI=1
  echo "    $2 aggiornato"
}
copia "$SRC/switchbot-mqtt.py"      /usr/local/lib/homehub/switchbot-mqtt.py 755
copia "$SRC/switchbot.toml"         /etc/homehub/switchbot.toml              644
copia "$SRC/switchbot-mqtt.service" /etc/systemd/system/switchbot-mqtt.service 644

echo "--- servizio"
systemctl daemon-reload
systemctl enable -q switchbot-mqtt
if [ "$CAMBIATI" -eq 1 ] || ! systemctl is-active -q switchbot-mqtt; then
  systemctl restart switchbot-mqtt
fi
sleep 20
systemctl is-active switchbot-mqtt | sed 's/^/    stato: /'
journalctl -u switchbot-mqtt -n 8 --no-pager -o cat | sed 's/^/    /'
[ -d "$BK" ] && echo "File sostituiti salvati in $BK"
exit 0
