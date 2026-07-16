"""K-Means sobre RFM para clusterização dinâmica de clientes."""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

import numpy as np
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from sklearn.preprocessing import StandardScaler

# permite `from common.db import ...` quando o script roda direto (python training/segmentation/train_kmeans.py)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from common.db import connect, fetch_dicts, replace_table  # noqa: E402

K_MIN = int(os.environ.get("KMEANS_K_MIN", "3"))
K_MAX = int(os.environ.get("KMEANS_K_MAX", "8"))
RANDOM_STATE = 42


def pick_best_k(features: np.ndarray, k_min: int, k_max: int) -> int:
    silhouette_by_k = {}
    for k in range(k_min, k_max + 1):
        labels = KMeans(n_clusters=k, random_state=RANDOM_STATE, n_init=10).fit_predict(features)
        silhouette_by_k[k] = silhouette_score(features, labels)
        print(f"k={k}: silhouette={silhouette_by_k[k]:.4f}", flush=True)
    return max(silhouette_by_k, key=silhouette_by_k.get)


def main() -> int:
    con = connect()
    customers = fetch_dicts(con, """
        SELECT customer_id, recency_days, total_orders, net_revenue
        FROM feature.feat_rfm_features
        WHERE has_purchase_history
    """)
    if not customers:
        print("Nenhum cliente com histórico de compra em feat_rfm_features.", file=sys.stderr)
        return 1

    rfm = np.array([[c["recency_days"], c["total_orders"], c["net_revenue"]] for c in customers])
    rfm_scaled = StandardScaler().fit_transform(rfm)

    max_testable_k = min(K_MAX, len(customers) - 1)
    if max_testable_k >= K_MIN:
        k = pick_best_k(rfm_scaled, K_MIN, max_testable_k)
    else:
        k = max(2, max_testable_k)
        print(f"Poucos clientes ({len(customers)}); usando k={k} sem otimizar silhouette.",
              file=sys.stderr)

    clusters = KMeans(n_clusters=k, random_state=RANDOM_STATE, n_init=10).fit_predict(rfm_scaled)

    trained_at = datetime.now(timezone.utc)
    rows = [
        (customer["customer_id"], int(cluster_id), trained_at)
        for customer, cluster_id in zip(customers, clusters)
    ]
    replace_table(
        con, "raw.customer_clusters",
        {"customer_id": "VARCHAR", "cluster_id": "INTEGER", "trained_at": "TIMESTAMP"},
        rows,
    )
    print(f"raw.customer_clusters: {len(rows)} linhas, k={k}.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
