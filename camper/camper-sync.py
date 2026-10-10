#!/usr/bin/env python3
"""camper-sync - copia sul Home Hub le righe nuove di history.db di Camper Hub.

Gira sul Home Hub come utente openhabian (timer systemd camper-sync.timer).
Chiede a LeoRaspy, via SSH con la chiave dedicata ~/.ssh/camper-export, le
righe successive all'ultima gia' presente nel database locale e le aggiunge.
Non cancella mai nulla: lo storico locale supera i 90 giorni del camper, e
se il camper e' offline la sincronizzazione successiva recupera tutto.

L'importazione avviene in una sola transazione e viene confermata solo se
LeoRaspy ha inviato la riga finale di chiusura con i conteggi giusti.

Uso:
  python3 camper-sync.py           sincronizza
  python3 camper-sync.py --info    stato remoto (LeoRaspy) e locale, senza copiare

Uscita 0 = ok, 1 = errore (camper non raggiungibile, dati incompleti...).
Solo libreria standard di Python.
"""

import argparse
import gzip
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

LOCAL_DB = "/var/lib/homehub/camper-history.db"
REMOTE = "homehub-export@10.8.0.5"
KEY = os.path.expanduser("~/.ssh/camper-export")

# tabella -> colonna chiave; deve coincidere con camper-export.py
TABLES = {
    "samples": "ts",
    "event_log": "id",
    "bds_events": "id",
}

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
TYPE_RE = re.compile(r"[A-Za-z ]{0,32}")


def log(msg):
    print(msg, flush=True)


def ssh_cmd(args, remote_command):
    return [
        "ssh", "-i", args.key,
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=30",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=4",
        args.remote,
        remote_command,
    ]


class CountingReader:
    """Conta i byte ricevuti (compressi) per stimare il traffico sul 4G."""

    def __init__(self, raw):
        self.raw = raw
        self.bytes = 0

    def read(self, n=-1):
        data = self.raw.read(n)
        self.bytes += len(data)
        return data


def table_exists(db, table):
    return db.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table,),
    ).fetchone() is not None


def local_cursor(db, table, key):
    if not table_exists(db, table):
        return 0
    return db.execute(
        f'SELECT COALESCE(MAX("{key}"), 0) FROM "{table}"'
    ).fetchone()[0]


def ensure_table(db, table, key, columns):
    """Crea la tabella o aggiunge le colonne nuove comparse su Camper Hub."""
    if not table_exists(db, table):
        defs = []
        for name, ctype in columns:
            if name == key:
                defs.append(f'"{name}" INTEGER PRIMARY KEY')
            else:
                defs.append(f'"{name}" {ctype}')
        db.execute(f'CREATE TABLE "{table}" ({", ".join(defs)})')
        if key != "ts" and any(name == "ts" for name, _ in columns):
            db.execute(
                f'CREATE INDEX IF NOT EXISTS "idx_{table}_ts" ON "{table}"(ts)'
            )
        return
    have = {row[1] for row in db.execute(f'PRAGMA table_info("{table}")')}
    for name, ctype in columns:
        if name not in have:
            db.execute(f'ALTER TABLE "{table}" ADD COLUMN "{name}" {ctype}')
            log(f"camper-sync: nuova colonna {table}.{name} ({ctype})")


def check_header(obj):
    table = obj.get("table")
    key = obj.get("key")
    columns = obj.get("columns")
    if table not in TABLES or key != TABLES[table]:
        raise ValueError(f"intestazione inattesa: {table}/{key}")
    if not isinstance(columns, list) or not columns:
        raise ValueError(f"colonne mancanti per {table}")
    for col in columns:
        if (not isinstance(col, list) or len(col) != 2
                or not NAME_RE.fullmatch(str(col[0]))
                or not TYPE_RE.fullmatch(str(col[1]))):
            raise ValueError(f"colonna non valida in {table}: {col!r}")
    if key not in [c[0] for c in columns]:
        raise ValueError(f"chiave {key} assente in {table}")
    return table, key, columns


