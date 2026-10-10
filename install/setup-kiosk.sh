#!/usr/bin/env bash
# =============================================================================
# setup-kiosk.sh - mostra la pagina TV del Home Hub sull'uscita HDMI del Pi
#
#   - pacchetti Debian cage, chromium, curl (e fonts-inter se disponibile)
#   - utente di sistema kiosk (gruppi video, render, input), home /var/lib/kiosk
#   - kiosk/kiosk-browser.sh -> /usr/local/lib/homehub/
#   - kiosk/pam-kiosk        -> /etc/pam.d/kiosk
#   - kiosk/kiosk.service    -> /etc/systemd/system/  (prende il posto di tty1)
#   - uscita HDMI fissa a 1920x1080: parametro video= in /boot/firmware/cmdline.txt
#     (la TV porta l'immagine a 4K; in 4K il browser del Pi 4 sarebbe lento)
#
# La pagina e' openhab/html/tv/, copiata da deploy-openhab.sh.
# I file sostituiti vengono salvati in /var/backups/homehub-kiosk/<data>/.
# Uso:  sudo bash install/setup-kiosk.sh            installa e avvia
#       sudo bash install/setup-kiosk.sh --stop     ferma e disattiva il chiosco
# =============================================================================

set -euo pipefail
export LC_ALL=C

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }

if [ "${1:-}" = "--stop" ]; then
  systemctl disable --now kiosk.service
  systemctl start getty@tty1.service || true
  echo "Chiosco fermato e disattivato (il login testuale torna su tty1)."
  exit 0
fi

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/kiosk"
BK=/var/backups/homehub-kiosk/$(date +%Y%m%d-%H%M%S)
CMDLINE=/boot/firmware/cmdline.txt
CONFIG=/boot/firmware/config.txt
URL=http://127.0.0.1:8080/static/tv/index.html
RIAVVIO=0

echo "--- grafica del Pi"
tr -d '\0' </proc/device-tree/model 2>/dev/null | sed 's/^/    /'; echo
if ls /dev/dri/card* >/dev/null 2>&1; then
  echo "    driver KMS presente: $(cd /dev/dri && echo *)"
else
  echo "    ERRORE: /dev/dri assente. In $CONFIG serve dtoverlay=vc4-kms-v3d" >&2
  grep -nE '^\s*(dtoverlay=vc4|gpu_mem|hdmi_|disable_fw_kms)' "$CONFIG" 2>/dev/null | sed 's/^/      /' >&2
  exit 1
fi
grep -nE '^\s*(dtoverlay=vc4|gpu_mem|max_framebuffers|hdmi_)' "$CONFIG" 2>/dev/null | sed 's/^/    config.txt:/' || true

CONN=""
for s in /sys/class/drm/card*-HDMI-A-*/status; do
  [ -r "$s" ] || continue
  c=$(basename "$(dirname "$s")"); c=${c#card*-}
  st=$(cat "$s")
  echo "    $c: $st"
  [ "$st" = connected ] && [ -z "$CONN" ] && CONN=$c
done
if [ -z "$CONN" ]; then
  echo "ERRORE: nessuna TV rilevata sulle uscite HDMI. Accendi la TV (anche su un altro ingresso) e rilancia." >&2
  exit 1
fi
echo "    TV collegata a $CONN"

echo "--- pacchetti"
PKG=(cage chromium curl fonts-dejavu-core)
apt-cache show fonts-inter >/dev/null 2>&1 && PKG+=(fonts-inter)
MANCANTI=()
for p in "${PKG[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || MANCANTI+=("$p")
done
if [ ${#MANCANTI[@]} -gt 0 ]; then
  echo "    da installare: ${MANCANTI[*]} (Chromium e' grande: qualche minuto)"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${MANCANTI[@]}"
fi
for p in "${PKG[@]}"; do echo "    $p $(dpkg-query -W -f='${Version}' "$p")"; done

echo "--- utente kiosk"
if ! id kiosk >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kiosk --shell /usr/sbin/nologin --user-group kiosk
  echo "    creato"
fi
for g in video render input; do getent group "$g" >/dev/null && usermod -a -G "$g" kiosk; done
install -d -m 700 -o kiosk -g kiosk /var/lib/kiosk
id kiosk | sed 's/^/    /'

echo "--- file del repo (commit $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo '?'))"
CAMBIATI=0
copia() {  # sorgente destinazione modo
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "    $2 invariato"; return 0; fi
  if [ -f "$2" ]; then mkdir -p "$BK"; cp -a "$2" "$BK/"; fi
  install -D -m "$3" -o root -g root "$1" "$2"
  CAMBIATI=1
  echo "    $2 aggiornato"
}
copia "$SRC/kiosk-browser.sh" /usr/local/lib/homehub/kiosk-browser.sh 755
copia "$SRC/pam-kiosk"        /etc/pam.d/kiosk                        644
copia "$SRC/kiosk.service"    /etc/systemd/system/kiosk.service       644

echo "--- risoluzione HDMI (1920x1080)"
VOLUTO="video=$CONN:1920x1080@60D"
if grep -qF "$VOLUTO" "$CMDLINE"; then
  echo "    $CMDLINE gia' a posto"
else
  mkdir -p "$BK"; cp -a "$CMDLINE" "$BK/"
  # una sola riga: si tolgono eventuali video=HDMI vecchi e si aggiunge il nuovo
  sed -i -E '1 s/ ?video=HDMI-A-[0-9]+:[^ ]*//g; 1 s/[[:space:]]*$//; 1 s/$/ '"$VOLUTO"'/' "$CMDLINE"
  [ "$(wc -l <"$CMDLINE")" -le 1 ] || { cp -a "$BK/cmdline.txt" "$CMDLINE"; echo "ERRORE: cmdline.txt non e' piu' una riga, ripristinato" >&2; exit 1; }
  echo "    aggiunto $VOLUTO (prima: $BK/cmdline.txt)"
  RIAVVIO=1
fi
sed 's/^/    /' "$CMDLINE"

echo "--- pagina"
if curl -fsS -o /dev/null --max-time 5 "$URL"; then
  echo "    $URL risponde"
else
  echo "    ATTENZIONE: $URL non risponde: lancia prima sudo bash install/deploy-openhab.sh" >&2
fi

echo "--- servizio"
systemctl daemon-reload
systemctl enable -q kiosk.service
if [ "$RIAVVIO" -eq 1 ]; then
  echo "    La risoluzione vale dal prossimo avvio: sudo reboot"
else
  if [ "$CAMBIATI" -eq 1 ] || ! systemctl is-active -q kiosk.service; then systemctl restart kiosk.service; fi
  sleep 25
  systemctl is-active kiosk.service | sed 's/^/    stato: /'
  journalctl -u kiosk.service -n 12 --no-pager -o cat | sed 's/^/    /'
fi
[ -d "$BK" ] && echo "File sostituiti salvati in $BK"
exit 0
