#!/usr/bin/env bash
# =============================================================================
# homehub-restore-vpn.sh - ripristina sul NUOVO Home Hub il server OpenVPN del Pi 3
#
# Prende l'archivio prodotto da homehub-backup.sh e ripristina:
#   /etc/openvpn (config, ccd, PKI easy-rsa, tls-crypt, crl), regole firewall
#   con la unit che le carica al boot, ip_forward; poi avvia openvpn@server.
#
# Di default e' una PROVA A SECCO: decifra in RAM, controlla l'archivio e il
# sistema, elenca cosa farebbe. Non tocca nulla.
# Con --apply esegue davvero. E' ripetibile: prima di sovrascrivere salva
# l'attuale /etc/openvpn in /etc/openvpn.pre-restore-<data>.
#
# Si rifiuta di girare sul Pi 3 (hostname openhabian / Raspberry Pi 3).
# Finche' il port forward 1194 punta al Pi 3, nessun client raggiunge questo server.
#
# Uso:  sudo bash homehub-restore-vpn.sh homehub-backup-AAAAMMGG-HHMM.tar.gz.gpg
#       sudo bash homehub-restore-vpn.sh homehub-backup-AAAAMMGG-HHMM.tar.gz.gpg --apply
# =============================================================================

set -u
export LC_ALL=C

ARCHIVE=${1:-}
MODE=${2:-}
case "$ARCHIVE" in
  ""|-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
esac
APPLY=0
case "$MODE" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "Secondo argomento sconosciuto: $MODE (ammesso solo --apply)" >&2; exit 2 ;;
esac

die()  { printf '\nERRORE: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  [ok] %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || die "va lanciato con sudo"
[ -f "$ARCHIVE" ] || die "archivio non trovato: $ARCHIVE"

# --- guardie: mai sul Pi 3 ----------------------------------------------------
MODEL=$( { tr -d '\0' </proc/device-tree/model; } 2>/dev/null || echo "?")
[ "$(hostname)" != "openhabian" ] || die "hostname 'openhabian': questo sembra il Pi 3. Lancialo sul nuovo Home Hub."
case "$MODEL" in *"Raspberry Pi 3"*) die "modello '$MODEL': questo e' il Pi 3. Lancialo sul nuovo Home Hub." ;; esac

TS=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d /dev/shm/hhvpn.XXXXXX 2>/dev/null || mktemp -d /tmp/hhvpn.XXXXXX)
chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

echo "Ripristino OpenVPN su $(hostname) ($MODEL) - modalita': $([ $APPLY -eq 1 ] && echo APPLY || echo 'prova a secco')"

# --- 1. estrazione in RAM -----------------------------------------------------
step "1. Lettura dell'archivio"
PATTERNS=('etc/openvpn/*' 'etc/iptables/*' 'etc/systemd/system/iptables-openvpn.service' 'etc/sysctl.d/*')
case "$ARCHIVE" in
  *.gpg)
    have gpg || die "gpg assente: sudo apt-get install -y gnupg"
    read -r -s -p "  Passphrase del backup: " PASS; echo
    gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d "$ARCHIVE" 3<<<"$PASS" 2>"$STAGE/gpg.err" \
      | tar -xzf - -C "$STAGE" --wildcards "${PATTERNS[@]}" 2>"$STAGE/tar.err"
    rcs=("${PIPESTATUS[@]}")
    unset PASS
    [ "${rcs[0]}" -eq 0 ] || die "decifratura fallita (passphrase errata?): $(head -n 3 "$STAGE/gpg.err")"
    ;;
  *.tar.gz|*.tgz)
    tar -xzf "$ARCHIVE" -C "$STAGE" --wildcards "${PATTERNS[@]}" 2>"$STAGE/tar.err"
    ;;
  *) die "formato non riconosciuto (attesi .tar.gz.gpg o .tar.gz)" ;;
esac
S="$STAGE/etc"
[ -f "$S/openvpn/server.conf" ] || die "l'archivio non contiene etc/openvpn/server.conf"
ok "archivio letto ($(find "$STAGE/etc" -type f | wc -l) file utili estratti in RAM)"

