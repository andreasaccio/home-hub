#!/usr/bin/env python3
"""switchbot-mqtt - termoigrometri SwitchBot via Bluetooth (annunci BLE) verso MQTT.

Ascolta gli annunci Bluetooth dei sensori SwitchBot, senza collegarsi ai
sensori, senza app e senza cloud. Decodifica temperatura, umidita' e batteria
come pySwitchbot (adv_parsers/meter.py) e le pubblica su Mosquitto:

  switchbot/<nome>/temperature   gradi C, un decimale      (retained)
  switchbot/<nome>/humidity      %                         (retained)
  switchbot/<nome>/battery       %                         (retained)
  switchbot/<nome>/rssi          dBm                       (retained)
  switchbot/<nome>/status        online | offline          (retained)
  switchbot/<nome>/last_seen     ora dell'ultimo annuncio  (retained)
  switchbot/bridge/status        online | offline (LWT di questo programma)

Un valore si ripubblica quando cambia, e comunque ogni publish.min_interval
secondi. Un sensore e' offline se non si sente da publish.offline_after secondi.

Uso:
  switchbot-mqtt.py --config /etc/homehub/switchbot.toml   servizio
  switchbot-mqtt.py --scan 60                              elenca i SwitchBot
                                                           in giro per 60 s

Dipendenze (Debian): python3-bleak, python3-paho-mqtt. Usa BlueZ via D-Bus:
serve root o il gruppo bluetooth.
"""

import argparse
import asyncio
import datetime
import signal
import sys
import time

COMPANY_ID = 0x0969          # Woan Technology (SwitchBot)
SERVICE_UUIDS = (
    "0000fd3d-0000-1000-8000-00805f9b34fb",
    "00000d00-0000-1000-8000-00805f9b34fb",   # modelli vecchi
)
# primo byte della service data & 0x7F -> modello (solo termoigrometri)
TH_MODELS = {
    "T": "Meter",
    "i": "Meter Plus",
    "w": "Indoor/Outdoor Meter",
    "4": "Meter Pro",
    "5": "Meter Pro CO2",
}


# --------------------------------------------------------------------------- #
# Decodifica                                                                  #
# --------------------------------------------------------------------------- #

def decode_temp_humidity(raw):
    """3 byte t0 t1 h, come pySwitchbot _sensor_th.decode_temp_humidity."""
    sign = 1 if raw[1] & 0x80 else -1
    temp = sign * ((raw[1] & 0x7F) + (raw[0] & 0x0F) / 10)
    humidity = raw[2] & 0x7F
    if temp == 0 and humidity == 0:
        return None
    return round(temp, 1), humidity


def decode(address, mfr, svc, known_model=None):
    """Decodifica un annuncio SwitchBot.

    address: indirizzo BLE; mfr: manufacturer data 0x0969 (senza company ID);
    svc: service data fd3d; known_model: modello gia' visto per questo
    indirizzo (la service data puo' mancare in un singolo annuncio).
    Restituisce un dict oppure None se non e' un SwitchBot.
    """
    if mfr is None and svc is None:
        return None
    out = {"address": address.upper(), "model": known_model, "encrypted": False,
           "battery": None, "temperature": None, "humidity": None}
    if mfr and len(mfr) >= 6:
        out["mac"] = ":".join(f"{b:02X}" for b in mfr[:6])
    else:
        out["mac"] = address.upper()
    if svc:
        out["model"] = chr(svc[0] & 0x7F)
        out["encrypted"] = bool(svc[0] & 0x80)
        if len(svc) >= 3:
            out["battery"] = svc[2] & 0x7F
    out["model_name"] = TH_MODELS.get(out["model"], "?")

    if out["model"] not in TH_MODELS or out["encrypted"]:
        return out   # SwitchBot ma non termoigrometro (o dati cifrati)

    raw = None
    if mfr and len(mfr) >= 11:
        raw = mfr[8:11]
    elif svc and len(svc) >= 6:
        raw = svc[3:6]
    if raw is not None:
        th = decode_temp_humidity(raw)
        if th:
            out["temperature"], out["humidity"] = th
    return out


