"""Agrega sinais de comportamento do GA4 por cliente do CDP.

Le os arquivos de export locais (../ga4_bigquery_export/events/*.json.gz) um
dia por vez -- parseando o NDJSON em Python puro, sem motor de SQL local --
filtrando pelos user_pseudo_id dos clientes conhecidos, e grava apenas o
resultado agregado em raw.ga4_customer_behavior e em
raw.ga4_promotion_engagement (exposição a campanha por cliente, usada pelo
modelo de propensão de campanha).

Carga incremental: a etapa cara (ler e filtrar o JSON bruto) usa um cursor
(raw._ga4_customer_events_scan_state) pra saber até que data de arquivo já
foi escaneado, e só processa arquivos posteriores a ela (a data está no nome
do arquivo, events_YYYYMMDD.json.gz). O cursor marca "já escaneei", não
"achei match" -- não dá pra derivar isso de max(event_date) na própria
tabela filtrada porque nos dados reais os primeiros ~422 dos 722 dias não
têm nenhum evento de cliente conhecido (os clientes só passam a aparecer no
GA4 a partir de set/2025); sem o cursor, esses dias sem match seriam
re-escaneados do zero em toda execução. Cada execução grava uma linha nova
no cursor (append-only -- ClickHouse não tem UPDATE síncrono barato) e a
leitura pega a mais recente por updated_at. raw._ga4_customer_events_filtered
persiste entre execuções em vez de ser recriada, e a agregação final
(barata, já opera só sobre eventos filtrados) é sempre recalculada por
completo a partir dela.

Limitação: um cliente que só passou a existir em raw.cdp_customer_profiles
depois que seus dias de evento já foram processados não terá esses eventos
antigos retroativamente incluídos (eles foram descartados no filtro daquela
execução). Rode com FORCE_RELOAD=1 pra reprocessar tudo do zero quando isso
importar (ex.: import retroativo de clientes) ou quando a lógica de
agregação abaixo mudar.
"""

from __future__ import annotations

import glob
import gzip
import json
import os
import re
import sys
from datetime import datetime, timezone

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

FILTERED_TABLE = f"{CLICKHOUSE_DATABASE}._ga4_customer_events_filtered"
SCAN_STATE_TABLE = f"{CLICKHOUSE_DATABASE}._ga4_customer_events_scan_state"
FILTERED_COLUMNS = [
    "user_pseudo_id", "event_date", "event_datetime", "event_name",
    "geo_country", "geo_region", "geo_city", "device_category",
    "traffic_source_name", "items",
]


def file_date(path: str) -> str:
    match = FILENAME_DATE_RE.search(os.path.basename(path))
    if not match:
        raise ValueError(f"Could not find a YYYYMMDD date in filename: {path}")
    return match.group(1)


