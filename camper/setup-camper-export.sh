#!/usr/bin/env bash
# =============================================================================
# setup-camper-export.sh - da lanciare SU LEORASPY, come root
#
# Prepara l'esportazione di history.db verso il Home Hub:
#   - installa camper-export.py in /usr/local/bin/camper-export
#   - crea l'utente di sistema homehub-export, nel gruppo camperhub
#     (serve per leggere /var/lib/camper-hub/history.db), senza password
#   - autorizza la chiave pubblica del Home Hub con le restrizioni:
#       restrict                 niente shell, terminale, inoltri
#       from="10.8.0.1"          solo dal Home Hub attraverso la VPN
#       command="..."            puo' lanciare solo camper-export
#
# Rilanciabile: con una chiave nuova sostituisce quella vecchia.
#
# Uso:  bash setup-camper-export.sh camper-export.pub
#       (camper-export.py deve stare nella stessa cartella dello script)
# =============================================================================

set -euo pipefail

PUB=${1:-}
HERE=$(cd "$(dirname "$0")" && pwd)
U=homehub-export
H=/var/lib/homehub-export
HOMEHUB_IP=10.8.0.1

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato da root" >&2; exit 1; }
[ -n "$PUB" ] && [ -f "$PUB" ] || { echo "Uso: bash $0 camper-export.pub" >&2; exit 2; }
[ -f "$HERE/camper-export.py" ] || { echo "camper-export.py assente in $HERE" >&2; exit 1; }
getent group camperhub >/dev/null || { echo "Gruppo camperhub assente: questo e' LeoRaspy?" >&2; exit 1; }
[ -f /var/lib/camper-hub/history.db ] || { echo "history.db assente: questo e' LeoRaspy?" >&2; exit 1; }

KEY=$(awk 'NR==1 && $1=="ssh-ed25519" {print $1" "$2" "$3}' "$PUB")
[ -n "$KEY" ] || { echo "$PUB non contiene una chiave pubblica ed25519" >&2; exit 1; }

echo "--- script di esportazione"
install -m 755 -o root -g root "$HERE/camper-export.py" /usr/local/bin/camper-export
echo "    /usr/local/bin/camper-export"

echo "--- utente $U"
if ! id "$U" >/dev/null 2>&1; then
  useradd --system --home-dir "$H" --create-home --shell /bin/sh --user-group "$U"
  echo "    creato"
fi
usermod -a -G camperhub "$U"
# '*' = nessuna password valida, ma account non "bloccato" (con '!' sshd
# potrebbe rifiutare anche la chiave)
usermod -p '*' "$U"
chmod 750 "$H"
id "$U" | sed 's/^/    /'

echo "--- chiave autorizzata"
install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
printf 'restrict,from="%s",command="/usr/local/bin/camper-export" %s\n' \
  "$HOMEHUB_IP" "$KEY" > "$H/.ssh/authorized_keys"
chown "$U:$U" "$H/.ssh/authorized_keys"
chmod 600 "$H/.ssh/authorized_keys"
sed 's/^/    /' "$H/.ssh/authorized_keys" | cut -c1-110
echo "    impronta: $(ssh-keygen -lf "$H/.ssh/authorized_keys" | awk '{print $2}')"

echo "--- prova: lettura del database come $U"
su -s /bin/sh -c 'SSH_ORIGINAL_COMMAND=info /usr/local/bin/camper-export' "$U" | sed 's/^/    /'

echo "--- prova: un comando diverso deve essere rifiutato"
if su -s /bin/sh -c 'SSH_ORIGINAL_COMMAND="ls /" /usr/local/bin/camper-export' "$U" 2>&1 | sed 's/^/    /'; then :; fi

echo "--- sshd: opzioni che potrebbero escludere l'utente"
SSHD_CFG=$(sshd -T 2>/dev/null || true)
if [ -z "$SSHD_CFG" ]; then
  echo "    (sshd -T non ha risposto: controllare a mano AllowUsers/AllowGroups)"
else
  printf '%s\n' "$SSHD_CFG" | grep -i -E '^(allowusers|allowgroups|denyusers|denygroups) ' | sed 's/^/    /' \
    || echo "    nessuna AllowUsers/AllowGroups/DenyUsers/DenyGroups: ok"
  printf '%s\n' "$SSHD_CFG" | grep -i -E '^(pubkeyauthentication|authorizedkeysfile) ' | sed 's/^/    /' || true
fi
echo "Fatto."
