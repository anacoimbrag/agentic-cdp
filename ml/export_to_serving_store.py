"""Publica os resultados finais de ML (já materializados pelo dbt em
activation.*) num arquivo SQLite de leitura, pra API (ml/api/) consumir sem
disputar o ClickHouse com o dbt/treino.

Não reprocessa nada, só copia tabelas já prontas. Rode depois do `dbt build` completo (a versão
que já materializou customer_profile/customer_showcase com as colunas de
ML).
"""

from __future__ import annotations

import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common.db import connect  # noqa: E402

SQLITE_PATH = os.environ.get("SERVING_STORE_PATH", "/output/serving_store.sqlite")

CUSTOMER_PROFILE_COLUMNS = [
    "customer_id", "cluster_id", "segment_label", "tier", "segmented_at",
    "next_best_promotion_id", "next_best_promotion_name",
    "next_best_campaign_score", "next_best_campaign_reason", "campaign_scored_at",
]
CUSTOMER_SHOWCASE_COLUMNS = [
    "customer_id", "rank", "product_id", "sku_id", "reason", "score", "computed_at",
]


def export_table(ch_client, sqlite_con, source_table: str, columns: list[str], dest_table: str) -> int:
    rows = ch_client.query(f"SELECT {', '.join(columns)} FROM {source_table}").result_rows

    placeholders = ", ".join(columns)
    sqlite_con.execute(f"DROP TABLE IF EXISTS {dest_table}")
    sqlite_con.execute(f"CREATE TABLE {dest_table} ({placeholders})")
    sqlite_con.executemany(
        f"INSERT INTO {dest_table} VALUES ({', '.join('?' for _ in columns)})", rows
    )
    sqlite_con.execute(f"CREATE INDEX idx_{dest_table}_customer_id ON {dest_table} (customer_id)")
    return len(rows)


def main() -> int:
    ch_client = connect()

    os.makedirs(os.path.dirname(SQLITE_PATH) or ".", exist_ok=True)
    if os.path.exists(SQLITE_PATH):
        os.remove(SQLITE_PATH)
    sqlite_con = sqlite3.connect(SQLITE_PATH)

    n_profiles = export_table(
        ch_client, sqlite_con, "activation.customer_profile",
        CUSTOMER_PROFILE_COLUMNS, "customer_profile",
    )
    n_showcase = export_table(
        ch_client, sqlite_con, "activation.customer_showcase",
        CUSTOMER_SHOWCASE_COLUMNS, "customer_showcase",
    )

    sqlite_con.commit()
    sqlite_con.close()

    print(f"Done. {SQLITE_PATH}: customer_profile={n_profiles} linhas, "
          f"customer_showcase={n_showcase} linhas.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
