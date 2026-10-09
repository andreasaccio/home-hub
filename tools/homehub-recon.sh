#!/usr/bin/env bash
# =============================================================================
# homehub-recon.sh - ricognizione in SOLA LETTURA del Raspberry "Home Hub"
#
# Cosa fa:     inventaria hardware, OS, openHABian/openHAB, server OpenVPN,
#              firewall, servizi, rete, mDNS, Bluetooth, collegamento a LeoRaspy.
# Cosa NON fa: niente apt update/upgrade, niente restart, niente modifiche.
#              Unica scrittura: il file di report nella home dell'utente sudo.
# Segreti:     password, token, chiavi private e blocchi inline OpenVPN vengono
#              oscurati. Ricontrolla comunque il file prima di condividerlo.
#
# Uso:  sudo bash homehub-recon.sh           solo lettura passiva
#       sudo bash homehub-recon.sh --scan    + ping-sweep della LAN e scan BLE di 20 s
# =============================================================================

set -u
export LC_ALL=C

SCAN=0
case "${1:-}" in
  --scan) SCAN=1 ;;
  "") ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "Opzione sconosciuta: $1 (usa --scan oppure nulla)" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Va lanciato con sudo: sudo bash $0 [--scan]" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M)
OWNER=${SUDO_USER:-root}
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
OUT="${OWNER_HOME:-/root}/homehub-recon-$TS.txt"

# percorsi openHAB (openHAB 3/4/5 = openhab, openHAB 2 = openhab2)
OH_PKG=""; OH_CONF=""; OH_DATA=""; OH_LOGS=""
for p in openhab openhab2; do
  if [ -d "/var/lib/$p" ] || [ -d "/etc/$p" ]; then
    OH_PKG=$p; OH_CONF=/etc/$p; OH_DATA=/var/lib/$p; OH_LOGS=/var/log/$p
    break
  fi
done

have() { command -v "$1" >/dev/null 2>&1; }

# Oscura i segreti: chiavi private PEM, blocchi inline OpenVPN, credenziali
# negli URL, parametri sensibili in query string, righe chiave=valore sensibili.
redact() {
  sed -E \
    -e '/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,/-----END [A-Z0-9 ]*PRIVATE KEY-----/c [REDACTED PRIVATE KEY]' \
    -e '/<(key|tls-auth|tls-crypt|tls-crypt-v2|secret|pkcs12)>/,/<\/(key|tls-auth|tls-crypt|tls-crypt-v2|secret|pkcs12)>/c [REDACTED OPENVPN INLINE BLOCK]' \
    -e 's#(://[^/:@[:space:]]+):[^@[:space:]]+@#\1:[REDACTED]@#g' \
    -e 's/([?&](access_token|refresh_token|token|apikey|api_key|key|auth|password|pass|pw)=)[^&[:space:]"]*/\1[REDACTED]/Ig' \
    -e 's/([A-Za-z0-9_.-]*(pass|pw|pwd|secret|token|apikey|api_key|api-key|psk|credential|privatekey|private_key)[A-Za-z0-9_.-]*["'"'"']?[[:space:]]*[=:][[:space:]]*).*/\1[REDACTED]/I'
}

exec 3>&2
sec()  { printf '\n\n########## %s ##########\n' "$*"; printf '  - %s\n' "$*" >&3; }
run()  { printf '\n$ %s\n' "$*"; timeout 60 bash -c "$*" 2>&1 | redact; }
blk()  { local f=$1; shift; printf '\n# %s\n' "$f"; "$f" "$@" 2>&1 | redact; }
show() {  # file di config senza commenti e righe vuote, oscurati
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '\n--- %s\n' "$f"
    grep -vE '^[[:space:]]*(#|;|//|$)' "$f" 2>&1 | head -n 400 | redact
  done
}