# --- 2. controllo del contenuto ------------------------------------------------
step "2. Contenuto OpenVPN nel backup"
CONF="$S/openvpn/server.conf"
dir_of() { awk -v k="$1" '$1==k {print $2; exit}' "$CONF"; }
PORT=$(dir_of port); PROTO=$(dir_of proto); DEV=$(dir_of dev)
info "server.conf: port ${PORT:-?} / proto ${PROTO:-?} / dev ${DEV:-?} / server $(awk '$1=="server"{print $2"/"$3}' "$CONF")"
MISSING=0
for k in ca cert key tls-crypt tls-auth crl-verify dh; do
  f=$(dir_of "$k")
  [ -n "$f" ] || continue
  [ "$f" = none ] && continue
  case "$f" in /*) p="$STAGE$f" ;; *) p="$S/openvpn/$f" ;; esac
  if [ -f "$p" ]; then ok "$k -> $f"; else warn "$k -> $f MANCANTE"; MISSING=1; fi
done
CCD=$(dir_of client-config-dir)
case "$CCD" in /*) CCDP="$STAGE$CCD" ;; "") CCDP="" ;; *) CCDP="$S/openvpn/$CCD" ;; esac
if [ -n "$CCDP" ] && [ -d "$CCDP" ]; then
  ok "ccd: $(ls "$CCDP" | xargs)"
else
  warn "client-config-dir ${CCD:-non definita} assente: LeoRaspy perderebbe 10.8.0.5 e le iroute"; MISSING=1
fi
if [ -f "$S/openvpn/easy-rsa/pki/private/ca.key" ]; then ok "PKI easy-rsa con chiave della CA"; else warn "PKI easy-rsa incompleta (niente nuovi client senza la chiave della CA)"; fi
if have openssl; then
  for k in ca cert; do
    f=$(dir_of "$k"); case "$f" in /*) p="$STAGE$f" ;; *) p="$S/openvpn/$f" ;; esac
    [ -f "$p" ] && info "$k scade: $(openssl x509 -in "$p" -noout -enddate 2>/dev/null | cut -d= -f2)"
  done
  f=$(dir_of crl-verify); [ -n "$f" ] && { case "$f" in /*) p="$STAGE$f" ;; *) p="$S/openvpn/$f" ;; esac
    [ -f "$p" ] && info "crl valida fino a: $(openssl crl -in "$p" -noout -nextupdate 2>/dev/null | cut -d= -f2)"; }
fi
[ $MISSING -eq 0 ] || die "mancano file indispensabili: ripristino interrotto"

step "3. Firewall e inoltro nel backup"
FW_MODE=""
if [ -f "$S/systemd/system/iptables-openvpn.service" ]; then
  FW_MODE=unit
  ok "unit iptables-openvpn.service presente"
  grep -E '^Exec(Start|Stop)=' "$S/systemd/system/iptables-openvpn.service" | sed 's/^/      /'
  for sc in $(grep -oE '/etc/iptables/[^[:space:]]+' "$S/systemd/system/iptables-openvpn.service" | sort -u); do
    if [ -f "$STAGE$sc" ]; then ok "script $sc"; else warn "script $sc MANCANTE"; FW_MODE=generate; fi
  done
else
  FW_MODE=generate
  warn "unit iptables-openvpn.service non presente nel backup: le regole verranno generate"
fi
if [ -f "$S/iptables/add-openvpn-rules.sh" ]; then
  info "regole (add-openvpn-rules.sh):"; grep -E '^(ip6?tables)' "$S/iptables/add-openvpn-rules.sh" | sed 's/^/      /'
fi
FWD_FILES=$(grep -lE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' "$S"/sysctl.d/*.conf 2>/dev/null | xargs -r -n1 basename | xargs)
if [ -n "$FWD_FILES" ]; then ok "ip_forward=1 in sysctl.d: $FWD_FILES"; else info "ip_forward non trovato in sysctl.d: verra' creato 99-openvpn.conf"; fi

# --- 4. sistema locale ---------------------------------------------------------
step "4. Questo sistema"
DEFIF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
info "interfaccia di default: ${DEFIF:-?}, IP: $(ip -4 -br addr show "${DEFIF:-eth0}" 2>/dev/null | awk '{print $3}')"
RULE_IFS=$(cat "$S"/iptables/*.sh 2>/dev/null | grep -oE -- '-[io] [a-z0-9]+' | awk '{print $2}' | grep -v '^tun' | sort -u | xargs)
if [ -n "$RULE_IFS" ] && [ -n "$DEFIF" ]; then
  for i in $RULE_IFS; do
    [ "$i" = "$DEFIF" ] && ok "le regole usano $i, che e' l'interfaccia di questo sistema" || warn "le regole usano $i ma qui l'interfaccia e' $DEFIF: vanno corrette"
  done
fi
if dpkg -s openvpn >/dev/null 2>&1; then info "openvpn installato: $(dpkg-query -W -f='${Version}' openvpn)"; else info "openvpn da installare"; fi
if have iptables; then info "iptables presente: $(iptables --version 2>/dev/null)"; else info "iptables da installare"; fi
[ -f /etc/openvpn/server.conf ] && warn "esiste gia' /etc/openvpn/server.conf: verra' salvato in /etc/openvpn.pre-restore-$TS"
systemctl is-active --quiet openvpn@server 2>/dev/null && warn "openvpn@server e' gia' attivo: verra' fermato e riavviato"

if [ $APPLY -eq 0 ]; then
  step "Prova a secco completata"
  cat <<EOF
  Con --apply farei:
    1. apt-get install openvpn iptables
    2. copia di /etc/openvpn dal backup (l'attuale salvato in /etc/openvpn.pre-restore-$TS)
       e drop-in LogsDirectory per openvpn@server (/var/log in zram si svuota a ogni riavvio)
    3. firewall: $([ "$FW_MODE" = unit ] && echo "unit iptables-openvpn.service e script /etc/iptables dal backup" || echo "unit e script generati da server.conf")
    4. ip_forward=1 in /etc/sysctl.d
    5. enable + start di openvpn@server e verifiche (servizio, porta ${PORT:-1194}/${PROTO:-tcp}, tun0, journal)

  Se l'elenco sopra non ha [!] inattesi, rilancia con --apply.
EOF
  exit 0
fi

# --- 5. APPLY ------------------------------------------------------------------
step "5. Installazione pacchetti"
DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update fallito"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvpn iptables || die "installazione openvpn/iptables fallita"
ok "openvpn $(dpkg-query -W -f='${Version}' openvpn), $(iptables --version)"
systemctl cat openvpn@server.service >/dev/null 2>&1 || die "la unit openvpn@.service non esiste in questa versione: serve adattare (openvpn-server@)"

step "6. /etc/openvpn"
systemctl is-active --quiet openvpn@server && { systemctl stop openvpn@server; info "openvpn@server fermato"; }
if [ -d /etc/openvpn ]; then cp -a /etc/openvpn "/etc/openvpn.pre-restore-$TS" && info "copia dell'attuale in /etc/openvpn.pre-restore-$TS"; fi
mkdir -p /etc/openvpn
cp -a "$S/openvpn/." /etc/openvpn/ || die "copia di /etc/openvpn fallita"
chown -R root:root /etc/openvpn
STATUS=$(dir_of status); [ -n "$STATUS" ] && install -d -m 755 "$(dirname "$STATUS")"
ok "/etc/openvpn ripristinato"
# openHABian tiene /var/log in zram: le sottocartelle spariscono a ogni riavvio
# e openvpn non parte (--status fails ... No such file or directory). systemd la
# ricrea prima dell'avvio con LogsDirectory= (stesso file di system/ nel repo).
for k in status log log-append; do
  f=$(dir_of "$k")
  case "$f" in /var/log/*/*) LOGSUB=${f#/var/log/}; LOGSUB=${LOGSUB%%/*}; break ;; esac
done
if [ -n "${LOGSUB:-}" ]; then
  install -d -m 755 /etc/systemd/system/openvpn@server.service.d
  printf '[Service]\n# /var/log sta in zram (openHABian): la cartella va ricreata a ogni avvio\nLogsDirectory=%s\n' "$LOGSUB" \
    >/etc/systemd/system/openvpn@server.service.d/logdir.conf
  ok "drop-in LogsDirectory=$LOGSUB (cartella dei log ricreata a ogni avvio)"
fi

step "7. Firewall"
if [ "$FW_MODE" = unit ]; then
  install -d -m 755 /etc/iptables
  cp -a "$S/iptables/." /etc/iptables/
  chmod 755 /etc/iptables/*.sh 2>/dev/null
  install -m 644 "$S/systemd/system/iptables-openvpn.service" /etc/systemd/system/iptables-openvpn.service
  ok "unit e script dal backup"
else
  NET=$(awk '$1=="server"{print $2"/"$3}' "$CONF")
  CIDR=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1],strict=False))" "$NET" 2>/dev/null || echo "10.8.0.0/24")
  IF=${DEFIF:-eth0}; P=${PROTO%%-*}; P=${P%[46]}
  install -d -m 755 /etc/iptables
  cat >/etc/iptables/add-openvpn-rules.sh <<EOF
#!/bin/sh
iptables -t nat -I POSTROUTING 1 -s $CIDR -o $IF -j MASQUERADE
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I FORWARD 1 -i $IF -o tun0 -j ACCEPT
iptables -I FORWARD 1 -i tun0 -o $IF -j ACCEPT
iptables -I INPUT 1 -i $IF -p $P --dport ${PORT:-1194} -j ACCEPT
EOF
  cat >/etc/iptables/rm-openvpn-rules.sh <<EOF
#!/bin/sh
iptables -t nat -D POSTROUTING -s $CIDR -o $IF -j MASQUERADE
iptables -D INPUT -i tun0 -j ACCEPT
iptables -D FORWARD -i $IF -o tun0 -j ACCEPT
iptables -D FORWARD -i tun0 -o $IF -j ACCEPT
iptables -D INPUT -i $IF -p $P --dport ${PORT:-1194} -j ACCEPT
EOF
  chmod 755 /etc/iptables/*.sh
  cat >/etc/systemd/system/iptables-openvpn.service <<'EOF'
[Unit]
Description=iptables rules for OpenVPN
Before=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/iptables/add-openvpn-rules.sh
ExecStop=/etc/iptables/rm-openvpn-rules.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  ok "unit e script generati ($CIDR via $IF, $P/${PORT:-1194})"
fi
systemctl daemon-reload
systemctl is-active --quiet iptables-openvpn && systemctl stop iptables-openvpn
systemctl enable --now iptables-openvpn >/dev/null 2>&1 || die "avvio di iptables-openvpn fallito: journalctl -u iptables-openvpn"
ok "iptables-openvpn attivo"

step "8. Inoltro IPv4"
if [ -n "$FWD_FILES" ]; then
  for f in $FWD_FILES; do install -m 644 "$S/sysctl.d/$f" "/etc/sysctl.d/$f"; done
else
  echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-openvpn.conf
fi
sysctl --system >/dev/null 2>&1
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && ok "net.ipv4.ip_forward = 1" || warn "ip_forward non e' 1: controllare /etc/sysctl.d"

step "9. Avvio openvpn@server"
systemctl enable openvpn@server >/dev/null 2>&1
systemctl restart openvpn@server
sleep 4
if systemctl is-active --quiet openvpn@server; then ok "openvpn@server attivo"; else warn "openvpn@server NON attivo"; fi
ss -ltnup 2>/dev/null | grep -E ":${PORT:-1194}[[:space:]]" | sed 's/^/      /' || true
if ip link show tun0 >/dev/null 2>&1; then ip -br addr show tun0 | sed 's/^/      /'; else warn "tun0 non presente"; fi
echo "  ultime righe del journal:"
journalctl -u openvpn@server --no-pager -n 15 2>/dev/null | sed 's/^/      /'

step "Fatto"
cat <<EOF
  Il server e' pronto su questo Pi ma nessun client lo raggiunge finche' il
  port forward ${PORT:-1194}/${PROTO:-tcp} punta al Pi 3. Il passaggio (fase 3 del piano):
    1. sul Pi 3: sudo poweroff
    2. su questo Pi: IP 192.168.133.251 (reservation sul router o nmcli)
    3. controllo: cat $(dir_of status) ; ping 10.8.0.5 ; curl -I http://10.8.0.5:8080/
  Rollback: spegnere questo Pi e riaccendere il Pi 3.
EOF