def filter_file(path: str, customer_ids: set[str]) -> list[tuple]:
    """Le um dia de eventos (NDJSON.gz) e mantem so os de clientes conhecidos."""
    rows = []
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            user_pseudo_id = event.get("user_pseudo_id")
            if user_pseudo_id not in customer_ids:
                continue
            geo = event.get("geo") or {}
            device = event.get("device") or {}
            traffic_source = event.get("traffic_source") or {}
            event_timestamp = event.get("event_timestamp") or 0
            event_datetime = datetime.fromtimestamp(event_timestamp / 1_000_000, tz=timezone.utc).replace(tzinfo=None)
            rows.append((
                user_pseudo_id,
                event.get("event_date") or "",
                event_datetime,
                event.get("event_name") or "",
                geo.get("country") or "",
                geo.get("region") or "",
                geo.get("city") or "",
                device.get("category") or "",
                traffic_source.get("name") or "",
                json.dumps(event.get("items") or []),
            ))
    return rows


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
        client.command(f"DROP TABLE IF EXISTS {FILTERED_TABLE}")
        client.command(f"DROP TABLE IF EXISTS {SCAN_STATE_TABLE}")

    client.command(f"""
        CREATE TABLE IF NOT EXISTS {SCAN_STATE_TABLE} (
            last_scanned_date String,
            updated_at DateTime
        ) ENGINE = MergeTree ORDER BY updated_at
    """)
    client.command(f"""
        CREATE TABLE IF NOT EXISTS {FILTERED_TABLE} (
            user_pseudo_id String,
            event_date String,
            event_datetime DateTime,
            event_name String,
            geo_country String,
            geo_region String,
            geo_city String,
            device_category String,
            traffic_source_name String,
            items String
        ) ENGINE = MergeTree ORDER BY (user_pseudo_id, event_datetime)
    """)

    watermark_rows = client.query(
        f"SELECT last_scanned_date FROM {SCAN_STATE_TABLE} ORDER BY updated_at DESC LIMIT 1"
    ).result_rows
    watermark = watermark_rows[0][0] if watermark_rows else None
    if watermark:
        files = [f for f in files if file_date(f) > watermark]
    if MAX_DAYS:
        files = files[:MAX_DAYS]

    if not files:
        print(f"raw._ga4_customer_events_filtered already up to date (watermark={watermark}). "
              f"Nothing to do.", flush=True)
        return 0

    customer_ids = {
        row[0] for row in client.query(
            f"SELECT DISTINCT identity_userpseudoid FROM {CLICKHOUSE_DATABASE}.cdp_customer_profiles "
            f"WHERE identity_userpseudoid != ''"
        ).result_rows
    }
    print(
        f"Filtering {len(files)} new day(s) ({files[0]} .. {files[-1]}) down to "
        f"{len(customer_ids)} known customer user_pseudo_ids. "
        f"Watermark before this run: {watermark or 'none'}...",
        flush=True,
    )

    total_matched = 0
    for i, f in enumerate(files):
        rows = filter_file(f, customer_ids)
        if rows:
            client.insert(FILTERED_TABLE, rows, column_names=FILTERED_COLUMNS)
            total_matched += len(rows)
        if (i + 1) % 50 == 0 or i == len(files) - 1:
            print(f"[{i + 1}/{len(files)}] {os.path.basename(f)}: "
                  f"{total_matched} matching rows so far", flush=True)

    client.insert(
        SCAN_STATE_TABLE,
        [(file_date(files[-1]), datetime.now(timezone.utc).replace(tzinfo=None))],
        column_names=["last_scanned_date", "updated_at"],
    )

    total_matched = client.query(f"SELECT count(*) FROM {FILTERED_TABLE}").result_rows[0][0]
    print(f"Matched {total_matched} events across {len(files)} days. Aggregating...", flush=True)

    client.command(f"""
        CREATE OR REPLACE TABLE {CLICKHOUSE_DATABASE}.ga4_customer_behavior
        ENGINE = MergeTree ORDER BY user_pseudo_id
        AS
        with events as (
            select * from {FILTERED_TABLE}
        ),
        activity as (
            select
                user_pseudo_id,
                count(*) as total_events,
                count(distinct event_date) as distinct_days_active,
                min(event_datetime) as ga4_first_seen_at,
                max(event_datetime) as ga4_last_seen_at
            from events
            group by 1
        ),
        location_counts as (
            select user_pseudo_id, geo_country, geo_region, geo_city, count(*) as cnt
            from events
            where geo_country != ''
            group by 1, 2, 3, 4
        ),
        top_location as (
            select user_pseudo_id, geo_country, geo_region, geo_city
            from (
                select *, row_number() over (partition by user_pseudo_id order by cnt desc) as rn
                from location_counts
            )
            where rn = 1
        ),
        device_counts as (
            select user_pseudo_id, device_category, count(*) as cnt
            from events
            where device_category != ''
            group by 1, 2
        ),
        top_device as (
            select user_pseudo_id, device_category
            from (
                select *, row_number() over (partition by user_pseudo_id order by cnt desc) as rn
                from device_counts
            )
            where rn = 1
        ),
        viewed_items as (
            select
                e.user_pseudo_id,
                JSONExtractString(i_json, 'item_category') as item_category,
                JSONExtractString(i_json, 'item_brand') as item_brand
            from events e
            array join JSONExtractArrayRaw(e.items) as i_json
            where e.event_name in ('view_item', 'select_item')
        ),
        category_counts as (
            select user_pseudo_id, item_category, count(*) as cnt
            from viewed_items
            where item_category != ''
            group by 1, 2
        ),
        top_viewed_category as (
            select user_pseudo_id, item_category as viewed_top_category
            from (
                select *, row_number() over (partition by user_pseudo_id order by cnt desc) as rn
                from category_counts
            )
            where rn = 1
        ),
        brand_counts as (
            select user_pseudo_id, item_brand, count(*) as cnt
            from viewed_items
            where item_brand != ''
            group by 1, 2
        ),
        top_viewed_brand as (
            select user_pseudo_id, item_brand as viewed_top_brand
            from (
                select *, row_number() over (partition by user_pseudo_id order by cnt desc) as rn
                from brand_counts
            )
            where rn = 1
        )
        select
            a.user_pseudo_id as user_pseudo_id,
            a.total_events as total_events,
            a.distinct_days_active as distinct_days_active,
            a.ga4_first_seen_at as ga4_first_seen_at,
            a.ga4_last_seen_at as ga4_last_seen_at,
            tl.geo_country as location_country,
            tl.geo_region as location_region,
            tl.geo_city as location_city,
            td.device_category as preferred_device_category,
            tvc.viewed_top_category,
            tvb.viewed_top_brand
        from activity a
        left join top_location tl on a.user_pseudo_id = tl.user_pseudo_id
        left join top_device td on a.user_pseudo_id = td.user_pseudo_id
        left join top_viewed_category tvc on a.user_pseudo_id = tvc.user_pseudo_id
        left join top_viewed_brand tvb on a.user_pseudo_id = tvb.user_pseudo_id
    """)

    # Exposição a campanha por cliente: view_promotion/select_promotion,
    # com o slug da campanha em traffic_source.name (bate com
    # promotions.utmiCampaign). Alimenta feature/feat_promotion_engagement.sql.
    client.command(f"""
        CREATE OR REPLACE TABLE {CLICKHOUSE_DATABASE}.ga4_promotion_engagement
        ENGINE = MergeTree ORDER BY (user_pseudo_id, promotion_slug)
        AS
        with promo_events as (
            select user_pseudo_id, event_name, event_datetime, traffic_source_name
            from {FILTERED_TABLE}
            where event_name in ('view_promotion', 'select_promotion')
              and traffic_source_name != ''
              and traffic_source_name not in ('(direct)', '(email)', '(organic)',
                                               '(referral)', '(none)')
        )
        select
            user_pseudo_id,
            traffic_source_name as promotion_slug,
            countIf(event_name = 'view_promotion') as view_count,
            countIf(event_name = 'select_promotion') as select_count,
            min(event_datetime) as first_seen_at,
            max(event_datetime) as last_seen_at
        from promo_events
        group by 1, 2
    """)

    total = client.query(f"SELECT count(*) FROM {CLICKHOUSE_DATABASE}.ga4_customer_behavior").result_rows[0][0]
    promo_total = client.query(
        f"SELECT count(*) FROM {CLICKHOUSE_DATABASE}.ga4_promotion_engagement"
    ).result_rows[0][0]
    print(f"Done. raw.ga4_customer_behavior has {total} rows (out of {len(customer_ids)} customers). "
          f"raw.ga4_promotion_engagement has {promo_total} rows.",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
