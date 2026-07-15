"""Conexão read-only ao output/serving_store.sqlite (gravado por
ml/export_to_serving_store.py). A API nunca lê o ClickHouse diretamente —
evita disputar o warehouse com o dbt/treino.
"""

from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager

SQLITE_PATH = os.environ.get("SERVING_STORE_PATH", "/output/serving_store.sqlite")


@contextmanager
def get_connection():
    uri = f"file:{SQLITE_PATH}?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    try:
        yield con
    finally:
        con.close()
