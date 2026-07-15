"""Conexão ClickHouse e helpers de leitura/escrita compartilhados pelos scripts de treino."""

from __future__ import annotations

import os
from typing import Any

import clickhouse_connect
from clickhouse_connect.driver.client import Client

CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")

# Tipos DuckDB que os scripts de treino já passavam pra replace_table -- mapeados
# pro tipo ClickHouse equivalente, pra não precisar mudar cada chamador.
_TYPE_MAP = {
    "VARCHAR": "String",
    "INTEGER": "Int32",
    "BIGINT": "Int64",
    "TIMESTAMP": "DateTime",
    "DOUBLE": "Float64",
    "BOOLEAN": "Bool",
}


def connect() -> Client:
    return clickhouse_connect.get_client(
        host=CLICKHOUSE_HOST,
        port=CLICKHOUSE_PORT,
        username=CLICKHOUSE_USER,
        password=CLICKHOUSE_PASSWORD,
    )


def fetch_dicts(client: Client, query: str) -> list[dict[str, Any]]:
    result = client.query(query)
    return [dict(zip(result.column_names, row)) for row in result.result_rows]


def replace_table(
    client: Client,
    table: str,
    columns: dict[str, str],
    rows: list[tuple],
    order_by: str | None = None,
) -> None:
    schema = table.split(".")[0]
    client.command(f"CREATE DATABASE IF NOT EXISTS {schema}")
    column_defs = ", ".join(
        f"{name} {_TYPE_MAP.get(dtype.upper(), dtype)}" for name, dtype in columns.items()
    )
    order_by = order_by or next(iter(columns))
    client.command(
        f"CREATE OR REPLACE TABLE {table} ({column_defs}) ENGINE = MergeTree ORDER BY ({order_by})"
    )
    if rows:
        client.insert(table, rows, column_names=list(columns.keys()))
