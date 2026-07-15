"""Agrega trafego de sessao do GA4 (todos os visitantes, nao so clientes do CDP).

Le os arquivos de export locais (../ga4_bigquery_export/events/*.json.gz) um
dia por vez -- parseando o NDJSON em Python puro, sem motor de SQL local -- e
grava, por dia/plataforma/midia, contagem de sessoes e de sessoes com evento
de purchase em raw.ga4_site_traffic. Ao contrario de
load_ga4_customer_behavior.py, nao filtra por user_pseudo_id conhecido: o
objetivo aqui e medir taxa de conversao real (sessao -> compra), que exige
o trafego anonimo que aquele script descarta.

Carga incremental: usa o maior event_date ja presente em
raw.ga4_site_traffic como watermark e so processa arquivos posteriores a
ele (a data esta no nome do arquivo, events_YYYYMMDD.json.gz). Rode com
FORCE_RELOAD=1 pra reprocessar tudo do zero -- necessario sempre que a
logica de agregacao abaixo mudar, pois dias ja carregados nao sao
retroativamente recalculados.
"""

from __future__ import annotations

import glob
import gzip
import json
import os
import re
import sys
from collections import defaultdict

import clickhouse_connect

CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")
CLICKHOUSE_DATABASE = os.environ.get("CLICKHOUSE_DATABASE", "raw")

SOURCE_GLOB = os.environ.get("GA4_SOURCE_GLOB", "/ga4_source/events/events_*.json.gz")
MAX_DAYS = int(os.environ["MAX_DAYS"]) if os.environ.get("MAX_DAYS") else None
FORCE_RELOAD = os.environ.get("FORCE_RELOAD") == "1"

FILENAME_DATE_RE = re.compile(r"(\d{8})")

TABLE = f"{CLICKHOUSE_DATABASE}.ga4_site_traffic"
COLUMNS = ["event_date", "platform", "medium", "sessions", "cart_sessions", "purchasing_sessions", "visitors"]


def file_date(path: str) -> str:
    match = FILENAME_DATE_RE.search(os.path.basename(path))
    if not match:
        raise ValueError(f"Could not find a YYYYMMDD date in filename: {path}")
    return match.group(1)


def aggregate_file(path: str) -> list[tuple]:
    """Le um dia de eventos (NDJSON.gz) e agrega por (event_date, platform, medium)."""
    groups: dict[tuple, dict[str, set]] = defaultdict(
        lambda: {"sessions": set(), "cart_sessions": set(), "purchasing_sessions": set(), "visitors": set()}
    )
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            event_name = event.get("event_name")
            user_pseudo_id = event.get("user_pseudo_id")
            session_id = next(
                (p["value"].get("int_value") for p in event.get("event_params") or []
                 if p.get("key") == "ga_session_id"),
                None,
            )
            key = (event.get("event_date"), event.get("platform"), (event.get("traffic_source") or {}).get("medium"))
            g = groups[key]
            if session_id is not None:
                g["sessions"].add(session_id)
                if event_name == "add_to_cart":
                    g["cart_sessions"].add(session_id)
                if event_name == "purchase":
                    g["purchasing_sessions"].add(session_id)
            if user_pseudo_id is not None:
                g["visitors"].add(user_pseudo_id)

    return [
        (event_date, platform, medium, len(g["sessions"]), len(g["cart_sessions"]),
         len(g["purchasing_sessions"]), len(g["visitors"]))
        for (event_date, platform, medium), g in groups.items()
    ]


def main() -> int:
    files = sorted(glob.glob(SOURCE_GLOB))
    if not files:
        print(f"No files matched {SOURCE_GLOB}", file=sys.stderr)
        return 1

    client = clickhouse_connect.get_client(
        host=CLICKHOUSE_HOST, port=CLICKHOUSE_PORT,
        username=CLICKHOUSE_USER, password=CLICKHOUSE_PASSWORD,
    )
    client.command(f"CREATE DATABASE IF NOT EXISTS {CLICKHOUSE_DATABASE}")

    if FORCE_RELOAD:
        client.command(f"DROP TABLE IF EXISTS {TABLE}")

    client.command(f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            event_date String,
            platform String,
            medium String,
            sessions Int64,
            cart_sessions Int64,
            purchasing_sessions Int64,
            visitors Int64
        ) ENGINE = MergeTree ORDER BY (event_date, platform, medium)
    """)

    watermark = client.query(f"SELECT max(event_date) FROM {TABLE}").result_rows[0][0]
    if watermark:
        files = [f for f in files if file_date(f) > watermark]
    if MAX_DAYS:
        files = files[:MAX_DAYS]

    if not files:
        print(f"raw.ga4_site_traffic already up to date (watermark={watermark}). Nothing to do.",
              flush=True)
        return 0

    print(f"Aggregating session traffic from {len(files)} new day(s) "
          f"({files[0]} .. {files[-1]}), all visitors (no customer filter). "
          f"Watermark before this run: {watermark or 'none'}...",
          flush=True)

    for i, f in enumerate(files):
        rows = aggregate_file(f)
        if rows:
            client.insert(TABLE, rows, column_names=COLUMNS)
        if (i + 1) % 50 == 0 or i == len(files) - 1:
            total = client.query(
                f"SELECT count(*), sum(sessions), sum(cart_sessions), sum(purchasing_sessions) FROM {TABLE}"
            ).result_rows[0]
            print(f"[{i + 1}/{len(files)}] {os.path.basename(f)}: "
                  f"{total[0]} rows so far "
                  f"({total[1]} sessions, {total[2]} com add_to_cart, {total[3]} com purchase)", flush=True)

    total = client.query(
        f"SELECT count(*), sum(sessions), sum(cart_sessions), sum(purchasing_sessions) FROM {TABLE}"
    ).result_rows[0]
    print(f"Done. raw.ga4_site_traffic has {total[0]} rows: "
          f"{total[1]} sessoes, {total[2]} com add_to_cart, {total[3]} com purchase.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
