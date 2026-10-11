#!/usr/bin/env bash
# =============================================================================
# homehub-backup-auto.sh - backup notturno del Home Hub (homehub-backup.service)
#
#   1. archivio cifrato con la chiave pubblica (homehub-backup.sh --auto)
#   2. conservazione: ultimi KEEP_DAILY giorni, KEEP_WEEKLY settimane,
#      KEEP_MONTHLY mesi (un archivio ciascuno, il piu' recente)
#   3. copia sul Synology con rsync via SSH (specchio di OUTDIR); da li' Cloud
#      Sync la carica su OneDrive
#   4. esito su MQTT (homehub/backup/...), letto da openHAB e dalla pagina TV
#
# Installato in /usr/local/lib/homehub/ da install/setup-backup.sh.
# Log: journalctl -u homehub-backup
# =============================================================================

set -uo pipefail
export LC_ALL=C

# shellcheck source=/dev/null
. /etc/homehub/backup.conf

mqtt() { mosquitto_pub -h 127.0.0.1 -p 1884 -r -q 1 -t "homehub/backup/$1" -m "$2" 2>/dev/null || true; }
fail() { echo "ERRORE: $*" >&2; mqtt status errore; mqtt message "$*"; exit 1; }

mqtt status in_corso
echo "--- archivio"
/usr/local/lib/homehub/homehub-backup.sh --auto || fail "creazione dell'archivio non riuscita"
NEW=$(ls -1t "$OUTDIR"/homehub-backup-*.tar.gz.gpg 2>/dev/null | head -n 1)
[ -n "$NEW" ] || fail "archivio non trovato in $OUTDIR"

echo "--- conservazione ($KEEP_DAILY giorni, $KEEP_WEEKLY settimane, $KEEP_MONTHLY mesi)"
python3 - "$OUTDIR" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY" <<'PY' || fail "conservazione non riuscita"
import os, re, sys, datetime as dt
d, nd, nw, nm = sys.argv[1], *map(int, sys.argv[2:5])
rx = re.compile(r"^homehub-backup-(\d{8}-\d{4})\.tar\.gz\.gpg$")
arch = sorted(((dt.datetime.strptime(m.group(1), "%Y%m%d-%H%M"), f)
               for f in os.listdir(d) if (m := rx.match(f))), reverse=True)
keep = {arch[0][1]} if arch else set()
for n, key in ((nd, lambda t: t.date()),
               (nw, lambda t: t.isocalendar()[:2]),
               (nm, lambda t: (t.year, t.month))):
    seen = []
    for t, f in arch:                       # dal piu' recente: il primo di ogni periodo
        k = key(t)
        if k not in seen:
            if len(seen) == n: break
            seen.append(k); keep.add(f)
for t, f in arch:
    if f not in keep:
        for x in (f, f.replace(".tar.gz.gpg", ".manifest.txt")):
            p = os.path.join(d, x)
            if os.path.exists(p): os.remove(p); print("    rimosso", x)
print(f"    {len(keep)} archivi conservati")
PY

echo "--- copia sul Synology ($NAS_USER@$NAS_HOST:$NAS_PATH)"
SSH="ssh -i $SSH_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=20"
# --max-delete: se la cartella sul Pi fosse vuota (SD nuova) non si cancellano
# gli archivi vecchi sul Synology; di norma la conservazione toglie 1-2 file.
rsync -rt --delete --max-delete=6 --chmod=D700,F600 -e "$SSH" "$OUTDIR"/ "$NAS_USER@$NAS_HOST:$NAS_PATH/"
rc=$?
case $rc in
  0) ;;
  25) mqtt message "attenzione: troppe cancellazioni, alcune rimandate"; echo "    attenzione: limite di cancellazioni raggiunto" ;;
  *) fail "copia sul Synology non riuscita (rsync $rc)" ;;
esac
# verifica: con --checksum non deve restare niente da copiare per l'archivio nuovo
if rsync -rn --checksum --itemize-changes -e "$SSH" "$NEW" "$NAS_USER@$NAS_HOST:$NAS_PATH/" | grep -q .; then
  fail "l'archivio sul Synology non coincide con quello del Pi"
fi

SIZE=$(du -h "$NEW" | cut -f1)
mqtt last_ok "$(date --iso-8601=seconds)"
mqtt message "$(basename "$NEW") ($SIZE) sul Synology"
mqtt status ok
echo "OK $(basename "$NEW") ($SIZE) sul Synology"