# ----------------------------------------------------------------------------
summary() {
  local model mem arch os oh ohstate java ovpn thr rootfs upg
  model=$( { tr -d '\0' </proc/device-tree/model; } 2>/dev/null || echo "n/d")
  mem=$(awk '/MemTotal/ {printf "%d MB", $2/1024}' /proc/meminfo)
  arch="dpkg $(dpkg --print-architecture 2>/dev/null), userland $(getconf LONG_BIT)-bit, kernel $(uname -m)"
  os=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-n/d}" )
  oh=$(dpkg-query -W -f='${Package} ${Version}\n' openhab openhab2 2>/dev/null | awk 'NF==2' | head -n 1)
  ohstate=$(systemctl is-active "${OH_PKG:-openhab}" 2>/dev/null)
  java=$( { java -version 2>&1 || true; } | grep -v '^Picked up' | head -n 1)
  ovpn=$(systemctl list-units --type=service --state=running --no-legend 'openvpn*' 2>/dev/null | awk '{print $1}' | xargs)
  thr=$( { vcgencmd get_throttled 2>/dev/null || echo "vcgencmd n/d"; } | head -n 1)
  rootfs=$(df -h / | awk 'NR==2 {print $3" usati su "$2" ("$5")"}')
  upg=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from')
  printf '%-22s %s\n' \
    "Host"                "$(hostname) - $(uptime -p 2>/dev/null)" \
    "Modello"             "$model" \
    "RAM"                 "$mem" \
    "Architettura"        "$arch" \
    "OS"                  "$os" \
    "openHAB"             "${oh:-non installato} (servizio: ${ohstate:-n/d})" \
    "Java"                "${java:-assente}" \
    "OpenVPN attivo"      "${ovpn:-nessuna unit openvpn in esecuzione}" \
    "Alimentazione"       "$thr" \
    "Disco /"             "$rootfs" \
    "Pacchetti da aggior." "$upg (secondo l'ultima apt update)" \
    "Report"              "$TS, opzione --scan=$SCAN"
}

# ----------------------------------------------------------------------------
oh_jsondb() {
  [ -n "$OH_DATA" ] && [ -d "$OH_DATA/jsondb" ] || { echo "jsondb non trovato"; return; }
  have python3 || { echo "python3 assente, elenco solo i file"; ls -la "$OH_DATA/jsondb"; return; }
  python3 - "$OH_DATA/jsondb" <<'PY'
import glob, json, os, sys
from collections import Counter

base = sys.argv[1]

def load(suffix):
    files = sorted(glob.glob(os.path.join(base, '*' + suffix)))
    if not files:
        return None
    try:
        with open(files[0], encoding='utf-8') as fh:
            return json.load(fh)
    except Exception as exc:
        print("  [errore lettura %s: %s]" % (files[0], exc))
        return None

def val(entry):
    return entry.get('value', entry) if isinstance(entry, dict) else {}

def uid_str(x):
    if isinstance(x, dict):
        seg = x.get('segments')
        return ':'.join(seg) if seg else (x.get('uid') or '')
    return x or ''

print("File jsondb:")
for f in sorted(os.listdir(base)):
    p = os.path.join(base, f)
    if os.path.isfile(p):
        print("  %9d  %s" % (os.path.getsize(p), f))

things = load('thing.Thing.json')
if things:
    print("\nThing: %d" % len(things))
    per = Counter(uid.split(':')[0] for uid in things)
    print("  per binding: " + ", ".join("%s=%d" % kv for kv in sorted(per.items())))
    for uid in sorted(things):
        v = val(things[uid])
        bridge = uid_str(v.get('bridgeUID'))
        line = "  %s  | %s" % (uid, v.get('label', ''))
        if bridge:
            line += "  | bridge=" + bridge
        print(line)

items = load('items.Item.json')
if items:
    print("\nItem: %d" % len(items))
    per = Counter(val(i).get('itemType', '?') for i in items.values())
    print("  per tipo: " + ", ".join("%s=%d" % kv for kv in sorted(per.items())))
    for n, name in enumerate(sorted(items)):
        if n >= 400:
            print("  ... altri %d" % (len(items) - 400))
            break
        v = val(items[name])
        print("  %s  [%s]  %s" % (name, v.get('itemType', '?'), v.get('label') or ''))

links = load('link.ItemChannelLink.json')
if links is not None:
    print("\nLink item-canale: %d" % len(links))

rules = load('automation_rules.json')
if rules:
    print("\nRegole create da UI: %d" % len(rules))
    for uid in sorted(rules):
        print("  %s  | %s" % (uid, val(rules[uid]).get('name', '')))

for suffix, title in (('uicomponents_ui_page.json', 'Pagine Main UI'),
                      ('uicomponents_ui_widget.json', 'Widget personalizzati'),
                      ('uicomponents_system_sitemap.json', 'Sitemap da UI'),
                      ('PersistenceServiceConfiguration.json', 'Persistence da UI')):
    d = load(suffix)
    if d:
        print("%s: %s" % (title, ", ".join(sorted(d))))
PY
}

