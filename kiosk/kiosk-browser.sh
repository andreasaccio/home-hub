#!/bin/sh
# Lanciato da cage (kiosk.service): aspetta che openHAB risponda, poi apre
# Chromium a schermo intero sulla pagina TV. Se Chromium si chiude, systemd
# riavvia tutto dopo 10 s.
URL="${KIOSK_URL:-http://127.0.0.1:8080/static/tv/index.html}"

# al boot openHAB impiega qualche minuto: intanto lo schermo resta nero
n=0
until curl -fsS -o /dev/null --max-time 3 "$URL"; do
  n=$((n + 1))
  [ "$n" -ge 120 ] && break      # dopo 10 minuti apre comunque
  sleep 5
done

exec chromium \
  --ozone-platform=wayland \
  --kiosk --incognito \
  --noerrdialogs --disable-infobars --no-first-run \
  --disable-session-crashed-bubble \
  --disable-features=Translate,MediaRouter \
  --check-for-update-interval=31536000 \
  --password-store=basic \
  --overscroll-history-navigation=0 --disable-pinch \
  --user-data-dir=/var/lib/kiosk/chromium \
  "$URL"
