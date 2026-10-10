#!/usr/bin/env python3
"""camper-export - esporta le righe nuove di history.db di Camper Hub.

Gira su LeoRaspy, installato in /usr/local/bin/camper-export, come comando
forzato dell'unica chiave SSH dell'utente homehub-export (vedi
setup-camper-export.sh). Qualunque altro comando viene rifiutato.

Comando ricevuto in SSH_ORIGINAL_COMMAND:
  info
      conteggi e ultime chiavi delle tabelle, in JSON
  export samples=<ts> event_log=<id> bds_events=<id>
      righe con chiave maggiore del valore indicato (0 = tutte)

Uscita di export, JSON lines compresse con gzip:
  {"table": "samples", "key": "ts", "columns": [["ts", "INTEGER"], ...]}
  [valore, valore, ...]              una riga per record, ordinate per chiave
  ...                                (stesso schema per event_log e bds_events)
  {"end": true, "counts": {"samples": N, "event_log": N, "bds_events": N}}

La riga "end" arriva solo se l'esportazione e' completa: senza di lei il
Home Hub scarta tutto (connessione caduta a meta').

Il database si apre in sola lettura. sms_seen non si esporta: contiene il
testo degli SMS. Solo libreria standard di Python.
"""

import gzip
import json
import os
import re
import sqlite3
import sys

DB = "/var/lib/camper-hub/history.db"

# tabella -> colonna chiave (crescente)
TABLES = {
    "samples": "ts",
    "event_log": "id",
    "bds_events": "id",
}


def fail(msg, code=2):
    sys.stderr.write("camper-export: " + msg + "\n")
    sys.exit(code)


def connect():
    if not os.path.exists(DB):
        fail("database assente: " + DB, 3)
    db = sqlite3.connect("file:" + DB + "?mode=ro", uri=True, timeout=30)
    db.execute("PRAGMA query_only = 1")
    return db


def cmd_info(db):
    out = {}
    for table, key in TABLES.items():
        rows, last = db.execute(
            f"SELECT COUNT(*), MAX({key}) FROM {table}"
        ).fetchone()
        out[table] = {"rows": rows, "last_" + key: last}
    print(json.dumps(out))


def cmd_export(db, cursors):
    counts = {}
    with gzip.GzipFile(fileobj=sys.stdout.buffer, mode="wb", mtime=0) as gz:

        def emit(obj):
            gz.write(
                (json.dumps(obj, separators=(",", ":"), default=str) + "\n")
                .encode("utf-8")
            )

        for table, key in TABLES.items():
            columns = [
                [row[1], row[2]]
                for row in db.execute(f"PRAGMA table_info({table})")
            ]
            emit({"table": table, "key": key, "columns": columns})
            n = 0
            for row in db.execute(
                f"SELECT * FROM {table} WHERE {key} > ? ORDER BY {key}",
                (cursors[table],),
            ):
                emit(list(row))
                n += 1
            counts[table] = n

        emit({"end": True, "counts": counts})


def main():
    cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "").strip()

    if cmd == "info":
        cmd_info(connect())
        return

    match = re.fullmatch(r"export((?: [a-z_]+=\d{1,12}){1,3})", cmd)
    if not match:
        fail("comando non ammesso")

    cursors = dict.fromkeys(TABLES, 0)
    for part in match.group(1).split():
        name, value = part.split("=")
        if name not in TABLES:
            fail("tabella non ammessa: " + name)
        cursors[name] = int(value)

    cmd_export(connect(), cursors)


if __name__ == "__main__":
    main()