oh_textconf() {
  [ -n "$OH_CONF" ] && [ -d "$OH_CONF" ] || { echo "configurazione testuale non trovata"; return; }
  echo "File di configurazione testuale (dimensione, data, percorso):"
  find "$OH_CONF" -type f \( -name '*.things' -o -name '*.items' -o -name '*.rules' -o -name '*.sitemap' \
       -o -name '*.persist' -o -name '*.js' -o -name '*.py' -o -name '*.rb' -o -name '*.yaml' -o -name '*.map' \) \
       -printf '  %7s B  %TY-%Tm-%Td  %p\n' 2>/dev/null | sort -k4
  echo
  echo "Nomi delle regole DSL:"
  grep -hE '^[[:space:]]*rule[[:space:]]' "$OH_CONF"/rules/*.rules 2>/dev/null | sed 's/^/  /'
}

# ----------------------------------------------------------------------------
ovpn_confs() { ls /etc/openvpn/*.conf /etc/openvpn/server/*.conf 2>/dev/null; }

ovpn_paths() {  # $1 = direttiva OpenVPN -> percorsi assoluti dai conf del server
  local f dir p
  ovpn_confs | while read -r f; do
    dir=$(dirname "$f")
    awk -v k="$1" '$1==k {print $2}' "$f" | while read -r p; do
      case "$p" in /*) echo "$p" ;; *) echo "$dir/$p" ;; esac
    done
  done | sort -u
}

ovpn_files() {
  echo "Albero /etc/openvpn (solo nomi e permessi):"
  find /etc/openvpn -maxdepth 4 -printf '  %M %-8u %8s %TY-%Tm-%Td  %p\n' 2>/dev/null | sort -k5
  echo
  local f
  for f in /etc/openvpn/*.conf /etc/openvpn/server/*.conf /etc/openvpn/client/*.conf; do
    [ -f "$f" ] || continue
    printf '\n--- %s\n' "$f"
    grep -vE '^[[:space:]]*(#|;|$)' "$f"
  done
}

ovpn_ccd() {
  local d f
  { echo /etc/openvpn/ccd; echo /etc/openvpn/server/ccd; ovpn_paths client-config-dir; } | sort -u |
  while read -r d; do
    [ -d "$d" ] || continue
    printf '\n--- ccd: %s\n' "$d"
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      printf '[%s]\n' "$(basename "$f")"
      grep -vE '^[[:space:]]*(#|;|$)' "$f" | sed 's/^/    /'
    done
  done
  ovpn_paths ifconfig-pool-persist | while read -r f; do
    [ -f "$f" ] && { printf '\n--- pool persist: %s\n' "$f"; cat "$f"; }
  done
  ovpn_paths status | while read -r f; do
    [ -f "$f" ] && { printf '\n--- status: %s\n' "$f"; head -n 60 "$f"; }
  done
}

ovpn_certs() {
  have openssl || { echo "openssl assente"; return; }
  local k p pki
  for k in ca cert; do
    ovpn_paths "$k" | while read -r p; do
      printf '%-5s %s\n      %s\n' "$k" "$p" "$(openssl x509 -in "$p" -noout -subject -enddate 2>&1 | xargs)"
    done
  done
  ovpn_paths crl-verify | while read -r p; do
    printf 'crl   %s\n      %s\n' "$p" "$(openssl crl -in "$p" -noout -lastupdate -nextupdate 2>&1 | xargs)"
  done
  find /etc/openvpn /root /home /usr/share/easy-rsa /opt -maxdepth 5 -type d -name pki 2>/dev/null | sort -u |
  while read -r pki; do
    [ -f "$pki/ca.crt" ] || continue
    printf '\n--- PKI easy-rsa: %s\n' "$pki"
    printf '  ca.crt   %s\n' "$(openssl x509 -in "$pki/ca.crt" -noout -enddate 2>&1)"
    [ -f "$pki/crl.pem" ] && printf '  crl.pem  %s\n' "$(openssl crl -in "$pki/crl.pem" -noout -nextupdate 2>&1)"
    if [ -f "$pki/index.txt" ]; then
      echo "  index.txt (V=valido R=revocato E=scaduto | scadenza YYMMDD | soggetto):"
      awk -F'\t' '{print "    " $1 "  " $2 "  " $NF}' "$pki/index.txt"
    fi
  done
}

# ----------------------------------------------------------------------------
pkgs_of_interest() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
    mosquitto mosquitto-clients influxdb influxdb2 influxdb2-cli grafana grafana-enterprise telegraf \
    nginx apache2 lighttpd homegear zigbee2mqtt deconz samba amanda-server amanda-client \
    tailscale wireguard wireguard-tools docker.io docker-ce fail2ban log2ram zram-tools \
    avahi-daemon avahi-utils bluez nmap jq python3 python3-pip ddclient openvpn easy-rsa \
    iptables iptables-persistent nftables ufw 2>/dev/null | grep '^ii' | sed 's/^ii  */  /'
}

