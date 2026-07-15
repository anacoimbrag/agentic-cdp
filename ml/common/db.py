"""Conexão DuckDB e helpers de leitura/escrita compartilhados pelos scripts de treino."""

from __future__ import annotations

import os
from typing import Any

import duckdb

WAREHOUSE_PATH = os.environ.get("WAREHOUSE_PATH", "/output/warehouse.duckdb")


def connect(read_only: bool = False) -> duckdb.DuckDBPyConnection:
    return duckdb.connect(WAREHOUSE_PATH, read_only=read_only)


def fetch_dicts(con: duckdb.DuckDBPyConnection, query: str) -> list[dict[str, Any]]:
    cursor = con.execute(query)
    columns = [c[0] for c in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def replace_table(
    con: duckdb.DuckDBPyConnection,
    table: str,
    columns: dict[str, str],
    rows: list[tuple],
) -> None:
    schema = table.split(".")[0]
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
    column_defs = ", ".join(f"{name} {dtype}" for name, dtype in columns.items())
    con.execute(f"CREATE OR REPLACE TABLE {table} ({column_defs})")
    if rows:
        placeholders = ", ".join("?" * len(columns))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
