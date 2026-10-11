#!/usr/bin/env bash
# =============================================================================
# homehub-backup.sh - backup di configurazione del Raspberry "Home Hub"
#
# Salva:  server OpenVPN completo (config, ccd, PKI easy-rsa con chiave della CA,
#         tls-crypt), regole firewall e servizio che le ricarica, sysctl,
#         configurazione openHAB (openhab-cli backup + copia diretta),
#         openHABian, rete, SSH (chiavi host), Samba, crontab, file .ovpn,
#         storico rrd4j dei grafici, copia di history.db del camper,
#         elenco pacchetti e stato di rete.
# Non fa: niente stop di servizi, niente modifiche di configurazione.
# Output: ~/homehub-backup-<data>.tar.gz.gpg  cifrato AES256 con passphrase
#         ~/homehub-backup-<data>.manifest.txt  elenco file + sha256 (in chiaro)
#
# L'archivio contiene la chiave privata della CA OpenVPN: chi la ha puo' emettere
# certificati validi per la tua VPN. Per questo e' cifrato di default.
#
# Uso:  sudo bash homehub-backup.sh            archivio cifrato (chiede la passphrase)
#       sudo bash homehub-backup.sh --plain    archivio NON cifrato (solo per test)
#       sudo bash homehub-backup.sh --auto     senza domande, per il backup notturno:
#            cifrato con la chiave pubblica /etc/homehub/backup-pubkey.asc (si
#            decifra solo con la chiave privata, che sul Pi non c'e'), scritto in
#            /var/backups/homehub; esce con errore se qualcosa non torna.
# =============================================================================

set -u
export LC_ALL=C

PLAIN=0
AUTO=0
case "${1:-}" in
  --plain) PLAIN=1 ;;
  --auto)  AUTO=1 ;;
  "") ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo: sudo bash $0 [--plain|--auto]" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M)
PUBKEY=/etc/homehub/backup-pubkey.asc
# OWNER_HOME: home salvata nell'archivio (repo, chiavi SSH, token); DEST: dove
# finisce l'archivio. Nel backup notturno la home e' quella di openhabian.
if [ "$AUTO" -eq 1 ]; then
  [ -s "$PUBKEY" ] || { echo "Chiave pubblica assente: $PUBKEY (install/setup-backup.sh)" >&2; exit 1; }
  OWNER=root
  OWNER_HOME=$(getent passwd openhabian | cut -d: -f6)
  OWNER_HOME=${OWNER_HOME:-/home/openhabian}
  DEST=/var/backups/homehub
  install -d -m 700 "$DEST"
else
  OWNER=${SUDO_USER:-root}
  OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
  OWNER_HOME=${OWNER_HOME:-/root}
  DEST=$OWNER_HOME
fi
NAME="homehub-backup-$TS"
WORK=$(mktemp -d /var/tmp/hhbk.XXXXXX)
STAGE="$WORK/$NAME"
TARBALL="$WORK/$NAME.tar.gz"
MANIFEST="$DEST/$NAME.manifest.txt"
trap 'rm -rf "$WORK"' EXIT
umask 077
mkdir -p "$STAGE/_info"