def extract(adv):
    """manufacturer data e service data SwitchBot da un AdvertisementData di bleak."""
    mfr = adv.manufacturer_data.get(COMPANY_ID)
    svc = None
    for uuid in SERVICE_UUIDS:
        if uuid in adv.service_data:
            svc = adv.service_data[uuid]
            break
    return (bytes(mfr) if mfr is not None else None,
            bytes(svc) if svc is not None else None)


# --------------------------------------------------------------------------- #
# Bluetooth                                                                   #
# --------------------------------------------------------------------------- #

def make_scanner(callback):
    from bleak import BleakScanner
    # DuplicateData=True: BlueZ segnala ogni annuncio, non solo quelli cambiati
    try:
        return BleakScanner(detection_callback=callback,
                            bluez={"filters": {"Transport": "le",
                                               "DuplicateData": True}})
    except TypeError:
        return BleakScanner(detection_callback=callback)


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


# --------------------------------------------------------------------------- #
# Modalita' --scan                                                            #
# --------------------------------------------------------------------------- #

async def run_scan(seconds):
    seen = {}
    models = {}

    def on_adv(device, adv):
        mfr, svc = extract(adv)
        if mfr is None and svc is None:
            return
        d = decode(device.address, mfr, svc, models.get(device.address))
        if d is None:
            return
        if d["model"]:
            models[device.address] = d["model"]
        entry = seen.setdefault(device.address, {"count": 0})
        entry["count"] += 1
        entry.update(d)
        entry["rssi"] = getattr(adv, "rssi", None)
        if entry["count"] == 1:
            print(f"nuovo  {device.address}  {fmt(entry)}", flush=True)

    scanner = make_scanner(on_adv)
    print(f"Ascolto per {seconds} s... (solo dispositivi SwitchBot)", flush=True)
    await scanner.start()
    await asyncio.sleep(seconds)
    await scanner.stop()

    print(f"\nRiepilogo ({len(seen)} dispositivi SwitchBot):")
    for addr, e in sorted(seen.items(), key=lambda kv: -kv[1]["count"]):
        print(f"  {addr}  annunci {e['count']:4d}  {fmt(e)}")
    return 0


def fmt(e):
    parts = [f"modello {e.get('model') or '?'} ({e.get('model_name', '?')})"]
    if e.get("mac") and e["mac"] != e.get("address"):
        parts.append(f"MAC nei dati {e['mac']}")
    if e.get("encrypted"):
        parts.append("CIFRATO")
    if e.get("temperature") is not None:
        parts.append(f"{e['temperature']:.1f} C  {e['humidity']} %")
    if e.get("battery") is not None:
        parts.append(f"batteria {e['battery']} %")
    if e.get("rssi") is not None:
        parts.append(f"RSSI {e['rssi']}")
    return "  ".join(parts)


# --------------------------------------------------------------------------- #
# Servizio                                                                    #
# --------------------------------------------------------------------------- #