crons() {
  local u
  for u in root "$OWNER" openhab openhabian; do
    getent passwd "$u" >/dev/null || continue
    printf '\n--- crontab %s\n' "$u"
    crontab -l -u "$u" 2>&1 | grep -vE '^[[:space:]]*(#|$)'
  done | awk '!seen[$0]++'
  echo
  ls -la /etc/cron.d 2>/dev/null
  local f
  for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue
    printf '\n--- %s\n' "$f"; grep -vE '^[[:space:]]*(#|$)' "$f"
  done
}

net_mgmt() {
  local s
  for s in NetworkManager dhcpcd systemd-networkd; do
    printf '  %-18s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  have nmcli && { echo; nmcli -t -f NAME,TYPE,DEVICE,AUTOCONNECT con show 2>&1; }
  return 0
}

lan_sweep() {
  local net
  ip -o -4 addr show scope global | awk '$2 !~ /^(tun|tap|wg|docker|br-|veth|lo)/ {print $4}' |
  while read -r net; do
    if have nmap; then
      printf '\n--- nmap -sn %s\n' "$net"
      timeout 180 nmap -sn -n "$net" 2>&1 | grep -E 'scan report|MAC Address'
    elif [ "${net#*/}" = 24 ]; then
      printf '\n--- ping-sweep %s (nmap assente)\n' "$net"
      local base=${net%.*} i
      for i in $(seq 1 254); do ping -c 1 -W 1 "$base.$i" >/dev/null 2>&1 & done
      wait
      ip neigh show | grep -v FAILED | sort -t. -k4 -n
    else
      echo "nmap assente e rete $net non /24: sweep saltato"
    fi
  done
}

mdns() {
  have avahi-browse || { echo "avahi-browse assente (pacchetto avahi-utils): sezione saltata"; return; }
  echo "Formato: nome ; tipo servizio ; host ; IP ; porta ; TXT"
  echo "(_hap._tcp = HomeKit: md= modello, sf=1 non abbinato / sf=0 gia' abbinato)"
  timeout 20 avahi-browse -artpk 2>/dev/null | grep '^=' | awk -F';' '$3=="IPv4"' |
    cut -d';' -f4,5,7,8,9,10 | sort -u | head -n 300
}

ble() {
  echo "rfkill:"; rfkill list 2>&1 | sed 's/^/  /'
  local s
  for s in bluetooth hciuart; do printf '  %-10s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"; done
  have bluetoothctl || { echo "bluetoothctl assente"; return; }
  echo "bluez: $(bluetoothctl --version 2>&1)"
  echo; timeout 8 bluetoothctl show 2>&1 | head -n 25
  if [ "$SCAN" -eq 1 ] && ! timeout 8 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
    echo; echo "Scan BLE saltato: adattatore spento o bloccato (sudo rfkill unblock bluetooth)"
  elif [ "$SCAN" -eq 1 ] && systemctl is-active --quiet bluetooth; then
    echo; echo "Scan BLE 20 s (nuovi dispositivi e nomi):"
    timeout 25 bluetoothctl --timeout 20 scan on 2>&1 | tr -d '\r\001\002' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' |
      grep -E '\[NEW\] Device|Name:|ManufacturerData Key|ServiceData Key' | sort -u | head -n 200
    echo; echo "Dispositivi noti a bluez:"
    timeout 8 bluetoothctl devices 2>&1 | head -n 200
  fi
}