log()  { printf '  - %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

# --- passphrase subito, cosi' poi lo script lavora da solo -------------------
if [ "$PLAIN" -eq 0 ] && [ "$AUTO" -eq 0 ]; then
  command -v gpg >/dev/null || { echo "gpg assente: installa gnupg oppure usa --plain" >&2; exit 1; }
  read -r -s -p "Passphrase per cifrare il backup: " PASS1; echo
  read -r -s -p "Ripeti la passphrase: " PASS2; echo
  [ -n "$PASS1" ] || { echo "Passphrase vuota, interrotto." >&2; exit 1; }
  [ "$PASS1" = "$PASS2" ] || { echo "Le passphrase non coincidono, interrotto." >&2; exit 1; }
  unset PASS2
fi

echo "Backup Home Hub $TS"

# --- 1. backup ufficiale openHAB ---------------------------------------------
if command -v openhab-cli >/dev/null; then
  log "openhab-cli backup"
  if openhab-cli backup "$STAGE/_info/openhab-cli-backup-$TS.zip" >"$STAGE/_info/openhab-cli-backup.log" 2>&1; then
    log "  ok ($(du -h "$STAGE/_info/openhab-cli-backup-$TS.zip" | cut -f1))"
  else
    warn "openhab-cli backup fallito (vedi _info/openhab-cli-backup.log): la copia diretta sotto copre comunque la config"
  fi
fi

# --- 2. stato del sistema in forma testuale ----------------------------------
log "stato di sistema (pacchetti, firewall, rete, servizi)"
{
  echo "# $(hostname) $TS"; uname -a; cat /etc/os-release
  tr -d '\0' </proc/device-tree/model 2>/dev/null; echo
} >"$STAGE/_info/system.txt" 2>&1
dpkg --get-selections                               >"$STAGE/_info/dpkg-selections.txt" 2>&1
dpkg -l                                             >"$STAGE/_info/dpkg-l.txt" 2>&1
iptables-save                                       >"$STAGE/_info/iptables-save.txt" 2>&1
nft list ruleset                                    >"$STAGE/_info/nft-ruleset.txt" 2>&1
{ ip -br addr; echo; ip route; echo; ip neigh; }    >"$STAGE/_info/network.txt" 2>&1
systemctl list-unit-files --state=enabled --no-pager >"$STAGE/_info/units-enabled.txt" 2>&1
sysctl net.ipv4.ip_forward                          >"$STAGE/_info/sysctl-forward.txt" 2>&1
cp -a /var/log/openvpn/status.log "$STAGE/_info/" 2>/dev/null

# --- 3. elenco dei percorsi da salvare (solo quelli esistenti) ---------------
CANDIDATES=(
  /etc/openvpn
  /etc/iptables
  /etc/systemd/system/iptables-openvpn.service
  /etc/systemd/system/openvpn@server.service.d
  /etc/sysctl.conf /etc/sysctl.d
  /etc/openhabian.conf
  /etc/default/openhab
  /etc/systemd/system/openhab.service.d
  /etc/openhab
  /var/lib/openhab/jsondb /var/lib/openhab/config /var/lib/openhab/etc /var/lib/openhab/secrets
  /etc/mosquitto
  /var/lib/homehub
  /var/lib/openhab/persistence
  /etc/homehub /root/.ssh
  /etc/systemd/system/camper-sync.service /etc/systemd/system/camper-sync.timer
  /etc/NetworkManager/system-connections
  /etc/ssh
  /etc/samba/smb.conf
  /etc/hostname /etc/hosts /etc/fstab /etc/ztab /etc/timezone
  /boot/firmware/config.txt /boot/firmware/cmdline.txt
  /etc/apt/sources.list /etc/apt/sources.list.d
  /var/spool/cron/crontabs
  /etc/cron.d
  "$OWNER_HOME"
)
# file client .ovpn generati dallo script di installazione OpenVPN
while IFS= read -r f; do CANDIDATES+=("$f"); done < <(find /root /home -maxdepth 2 -name '*.ovpn' 2>/dev/null)

PATHS=()
for p in "${CANDIDATES[@]}"; do
  [ -e "$p" ] && PATHS+=("${p#/}")
done

# --- 4. tar + verifica --------------------------------------------------------
log "archivio tar.gz (${#PATHS[@]} percorsi)"
tar -C / -czf "$TARBALL" \
    --exclude="${OWNER_HOME#/}/.cache" --exclude="${OWNER_HOME#/}/.npm" \
    --exclude="${OWNER_HOME#/}/homehub-backup-*" \
    "${PATHS[@]}" \
    -C "$WORK" "$NAME/_info" 2>"$WORK/tar.err"
rc=$?
if [ $rc -gt 1 ]; then
  echo "tar fallito (rc=$rc):" >&2; cat "$WORK/tar.err" >&2; exit 1
fi
[ -s "$WORK/tar.err" ] && { warn "avvisi di tar:"; sed 's/^/    /' "$WORK/tar.err" >&2; }

if ! tar -tzf "$TARBALL" >"$WORK/list.txt" 2>"$WORK/verify.err"; then
  echo "Verifica dell'archivio fallita:" >&2; cat "$WORK/verify.err" >&2; exit 1
fi

# controllo che i pezzi critici ci siano davvero
MISSING=0
for must in etc/openvpn/server.conf etc/openvpn/ca.crt etc/openvpn/tls-crypt.key \
            etc/openvpn/crl.pem etc/openvpn/easy-rsa/pki/private/ca.key etc/openvpn/ccd/; do
  grep -q "^$must" "$WORK/list.txt" || { warn "MANCA nell'archivio: /$must"; MISSING=1; }
done
log "verifica: $(wc -l <"$WORK/list.txt") voci, pezzi critici OpenVPN $([ $MISSING -eq 0 ] && echo presenti || echo INCOMPLETI)"
if [ "$AUTO" -eq 1 ] && [ "$MISSING" -ne 0 ]; then
  echo "Archivio incompleto: backup notturno interrotto." >&2; exit 1
fi

# --- 5. cifratura -------------------------------------------------------------
if [ "$AUTO" -eq 1 ]; then
  OUT="$DEST/$NAME.tar.gz.gpg"
  log "cifratura con la chiave pubblica"
  GH=$(mktemp -d "$WORK/gnupg.XXXXXX")   # portachiavi temporaneo: niente da conservare sul Pi
  if ! GNUPGHOME="$GH" gpg --batch --yes --quiet --trust-model always \
         --recipient-file "$PUBKEY" --encrypt -o "$OUT" "$TARBALL"; then
    rm -f "$OUT"; echo "Cifratura fallita." >&2; exit 1
  fi
  # il Pi non puo' decifrare (e' il punto): si controlla che il file sia
  # davvero cifrato per la chiave giusta
  KEYID=$(GNUPGHOME="$GH" gpg --batch --with-colons --show-keys "$PUBKEY" 2>/dev/null | awk -F: '$1=="sub" && $12 ~ /e/ {print $5; exit}')
  if GNUPGHOME="$GH" gpg --batch --list-packets "$OUT" 2>&1 | grep -q "pubkey enc packet.*keyid $KEYID"; then
    log "cifrato per la chiave $KEYID: ok"
  else
    rm -f "$OUT"; echo "Il file cifrato non risulta destinato alla chiave $KEYID." >&2; exit 1
  fi
elif [ "$PLAIN" -eq 0 ]; then
  OUT="$DEST/$NAME.tar.gz.gpg"
  log "cifratura AES256"
  if ! gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
           --symmetric --cipher-algo AES256 -o "$OUT" "$TARBALL" 3<<<"$PASS1"; then
    echo "Cifratura fallita." >&2; exit 1
  fi
  # prova di decifratura: deve tornare l'archivio identico
  if gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d "$OUT" 3<<<"$PASS1" 2>/dev/null \
       | cmp -s - "$TARBALL"; then
    log "prova di decifratura: ok"
  else
    echo "Prova di decifratura FALLITA: non fidarti di questo file." >&2; exit 1
  fi
  unset PASS1
else
  OUT="$DEST/$NAME.tar.gz"
  cp "$TARBALL" "$OUT"
  warn "archivio NON cifrato: contiene la chiave privata della CA OpenVPN"
fi

# --- 6. manifest in chiaro (solo nomi file e hash) ----------------------------
{
  echo "Backup Home Hub $TS - $(hostname)"
  echo "Archivio: $(basename "$OUT")"
  echo "sha256:   $(sha256sum "$OUT" | cut -d' ' -f1)"
  echo "Dimensione: $(du -h "$OUT" | cut -f1)"
  echo
  echo "Contenuto:"
  sed 's/^/  /' "$WORK/list.txt"
} >"$MANIFEST"
chown "$OWNER" "$OUT" "$MANIFEST" 2>/dev/null

if [ "$AUTO" -eq 1 ]; then
  echo "OK $OUT ($(du -h "$OUT" | cut -f1))"
  exit 0
fi

cat <<EOF

Fatto.
  Archivio: $OUT ($(du -h "$OUT" | cut -f1))
  Manifest: $MANIFEST

Copialo fuori dal Pi (da WSL sul Surface):
  scp $OWNER@<ip-home-hub>:$NAME.* /mnt/c/Users/as/

Per verificarlo in futuro (chiede la passphrase):
  gpg -d $(basename "$OUT") | tar -tzf - | head

Poi cancella le copie rimaste sul Pi:
  rm ~/$NAME.*
EOF
