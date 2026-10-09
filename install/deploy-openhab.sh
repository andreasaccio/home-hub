#!/usr/bin/env bash
# =============================================================================
# deploy-openhab.sh - copia la configurazione openHAB del repo in /etc/openhab
#
# Cartelle gestite in modo completo (i file non presenti nel repo vengono
# rimossi): things, items, persistence, rules, sitemaps.
# services: copiati solo i file presenti nel repo (addons.cfg, network.cfg),
# senza toccare gli altri (es. runtime.cfg).
# Non tocca automation/, transform/, html/, icons/.
#
# Ogni file sostituito o rimosso viene salvato in
#   /var/backups/homehub-openhab/<data>/
# openHAB rilegge da solo i file cambiati: niente riavvio.
#
# Uso:  sudo bash install/deploy-openhab.sh --check   mostra cosa cambierebbe
#       sudo bash install/deploy-openhab.sh           applica
# =============================================================================

set -euo pipefail
export LC_ALL=C

CHECK=0
case "${1:-}" in
  --check|-n) CHECK=1 ;;
  "") ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync assente: sudo apt-get install -y rsync" >&2; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/openhab"
DST=/etc/openhab
TS=$(date +%Y%m%d-%H%M%S)
BK=/var/backups/homehub-openhab/$TS
OWNER=openhab:openhab

[ -d "$SRC" ] || { echo "Cartella $SRC assente" >&2; exit 1; }
[ -d "$DST" ] || { echo "Cartella $DST assente: openHAB e' installato?" >&2; exit 1; }

RS=(rsync -rtci --chown="$OWNER" --temp-dir=/var/tmp --exclude=readme.txt)
[ "$CHECK" -eq 1 ] && RS+=(--dry-run)

echo "Deploy da $SRC a $DST $([ "$CHECK" -eq 1 ] && echo '(PROVA, nessuna modifica)')"
[ -d "$REPO/.git" ] && echo "Commit: $(git -C "$REPO" log -1 --format='%h %cd %s' --date=short 2>/dev/null || echo '?')"

CHANGES=0
for d in things items persistence rules sitemaps; do
  [ -d "$SRC/$d" ] || continue
  echo "--- $d"
  out=$("${RS[@]}" --delete --backup --backup-dir="$BK/$d" "$SRC/$d/" "$DST/$d/")
  [ -n "$out" ] && { echo "$out"; CHANGES=1; } || echo "    nessuna modifica"
done

if [ -d "$SRC/services" ]; then
  echo "--- services (solo i file del repo)"
  out=$("${RS[@]}" --backup --backup-dir="$BK/services" "$SRC/services/" "$DST/services/")
  [ -n "$out" ] && { echo "$out"; CHANGES=1; } || echo "    nessuna modifica"
fi

if [ "$CHECK" -eq 1 ]; then
  echo; echo "Prova completata. Legenda: '>f' file copiato, '*deleting' file rimosso, 'c'/'s'/'t' contenuto/dimensione/data."
  exit 0
fi

if [ "$CHANGES" -eq 1 ]; then
  echo; echo "Applicato. File sostituiti o rimossi salvati in: $BK"
  echo "Controllo nel log di openHAB (ultime righe su things/items/addon):"
  sleep 5
  grep -hE 'model\.core|ModelRepository|Loading model|addon|ERROR|WARN' /var/log/openhab/openhab.log 2>/dev/null | tail -n 15 || true
else
  rmdir -p "$BK" 2>/dev/null || true
  echo; echo "Nessuna modifica da applicare."
fi
