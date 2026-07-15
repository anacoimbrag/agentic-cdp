"""Agrega sinais de comportamento do GA4 por cliente do CDP.

Lê os arquivos de export locais (../ga4_bigquery_export/events/*.json.gz) um
dia por vez, filtrando pelos user_pseudo_id dos clientes conhecidos, e grava
apenas o resultado agregado em raw.ga4_customer_behavior e em
raw.ga4_promotion_engagement (exposição a campanha por cliente, usada pelo
modelo de propensão de campanha).

Carga incremental: a etapa cara (ler e filtrar o JSON bruto) usa um cursor
de 1 linha (raw._ga4_customer_events_scan_state) pra saber até que data de
arquivo já foi escaneado, e só processa arquivos posteriores a ela (a data
está no nome do arquivo, events_YYYYMMDD.json.gz). O cursor marca "já
escaneei", não "achei match" -- não dá pra derivar isso de
max(event_date) na própria tabela filtrada porque nos dados reais os
primeiros ~422 dos 722 dias não têm nenhum evento de cliente conhecido
(os clientes só passam a aparecer no GA4 a partir de set/2025); sem o
cursor, esses dias sem match seriam re-escaneados do zero em toda
execução. raw._ga4_customer_events_filtered persiste entre execuções em
vez de ser recriada, e a agregação final (barata, já opera só sobre
eventos filtrados) é sempre recalculada por completo a partir dela.

Limitação: um cliente que só passou a existir em raw.cdp_customer_profiles
depois que seus dias de evento já foram processados não terá esses eventos
antigos retroativamente incluídos (eles foram descartados no filtro daquela
execução). Rode com FORCE_RELOAD=1 pra reprocessar tudo do zero quando isso
importar (ex.: import retroativo de clientes) ou quando a lógica de
agregação abaixo mudar.
"""

from __future__ import annotations

import glob
import os
import re
import sys

import duckdb

WAREHOUSE_PATH = os.environ.get("WAREHOUSE_PATH", "/output/warehouse.duckdb")
SOURCE_GLOB = os.environ.get("GA4_SOURCE_GLOB", "/ga4_source/events/events_*.json.gz")
MAX_DAYS = int(os.environ["MAX_DAYS"]) if os.environ.get("MAX_DAYS") else None
FORCE_RELOAD = os.environ.get("FORCE_RELOAD") == "1"

FILENAME_DATE_RE = re.compile(r"(\d{8})")


def file_date(path: str) -> str:
    match = FILENAME_DATE_RE.search(os.path.basename(path))
    if not match:
        raise ValueError(f"Could not find a YYYYMMDD date in filename: {path}")
    return match.group(1)