ssh_keys() {
  local h
  for h in /root /home/*; do
    [ -f "$h/.ssh/authorized_keys" ] && printf '  %s: %s chiavi autorizzate\n' "$h" "$(grep -c . "$h/.ssh/authorized_keys")"
  done
  return 0
}

# ----------------------------------------------------------------------------
main() {
  echo "Home Hub - ricognizione $TS"
  sec "0. RIEPILOGO"
  summary

  sec "1. HARDWARE E STORAGE"
  run "{ tr -d '\\0' </proc/device-tree/model; } 2>/dev/null || echo 'device-tree assente: non sembra un Raspberry'; echo"
  run "grep -E '^(Hardware|Revision|Model)' /proc/cpuinfo"
  run 'free -h'
  run 'vcgencmd get_throttled; vcgencmd measure_temp'
  echo "(throttled: 0x0 = ok; bit 0x1 sottotensione ora, 0x10000 sottotensione avvenuta dal boot)"
  run 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL'
  run 'df -hT -x tmpfs -x devtmpfs -x squashfs'
  run 'findmnt -no SOURCE,FSTYPE,OPTIONS /; findmnt -no SOURCE,FSTYPE,OPTIONS /boot/firmware || findmnt -no SOURCE,FSTYPE,OPTIONS /boot'
  run 'for f in name date manfid oemid; do printf "sd %-7s %s\n" "$f" "$(cat /sys/block/mmcblk0/device/$f 2>/dev/null)"; done'
  run 'zramctl 2>/dev/null; grep -vE "^[[:space:]]*(#|$)" /etc/ztab 2>/dev/null'
  run "dmesg 2>/dev/null | grep -iE 'mmc.*(error|timeout)|i/o error|ext4-fs error|voltage' | tail -n 30"

  sec "2. SISTEMA OPERATIVO E PACCHETTI"
  run 'cat /etc/os-release; echo "debian_version: $(cat /etc/debian_version)"'
  run 'uname -a'
  run 'echo "dpkg: $(dpkg --print-architecture)  foreign: $(dpkg --print-foreign-architectures | xargs)  LONG_BIT: $(getconf LONG_BIT)"'
  show /boot/firmware/config.txt /boot/config.txt
  run "grep -rvhE '^[[:space:]]*(#|\$)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null"
  run "echo \"ultima apt update: \$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%TY-%Tm-%Td\n' | sort | tail -n 1)\""
  run 'apt list --upgradable 2>/dev/null | grep "upgradable from" | head -n 80'
  run 'timedatectl 2>/dev/null; uptime'

  sec "3. OPENHABIAN"
  run 'ls -la /opt/openhabian 2>&1 | head -n 5'
  run 'git -c safe.directory=/opt/openhabian -C /opt/openhabian log -1 --date=short --format="%h %cd %s"; git -c safe.directory=/opt/openhabian -C /opt/openhabian rev-parse --abbrev-ref HEAD'
  show /etc/openhabian.conf

  sec "4. OPENHAB"
  run "dpkg -l 'openhab*' 'openjdk*' 'temurin*' 'zulu*' 2>/dev/null | grep '^ii'"
  run 'java -version; update-alternatives --list java'
  run "systemctl status ${OH_PKG:-openhab} --no-pager -n 0"
  run "cat ${OH_DATA:-/nonexistent}/etc/version.properties"
  run 'curl -s -m 5 http://127.0.0.1:8080/rest/ | head -c 600; echo'
  show "/etc/default/${OH_PKG:-openhab}" "${OH_CONF:-/nonexistent}/services/addons.cfg" "${OH_DATA:-/nonexistent}/config/org/openhab/addons.config"
  blk oh_textconf
  [ -n "$OH_CONF" ] && show "$OH_CONF"/things/*.things "$OH_CONF"/persistence/*.persist
  blk oh_jsondb
  run "du -sh ${OH_DATA:-/nonexistent}/persistence/* ${OH_LOGS:-/nonexistent} 2>/dev/null; du -xh -d1 ${OH_DATA:-/nonexistent} 2>/dev/null | sort -h | tail -n 12"

  sec "5. OPENVPN, FIREWALL, DNS DINAMICO"
  run "dpkg -l 'openvpn*' 'easy-rsa*' 'wireguard*' 'tailscale*' 2>/dev/null | grep '^ii'; ls -d /etc/pivpn 2>/dev/null"
  run "systemctl list-units --all --no-pager --no-legend 'openvpn*' 'wg-quick*' 'tailscale*'"
  blk ovpn_files
  blk ovpn_ccd
  blk ovpn_certs
  run 'sysctl net.ipv4.ip_forward'
  run 'iptables-save 2>/dev/null || echo "iptables-save assente"'
  run 'nft list ruleset 2>/dev/null | head -n 150'
  run 'ufw status verbose 2>/dev/null'
  show /etc/ddclient.conf
  run "grep -rlisE 'duckdns|no-ip|noip|dynu|dyndns|ddns' /etc/cron* /var/spool/cron 2>/dev/null"

  sec "6. SERVIZI"
  blk pkgs_of_interest
  run 'systemctl list-units --type=service --state=running --no-pager --no-legend'
  run 'systemctl --failed --no-pager --no-legend'
  run 'systemctl list-timers --all --no-pager | head -n 40'
  run 'docker ps -a --format "{{.Names}}  {{.Image}}  {{.Status}}" 2>/dev/null'
  run 'ss -tulpn'
  blk crons

  sec "7. RETE E DISPOSITIVI IN LAN"
  run 'ip -br addr; echo; ip route'
  run 'cat /etc/resolv.conf'
  blk net_mgmt
  show /etc/dhcpcd.conf /etc/network/interfaces
  if [ "$SCAN" -eq 1 ]; then blk lan_sweep; fi
  run 'ip neigh show | grep -v FAILED | sort -t. -k4 -n'

  sec "8. mDNS (tado bridge, Shelly, ESPurna, HomeKit, Matter...)"
  blk mdns

  sec "9. BLUETOOTH"
  blk ble

  sec "10. CAMPER HUB VIA VPN"
  run 'ping -c 3 -W 2 10.8.0.5'
  run 'curl -s -m 5 -o /dev/null -w "LeoRaspy :8080 -> HTTP %{http_code} in %{time_total}s\n" http://10.8.0.5:8080/'

  sec "11. ACCESSO E SICUREZZA"
  run 'sshd -T 2>/dev/null | grep -E "^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|allowusers|allowgroups) "'
  blk ssh_keys
  run 'getent group sudo; ls -la /home'
  run 'last -n 15 2>/dev/null | head -n 20'

  sec "12. BACKUP ESISTENTI"
  run "ls -la ${OH_DATA:-/nonexistent}/backups 2>/dev/null; ls -la /etc/amanda 2>/dev/null"

  sec "13. ERRORI RECENTI"
  run 'journalctl -p err -b --no-pager 2>/dev/null | tail -n 40'
  run "grep -hE '\\[(ERROR|WARN) ?\\]' ${OH_LOGS:-/nonexistent}/openhab.log 2>/dev/null | tail -n 40"
  run "journalctl -u 'openvpn*' --no-pager -n 30 2>/dev/null"

  echo; echo "Fine ricognizione."
}

umask 077
echo "Ricognizione Home Hub in corso (sola lettura)..." >&3
main >"$OUT" 2>&1
chown "$OWNER" "$OUT" 2>/dev/null

cat >&3 <<EOF

Report: $OUT ($(du -h "$OUT" | cut -f1))

Copialo sul Surface (da WSL) e allegalo in chat:
  scp $OWNER@<ip-home-hub>:$(basename "$OUT") /mnt/c/Users/as/

I segreti noti sono oscurati, ma dagli comunque un'occhiata prima di condividerlo.
EOF
