from fastapi import APIRouter, Query

from api.db import get_connection
from api.schemas import ShowcaseItem, ShowcaseResponse

router = APIRouter()


@router.get("/customers/{customer_id}/showcase", response_model=ShowcaseResponse)
def get_customer_showcase(
    customer_id: str, limit: int = Query(default=12, ge=1, le=12)
) -> ShowcaseResponse:
    with get_connection() as con:
        rows = con.execute(
            """
            SELECT
                cs.rank AS rank,
                cs.product_id AS product_id,
                cs.sku_id AS sku_id,
                p.sku_name AS product_name,
                p.selling_price AS price,
                p.image_url AS image_url,
                cs.reason AS reason,
                cs.score AS score
            FROM customer_showcase cs
            LEFT JOIN products p ON cs.sku_id = p.sku_id
            WHERE cs.customer_id = ?
            ORDER BY cs.rank
            LIMIT ?
            """,
            (customer_id, limit),
        ).fetchall()

    return ShowcaseResponse(
        customer_id=customer_id,
        items=[ShowcaseItem(**dict(row)) for row in rows],
    )