def main() -> int:
    files = sorted(glob.glob(SOURCE_GLOB))
    if not files:
        print(f"No files matched {SOURCE_GLOB}", file=sys.stderr)
        return 1

    con = duckdb.connect(WAREHOUSE_PATH)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")

    if FORCE_RELOAD:
        con.execute("DROP TABLE IF EXISTS raw._ga4_customer_events_filtered")
        con.execute("DROP TABLE IF EXISTS raw._ga4_customer_events_scan_state")

    con.execute("""
        CREATE TABLE IF NOT EXISTS raw._ga4_customer_events_scan_state (
            last_scanned_date VARCHAR
        )
    """)
    if con.execute("SELECT count(*) FROM raw._ga4_customer_events_scan_state").fetchone()[0] == 0:
        con.execute("INSERT INTO raw._ga4_customer_events_scan_state VALUES (NULL)")

    con.execute("""
        CREATE TABLE IF NOT EXISTS raw._ga4_customer_events_filtered AS
        with customer_ids as (
            select distinct identity_userpseudoid as user_pseudo_id
            from raw.cdp_customer_profiles
            where identity_userpseudoid is not null
        )
        select
            cast(null as varchar) as user_pseudo_id,
            cast(null as varchar) as event_date,
            cast(null as timestamp) as event_datetime,
            cast(null as varchar) as event_name,
            cast(null as varchar) as geo_country,
            cast(null as varchar) as geo_region,
            cast(null as varchar) as geo_city,
            cast(null as varchar) as device_category,
            cast(null as varchar) as traffic_source_name,
            cast(null as struct(item_id varchar, item_name varchar, item_brand varchar,
                 item_variant varchar, item_category varchar, item_category2 varchar,
                 price double, quantity bigint, item_revenue double, coupon varchar,
                 item_list_name varchar, item_list_index bigint, promotion_id varchar,
                 promotion_name varchar)[]) as items
        from customer_ids
        where false
    """)

    watermark = con.execute(
        "SELECT last_scanned_date FROM raw._ga4_customer_events_scan_state"
    ).fetchone()[0]
    if watermark:
        files = [f for f in files if file_date(f) > watermark]
    if MAX_DAYS:
        files = files[:MAX_DAYS]

    if not files:
        print(f"raw._ga4_customer_events_filtered already up to date (watermark={watermark}). "
              f"Nothing to do.", flush=True)
        return 0

    customer_count = con.execute(
        "SELECT count(*) FROM raw.cdp_customer_profiles"
    ).fetchone()[0]
    print(
        f"Filtering {len(files)} new day(s) ({files[0]} .. {files[-1]}) down to "
        f"{customer_count} known customer user_pseudo_ids. "
        f"Watermark before this run: {watermark or 'none'}...",
        flush=True,
    )

    for i, f in enumerate(files):
        con.execute(f"""
            insert into raw._ga4_customer_events_filtered
            with customer_ids as (
                select distinct identity_userpseudoid as user_pseudo_id
                from raw.cdp_customer_profiles
                where identity_userpseudoid is not null
            )
            select
                g.user_pseudo_id,
                g.event_date,
                to_timestamp(g.event_timestamp / 1000000.0) as event_datetime,
                g.event_name,
                g.geo.country as geo_country,
                g.geo.region as geo_region,
                g.geo.city as geo_city,
                g.device.category as device_category,
                g.traffic_source.name as traffic_source_name,
                g.items
            from read_json_auto('{f}') g
            inner join customer_ids c on g.user_pseudo_id = c.user_pseudo_id
        """)
        if (i + 1) % 50 == 0 or i == len(files) - 1:
            running_total = con.execute(
                "SELECT count(*) FROM raw._ga4_customer_events_filtered"
            ).fetchone()[0]
            print(f"[{i + 1}/{len(files)}] {os.path.basename(f)}: "
                  f"{running_total} matching rows so far", flush=True)

    con.execute(
        "UPDATE raw._ga4_customer_events_scan_state SET last_scanned_date = ?",
        [file_date(files[-1])],
    )

    total_matched = con.execute(
        "SELECT count(*) FROM raw._ga4_customer_events_filtered"
    ).fetchone()[0]
    print(f"Matched {total_matched} events across {len(files)} days. Aggregating...",
          flush=True)

    con.execute("""
        CREATE OR REPLACE TABLE raw.ga4_customer_behavior AS
        with events as (
            select * from raw._ga4_customer_events_filtered
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
            where geo_country is not null
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
            where device_category is not null
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
            select e.user_pseudo_id, i.item_category, i.item_brand
            from events e
            cross join unnest(e.items) as t(i)
            where e.event_name in ('view_item', 'select_item')
        ),
        category_counts as (
            select user_pseudo_id, item_category, count(*) as cnt
            from viewed_items
            where item_category is not null
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
            where item_brand is not null
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
            a.user_pseudo_id,
            a.total_events,
            a.distinct_days_active,
            a.ga4_first_seen_at,
            a.ga4_last_seen_at,
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
    con.execute("""
        CREATE OR REPLACE TABLE raw.ga4_promotion_engagement AS
        with promo_events as (
            select user_pseudo_id, event_name, event_datetime, traffic_source_name
            from raw._ga4_customer_events_filtered
            where event_name in ('view_promotion', 'select_promotion')
              and traffic_source_name is not null
              and traffic_source_name not in ('(direct)', '(email)', '(organic)',
                                               '(referral)', '(none)')
        )
        select
            user_pseudo_id,
            traffic_source_name as promotion_slug,
            count(*) filter (where event_name = 'view_promotion') as view_count,
            count(*) filter (where event_name = 'select_promotion') as select_count,
            min(event_datetime) as first_seen_at,
            max(event_datetime) as last_seen_at
        from promo_events
        group by 1, 2
    """)

    total = con.execute("SELECT count(*) FROM raw.ga4_customer_behavior").fetchone()[0]
    promo_total = con.execute("SELECT count(*) FROM raw.ga4_promotion_engagement").fetchone()[0]
    print(f"Done. raw.ga4_customer_behavior has {total} rows (out of {customer_count} customers). "
          f"raw.ga4_promotion_engagement has {promo_total} rows.",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
