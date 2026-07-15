"""Cosine similarity produto x produto para a vitrine personalizada."""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

import numpy as np
from scipy.sparse import csr_matrix
from sklearn.metrics.pairwise import cosine_similarity

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.db import connect, fetch_dicts, replace_table  # noqa: E402

TOP_K = int(os.environ.get("SIMILARITY_TOP_K", "10"))


def build_product_similarity_matrix(interactions: list[dict]) -> tuple[np.ndarray, list[str]]:
    customer_ids = sorted({row["customer_id"] for row in interactions})
    product_ids = sorted({row["product_id"] for row in interactions})
    customer_index = {customer_id: i for i, customer_id in enumerate(customer_ids)}
    product_index = {product_id: i for i, product_id in enumerate(product_ids)}

    weights = [row["interaction_weight"] for row in interactions]
    customer_rows = [customer_index[row["customer_id"]] for row in interactions]
    product_cols = [product_index[row["product_id"]] for row in interactions]
    interaction_matrix = csr_matrix(
        (weights, (customer_rows, product_cols)),
        shape=(len(customer_ids), len(product_ids)),
    )

    similarity = cosine_similarity(interaction_matrix.T, dense_output=True)
    np.fill_diagonal(similarity, 0.0)
    return similarity, product_ids


def top_similar_products(similarity: np.ndarray, product_ids: list[str]) -> list[tuple]:
    trained_at = datetime.now(timezone.utc)
    rows = []
    for i, product_id in enumerate(product_ids):
        neighbor_indices = np.argsort(-similarity[i])[:TOP_K]
        for j in neighbor_indices:
            score = float(similarity[i, j])
            if score > 0:
                rows.append((product_id, product_ids[j], score, trained_at))
    return rows


def main() -> int:
    con = connect()
    interactions = fetch_dicts(con, """
        SELECT customer_id, product_id, interaction_weight
        FROM feature.feat_customer_product_interactions
    """)
    if not interactions:
        print("feat_customer_product_interactions está vazia — nada a treinar.", file=sys.stderr)
        return 1

    similarity, product_ids = build_product_similarity_matrix(interactions)
    rows = top_similar_products(similarity, product_ids)

    replace_table(
        con, "raw.product_similarity",
        {"product_id_a": "VARCHAR", "product_id_b": "VARCHAR",
         "similarity_score": "DOUBLE", "trained_at": "TIMESTAMP"},
        rows,
    )
    print(f"raw.product_similarity: {len(rows)} linhas "
          f"({len(product_ids)} produtos, top-{TOP_K} vizinhos cada).", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
