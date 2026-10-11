#!/usr/bin/env bash
# =============================================================================
# setup-backup.sh - backup notturno cifrato del Home Hub sul Synology
#
#   - pacchetti gnupg, rsync, mosquitto-clients
#   - backup/homehub-backup.pub.asc -> /etc/homehub/backup-pubkey.asc
#     (solo la chiave PUBBLICA: la privata non deve mai stare sul Pi)
#   - backup/backup.conf            -> /etc/homehub/backup.conf
#   - tools/homehub-backup.sh e backup/homehub-backup-auto.sh -> /usr/local/lib/homehub/
#   - chiave SSH /root/.ssh/homehub-backup (creata se manca) e impronta del Synology
#   - prova di collegamento al Synology; se riesce attiva homehub-backup.timer
#
# Uso:  sudo bash install/setup-backup.sh           installa e controlla
#       sudo bash install/setup-backup.sh --prova   in piu' fa subito un backup
# =============================================================================

set -euo pipefail
export LC_ALL=C

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }
PROVA=0
case "${1:-}" in --prova) PROVA=1 ;; "") ;; *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;; esac

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/backup"
BK=/var/backups/homehub-setup/$(date +%Y%m%d-%H%M%S)

echo "--- pacchetti"
MANCANTI=()
for p in gnupg rsync mosquitto-clients; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || MANCANTI+=("$p")
done
if [ ${#MANCANTI[@]} -gt 0 ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${MANCANTI[@]}"
fi
for p in gnupg rsync mosquitto-clients; do echo "    $p $(dpkg-query -W -f='${Version}' "$p")"; done

echo "--- chiave pubblica gpg"
PUB="$SRC/homehub-backup.pub.asc"
[ -s "$PUB" ] || { echo "ERRORE: manca $PUB (passo 24a: chiave creata sul Surface)" >&2; exit 1; }
if grep -q 'PRIVATE KEY' "$PUB"; then
  echo "ERRORE: $PUB contiene una chiave PRIVATA. Toglila dal repo e cambia chiave." >&2; exit 1
fi
GH=$(mktemp -d); trap 'rm -rf "$GH"' EXIT
GNUPGHOME="$GH" gpg --batch --show-keys --with-fingerprint "$PUB" 2>/dev/null | sed 's/^/    /'
GNUPGHOME="$GH" gpg --batch --with-colons --show-keys "$PUB" 2>/dev/null | awk -F: '$1=="sub" && $12 ~ /e/ {f=1} END {exit !f}' \
  || { echo "ERRORE: la chiave non ha una sottochiave di cifratura" >&2; exit 1; }

echo "--- file del repo (commit $(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo '?'))"
copia() {  # sorgente destinazione modo
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "    $2 invariato"; return 0; fi
  if [ -f "$2" ]; then mkdir -p "$BK"; cp -a "$2" "$BK/"; fi
  install -D -m "$3" -o root -g root "$1" "$2"
  echo "    $2 aggiornato"
}
copia "$PUB"                          /etc/homehub/backup-pubkey.asc              644
copia "$SRC/backup.conf"              /etc/homehub/backup.conf                    644
copia "$REPO/tools/homehub-backup.sh" /usr/local/lib/homehub/homehub-backup.sh    755
copia "$SRC/homehub-backup-auto.sh"   /usr/local/lib/homehub/homehub-backup-auto.sh 755
copia "$SRC/homehub-backup.service"   /etc/systemd/system/homehub-backup.service  644
copia "$SRC/homehub-backup.timer"     /etc/systemd/system/homehub-backup.timer    644
# shellcheck source=/dev/null
. /etc/homehub/backup.conf
install -d -m 700 "$OUTDIR"

echo "--- chiave SSH per il Synology"
install -d -m 700 /root/.ssh
if [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "homehub-backup@$(hostname)" -f "$SSH_KEY"
  echo "    creata $SSH_KEY"
fi
echo "    chiave pubblica da mettere sul Synology (authorized_keys di $NAS_USER):"
sed 's/^/      /' "$SSH_KEY.pub"

echo "--- impronta del Synology ($NAS_HOST)"
if [ ! -s "$KNOWN_HOSTS" ]; then
  ssh-keyscan -T 10 -t ed25519 "$NAS_HOST" 2>/dev/null >"$KNOWN_HOSTS.tmp" || true
  if [ -s "$KNOWN_HOSTS.tmp" ]; then mv "$KNOWN_HOSTS.tmp" "$KNOWN_HOSTS"; chmod 644 "$KNOWN_HOSTS"
  else rm -f "$KNOWN_HOSTS.tmp"; echo "    ATTENZIONE: $NAS_HOST non risponde su SSH (servizio SSH del DSM attivo?)" >&2; fi
fi
[ -s "$KNOWN_HOSTS" ] && ssh-keygen -lf "$KNOWN_HOSTS" | sed 's/^/    /'

echo "--- prova di collegamento"
systemctl daemon-reload
SSH="ssh -i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=15"
if [ -s "$KNOWN_HOSTS" ] && OUT=$(rsync --list-only -e "$SSH" "$NAS_USER@$NAS_HOST:$NAS_PATH/" 2>&1); then
  echo "    ok: $NAS_USER@$NAS_HOST:$NAS_PATH raggiungibile ($(printf '%s\n' "$OUT" | grep -c 'homehub-backup-.*\.gpg' || true) archivi presenti)"
  systemctl enable -q --now homehub-backup.timer
  systemctl list-timers homehub-backup.timer --no-pager | sed 's/^/    /'
else
  echo "    NON riuscito:" >&2
  printf '%s\n' "${OUT:-nessuna impronta del Synology}" | tail -n 5 | sed 's/^/      /' >&2
  echo "    Il timer resta spento finche' il collegamento non funziona: rilancia questo script." >&2
  exit 1
fi

if [ "$PROVA" -eq 1 ]; then
  echo "--- backup di prova (qualche minuto)"
  systemctl start homehub-backup.service || true
  journalctl -u homehub-backup -n 25 --no-pager -o cat | sed 's/^/    /'
  systemctl is-failed -q homehub-backup.service && { echo "Backup di prova NON riuscito" >&2; exit 1; }
fi
[ -d "$BK" ] && echo "File sostituiti salvati in $BK"
exit 0
