import subprocess
from pathlib import Path

from dagster import In, Nothing, job, op

# raiz do ecommerce-data-pipeline (pai deste pacote)
PROJECT_ROOT = Path(__file__).parent.parent


def _run_in_venv(venv: str, args: list[str]) -> None:
    binary = PROJECT_ROOT / venv / "bin" / args[0]
    subprocess.run([str(binary), *args[1:]], cwd=str(PROJECT_ROOT), check=True)


@op
def categories_el_op() -> None:
    """EL de categories (ecommerce-synthetic-data) -> raw.categories, upsert por id."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_categories"])


@op
def promotions_el_op() -> None:
    """EL de promotions (ecommerce-synthetic-data) -> raw.promotions, upsert por name."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_promotions"])


@op
def affiliates_el_op() -> None:
    """EL de affiliates (ecommerce-synthetic-data) -> raw.affiliates, upsert por id."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_affiliates"])


@op
def cdp_customer_profiles_el_op() -> None:
    """EL de cdp_customer_profiles (ecommerce-synthetic-data) -> raw.cdp_customer_profiles, append-only (sem PK plana)."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_profiles"])


@op
def products_el_op() -> None:
    """EL de products (ecommerce-synthetic-data) -> raw.products, upsert por productId."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_products"])


@op
def orders_el_op() -> None:
    """EL de orders (bookmark de creationDate rastreado, mas API não filtra por data -> upsert por orderId evita duplicata em raw.orders)."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_orders"])


@op(ins={"start": In(Nothing)})
def ga4_customer_behavior_op() -> None:
    _run_in_venv(".venv-py", ["python", "scripts/load_ga4_customer_behavior.py"])


@op(ins={"start": In(Nothing)})
def ga4_site_traffic_op() -> None:
    _run_in_venv(".venv-py", ["python", "scripts/load_ga4_site_traffic.py"])


@job
def el_job():
    """Espelha `./stack.sh data` até o dbt: 6 streams ecomm (paralelo) -> GA4 (paralelo)."""
    done = [
        categories_el_op(),
        promotions_el_op(),
        affiliates_el_op(),
        cdp_customer_profiles_el_op(),
        products_el_op(),
        orders_el_op(),
    ]
    ga4_customer_behavior_op(start=done)
    ga4_site_traffic_op(start=done)
