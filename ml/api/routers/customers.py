from fastapi import APIRouter

from api.db import get_connection
from api.schemas import CustomerSummary

router = APIRouter()


@router.get("/customers", response_model=list[CustomerSummary])
def list_customers() -> list[CustomerSummary]:
    with get_connection() as con:
        rows = con.execute(
            """
            SELECT customer_id, full_name
            FROM customer_profile
            ORDER BY customer_id
            LIMIT 10
            """
        ).fetchall()

    return [CustomerSummary(**dict(row)) for row in rows]
