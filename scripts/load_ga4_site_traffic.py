"""Agrega trafego de sessao do GA4 (todos os visitantes, nao so clientes do CDP).

Le os arquivos de export locais (../ga4_bigquery_export/events/*.json.gz) um
dia por vez e grava, por dia/plataforma/midia, contagem de sessoes e de
sessoes com evento de purchase em raw.ga4_site_traffic. Ao contrario de
load_ga4_customer_behavior.py, nao filtra por user_pseudo_id conhecido: o
objetivo aqui e medir taxa de conversao real (sessao -> compra), que exige
o trafego anonimo que aquele script descarta.
"""

from __future__ import annotations

import glob
import os
import sys

import duckdb

WAREHOUSE_PATH = os.environ.get("WAREHOUSE_PATH", "/output/warehouse.duckdb")
SOURCE_GLOB = os.environ.get("GA4_SOURCE_GLOB", "/ga4_source/events/events_*.json.gz")
MAX_DAYS = int(os.environ["MAX_DAYS"]) if os.environ.get("MAX_DAYS") else None


def main() -> int:
    files = sorted(glob.glob(SOURCE_GLOB))
    if not files:
        print(f"No files matched {SOURCE_GLOB}", file=sys.stderr)
        return 1
    if MAX_DAYS:
        files = files[:MAX_DAYS]

    con = duckdb.connect(WAREHOUSE_PATH)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")
    con.execute("""
        CREATE OR REPLACE TABLE raw.ga4_site_traffic (
            event_date VARCHAR,
            platform VARCHAR,
            medium VARCHAR,
            sessions BIGINT,
            purchasing_sessions BIGINT,
            visitors BIGINT
        )
    """)

    print(f"Aggregating session traffic from {len(files)} day(s) "
          f"({files[0]} .. {files[-1]}), all visitors (no customer filter)...",
          flush=True)

    for i, f in enumerate(files):
        con.execute(f"""
            insert into raw.ga4_site_traffic
            with events as (
                select
                    event_date,
                    platform,
                    traffic_source.medium as medium,
                    list_filter(event_params, x -> x.key = 'ga_session_id')[1].value.int_value as session_id,
                    event_name,
                    user_pseudo_id
                from read_json_auto('{f}')
            )
            select
                event_date,
                platform,
                medium,
                count(distinct session_id) as sessions,
                count(distinct case when event_name = 'purchase' then session_id end) as purchasing_sessions,
                count(distinct user_pseudo_id) as visitors
            from events
            group by 1, 2, 3
        """)
        if (i + 1) % 50 == 0 or i == len(files) - 1:
            running_total = con.execute(
                "SELECT count(*), sum(sessions), sum(purchasing_sessions) FROM raw.ga4_site_traffic"
            ).fetchone()
            print(f"[{i + 1}/{len(files)}] {os.path.basename(f)}: "
                  f"{running_total[0]} rows so far "
                  f"({running_total[1]} sessions, {running_total[2]} com purchase)", flush=True)

    total = con.execute(
        "SELECT count(*), sum(sessions), sum(purchasing_sessions) FROM raw.ga4_site_traffic"
    ).fetchone()
    print(f"Done. raw.ga4_site_traffic has {total[0]} rows: "
          f"{total[1]} sessoes, {total[2]} com purchase.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
