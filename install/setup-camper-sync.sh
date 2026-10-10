#!/usr/bin/env bash
# =============================================================================
# setup-camper-sync.sh - installa sul Home Hub la copia di history.db di Camper Hub
#
#   - crea /var/lib/homehub (database locale camper-history.db), di openhabian
#   - installa camper/camper-sync.service e .timer in /etc/systemd/system
#   - attiva il timer (quattro volte al giorno)
#
# Il servizio lancia camper/camper-sync.py direttamente dal repo
# (/home/openhabian/home-hub): dopo un git pull vale subito la versione nuova.
# Rilanciare questo script solo se cambiano i file .service o .timer.
#
# Uso:  sudo bash install/setup-camper-sync.sh
# =============================================================================

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
EXPECTED=/home/openhabian/home-hub
U=openhabian
DIR=/var/lib/homehub
KEY=/home/$U/.ssh/camper-export

[ "$REPO" = "$EXPECTED" ] || {
  echo "Il repo sta in $REPO, ma camper-sync.service usa $EXPECTED" >&2; exit 1; }

echo "--- cartella del database locale"
install -d -m 750 -o "$U" -g "$U" "$DIR"
stat -c '    %A %U:%G %n' "$DIR"

echo "--- chiave SSH di $U"
if [ -f "$KEY" ]; then
  echo "    $(ssh-keygen -lf "$KEY.pub")"
else
  echo "    ATTENZIONE: $KEY assente. Creala come $U con:"
  echo "    ssh-keygen -t ed25519 -f ~/.ssh/camper-export -N \"\" -C homehub-camper-export"
fi

echo "--- unita' systemd"
for f in camper-sync.service camper-sync.timer; do
  install -m 644 -o root -g root "$REPO/camper/$f" "/etc/systemd/system/$f"
  echo "    /etc/systemd/system/$f"
done
systemctl daemon-reload
systemctl enable --now camper-sync.timer
systemctl list-timers camper-sync.timer --no-pager | sed 's/^/    /'
echo "Fatto. Log: journalctl -u camper-sync"