class Bridge:
    def __init__(self, cfg):
        mq = cfg.get("mqtt", {})
        pub = cfg.get("publish", {})
        self.prefix = mq.get("prefix", "switchbot").rstrip("/")
        self.host = mq.get("host", "127.0.0.1")
        self.port = int(mq.get("port", 1884))
        self.min_interval = int(pub.get("min_interval", 60))
        self.offline_after = int(pub.get("offline_after", 900))
        self.sensors = {}
        for s in cfg.get("sensore", []):
            mac = s["mac"].upper()
            self.sensors[mac] = {"name": s["nome"], "last": {}, "last_pub": {},
                                 "last_seen": None, "online": None}
        if not self.sensors:
            raise SystemExit("Nessun [[sensore]] nella configurazione")
        self.models = {}
        self.client = None
        self.started = time.monotonic()

    # --- MQTT ---------------------------------------------------------------
    def mqtt_start(self):
        import paho.mqtt.client as mqtt
        cid = "homehub-switchbot"
        try:
            self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid)
        except AttributeError:          # paho-mqtt 1.x
            self.client = mqtt.Client(client_id=cid)
        self.client.will_set(f"{self.prefix}/bridge/status", "offline", qos=1, retain=True)
        self.client.on_connect = self.on_connect
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)
        self.client.connect_async(self.host, self.port, keepalive=60)
        self.client.loop_start()

    def on_connect(self, client, userdata, flags, *rest):
        client.publish(f"{self.prefix}/bridge/status", "online", qos=1, retain=True)
        log(f"MQTT collegato a {self.host}:{self.port}")
        for s in self.sensors.values():
            if s["online"] is not None:   # stato deciso prima della connessione
                self.publish(s["name"], "status", "online" if s["online"] else "offline")
            s["last_pub"].clear()         # ripubblica tutto al prossimo annuncio

    def publish(self, name, field, value):
        self.client.publish(f"{self.prefix}/{name}/{field}", str(value), qos=0, retain=True)

    def mqtt_stop(self):
        if self.client:
            info = self.client.publish(f"{self.prefix}/bridge/status", "offline", qos=1, retain=True)
            try:
                info.wait_for_publish(5)
            except Exception:
                pass
            self.client.loop_stop()
            self.client.disconnect()

    # --- annunci ------------------------------------------------------------
    def on_adv(self, device, adv):
        mfr, svc = extract(adv)
        if mfr is None and svc is None:
            return
        d = decode(device.address, mfr, svc, self.models.get(device.address))
        if d is None:
            return
        if d["model"]:
            self.models[device.address] = d["model"]
        s = self.sensors.get(d["mac"]) or self.sensors.get(d["address"])
        if s is None or d["temperature"] is None:
            return

        t = time.monotonic()
        s["last_seen"] = t
        if s["online"] is not True:
            s["online"] = True
            self.publish(s["name"], "status", "online")
            log(f"{s['name']}: online ({d['mac']}, {d['model_name']})")

        values = {
            "temperature": f"{d['temperature']:.1f}",
            "humidity": d["humidity"],
            "battery": d["battery"],
            "rssi": getattr(adv, "rssi", None),
        }
        for field, value in values.items():
            if value is None:
                continue
            changed = s["last"].get(field) != value and field != "rssi"
            due = t - s["last_pub"].get(field, -1e9) >= self.min_interval
            if changed or due:
                self.publish(s["name"], field, value)
                s["last"][field] = value
                s["last_pub"][field] = t
        if t - s["last_pub"].get("last_seen", -1e9) >= self.min_interval:
            self.publish(s["name"], "last_seen", now_iso())
            s["last_pub"]["last_seen"] = t

    def check_offline(self):
        t = time.monotonic()
        for s in self.sensors.values():
            stale = s["last_seen"] is None or t - s["last_seen"] > self.offline_after
            if stale and s["online"] is not False and (
                    s["last_seen"] is not None or t - self.started > self.offline_after):
                s["online"] = False
                self.publish(s["name"], "status", "offline")
                log(f"{s['name']}: offline (nessun annuncio da {self.offline_after} s)")


def log(msg):
    print(msg, flush=True)


async def run_service(cfg_path):
    import tomllib
    with open(cfg_path, "rb") as f:
        cfg = tomllib.load(f)
    bridge = Bridge(cfg)
    names = ", ".join(f"{s['name']}={mac}" for mac, s in bridge.sensors.items())
    log(f"switchbot-mqtt: sensori {names}")
    bridge.mqtt_start()

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    scanner = make_scanner(bridge.on_adv)
    await scanner.start()
    log("Bluetooth: ascolto avviato")
    try:
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=30)
            except asyncio.TimeoutError:
                bridge.check_offline()
    finally:
        await scanner.stop()
        bridge.mqtt_stop()
        log("switchbot-mqtt: fermato")
    return 0


def main():
    parser = argparse.ArgumentParser(description="SwitchBot BLE -> MQTT")
    parser.add_argument("--config", default="/etc/homehub/switchbot.toml")
    parser.add_argument("--scan", type=int, metavar="SECONDI",
                        help="elenca i dispositivi SwitchBot che si sentono e termina")
    args = parser.parse_args()
    if args.scan:
        return asyncio.run(run_scan(args.scan))
    return asyncio.run(run_service(args.config))


if __name__ == "__main__":
    sys.exit(main())