def cmd_info(args):
    proc = subprocess.run(
        ssh_cmd(args, "info"), capture_output=True, text=True, timeout=120
    )
    if proc.returncode != 0:
        log("LeoRaspy: errore - " + proc.stderr.strip())
    else:
        log("LeoRaspy: " + proc.stdout.strip())
    if os.path.exists(args.db):
        db = sqlite3.connect(args.db)
        local = {}
        for table, key in TABLES.items():
            if table_exists(db, table):
                rows, last = db.execute(
                    f'SELECT COUNT(*), MAX("{key}") FROM "{table}"'
                ).fetchone()
                local[table] = {"rows": rows, "last_" + key: last}
        log("Home Hub: " + json.dumps(local))
        log(f"Home Hub: {args.db}, {os.path.getsize(args.db) / 1e6:.1f} MB")
    else:
        log(f"Home Hub: {args.db} non ancora creato")
    return 0 if proc.returncode == 0 else 1


def cmd_sync(args):
    db = sqlite3.connect(args.db, isolation_level=None, timeout=30)

    cursors = {t: local_cursor(db, t, k) for t, k in TABLES.items()}
    remote_command = "export " + " ".join(f"{t}={cursors[t]}" for t in TABLES)
    log("camper-sync: " + remote_command)

    started = time.monotonic()
    proc = subprocess.Popen(
        ssh_cmd(args, remote_command),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    reader = CountingReader(proc.stdout)
    counts = {}
    end = None
    error = None

    db.execute("BEGIN")
    try:
        sql = None
        table = None
        width = 0
        with gzip.GzipFile(fileobj=reader, mode="rb") as gz:
            for raw in gz:
                obj = json.loads(raw)
                if isinstance(obj, dict):
                    if obj.get("end"):
                        end = obj
                        break
                    table, key, columns = check_header(obj)
                    ensure_table(db, table, key, columns)
                    names = ", ".join(f'"{c[0]}"' for c in columns)
                    width = len(columns)
                    sql = (f'INSERT OR IGNORE INTO "{table}" ({names}) '
                           f'VALUES ({", ".join("?" * width)})')
                    counts[table] = 0
                elif isinstance(obj, list) and sql and len(obj) == width:
                    db.execute(sql, obj)
                    counts[table] += 1
                else:
                    raise ValueError("riga inattesa nel flusso di dati")
            # fino alla fine del flusso: gzip verifica anche il CRC
            if gz.read():
                raise ValueError("dati dopo la riga finale")
    except Exception as exc:  # gzip troncato, JSON non valido, schema...
        error = f"{type(exc).__name__}: {exc}"
        proc.kill()
    try:
        rc = proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
        rc = proc.wait()
    stderr = proc.stderr.read().decode("utf-8", "replace").strip()

    if error is None and end is None:
        error = "flusso interrotto: manca la riga finale"
    if error is None and end.get("counts") != counts:
        error = f"conteggi diversi: inviati {end.get('counts')}, ricevuti {counts}"
    if error is None and rc != 0:
        error = f"ssh terminato con codice {rc}"

    if error:
        db.execute("ROLLBACK")
        log("camper-sync: ERRORE, nessuna riga importata - " + error)
        if stderr:
            log("camper-sync: ssh/LeoRaspy: " + stderr)
        return 1

    db.execute("COMMIT")
    seconds = time.monotonic() - started
    summary = ", ".join(f"{t} +{n}" for t, n in counts.items())
    log(f"camper-sync: ok - {summary}; {reader.bytes / 1024:.0f} kB ricevuti "
        f"in {seconds:.0f} s")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Copia incrementale di history.db di Camper Hub"
    )
    parser.add_argument("--info", action="store_true",
                        help="mostra lo stato remoto e locale senza copiare")
    parser.add_argument("--db", default=LOCAL_DB, help="database locale")
    parser.add_argument("--remote", default=REMOTE, help="utente@host di LeoRaspy")
    parser.add_argument("--key", default=KEY, help="chiave SSH privata")
    args = parser.parse_args()

    if args.info:
        return cmd_info(args)
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
