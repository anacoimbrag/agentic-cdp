"""Regressão logística por campanha: propensão de conversão do cliente."""

from __future__ import annotations

import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

import numpy as np
from sklearn.linear_model import LogisticRegression

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common.db import connect, fetch_dicts, replace_table  # noqa: E402

MIN_SAMPLES_PER_CAMPAIGN = int(os.environ.get("PROPENSITY_MIN_SAMPLES", "20"))
FEATURE_COLUMNS = [
    "view_count", "select_count", "days_since_last_exposure",
    "recency_days", "total_orders", "net_revenue", "avg_order_value",
]


def predict_propensity(exposures: list[dict]) -> np.ndarray:
    features = np.array([[float(row[col] or 0) for col in FEATURE_COLUMNS] for row in exposures])
    converted = np.array([row["converted"] for row in exposures], dtype=int)
    model = LogisticRegression(class_weight="balanced", max_iter=1000)
    model.fit(features, converted)
    return model.predict_proba(features)[:, 1]


def main() -> int:
    con = connect()
    exposures = fetch_dicts(con, f"""
        SELECT customer_id, promotion_id, {", ".join(FEATURE_COLUMNS)}, converted
        FROM feature.feat_campaign_training_data
    """)
    if not exposures:
        print("feat_campaign_training_data está vazia — nada a treinar.", file=sys.stderr)
        return 1

    exposures_by_promotion: dict[str, list[dict]] = defaultdict(list)
    for row in exposures:
        exposures_by_promotion[row["promotion_id"]].append(row)

    trained_at = datetime.now(timezone.utc)
    result_rows = []
    trained_promotions, skipped_promotions = [], []

    for promotion_id, rows in exposures_by_promotion.items():
        conversions = sum(row["converted"] for row in rows)
        has_both_classes = 0 < conversions < len(rows)
        if len(rows) < MIN_SAMPLES_PER_CAMPAIGN or not has_both_classes:
            skipped_promotions.append(promotion_id)
            continue

        scores = predict_propensity(rows)
        result_rows += [
            (row["customer_id"], promotion_id, float(score), trained_at)
            for row, score in zip(rows, scores)
        ]
        trained_promotions.append(promotion_id)
        print(f"{promotion_id}: {len(rows)} amostras, {conversions} conversões, treinado.", flush=True)

    if skipped_promotions:
        print(f"Puladas (poucas amostras ou só uma classe): {skipped_promotions}", flush=True)

    replace_table(
        con, "raw.campaign_propensity",
        {"customer_id": "VARCHAR", "promotion_id": "VARCHAR",
         "propensity_score": "DOUBLE", "trained_at": "TIMESTAMP"},
        result_rows,
    )
    print(f"raw.campaign_propensity: {len(result_rows)} linhas "
          f"({len(trained_promotions)} campanhas treinadas).", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
