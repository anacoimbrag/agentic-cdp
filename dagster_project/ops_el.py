import subprocess
from pathlib import Path

from dagster import In, Nothing, job, op

# raiz do ecommerce-data-pipeline (pai deste pacote)
PROJECT_ROOT = Path(__file__).parent.parent


def _run_in_venv(venv: str, args: list[str]) -> None:
    binary = PROJECT_ROOT / venv / "bin" / args[0]
    subprocess.run([str(binary), *args[1:]], cwd=str(PROJECT_ROOT), check=True)


@op
def meltano_el_op() -> None:
    """EL do ecommerce-synthetic-data -> raw, mesmo comando do stack.sh cmd_data."""
    _run_in_venv(".venv-meltano", ["meltano", "run", "el_ecomm_data"])


@op(ins={"start": In(Nothing)})
def ga4_customer_behavior_op() -> None:
    _run_in_venv(".venv-py", ["python", "scripts/load_ga4_customer_behavior.py"])


@op(ins={"start": In(Nothing)})
def ga4_site_traffic_op() -> None:
    _run_in_venv(".venv-py", ["python", "scripts/load_ga4_site_traffic.py"])


@job
def el_job():
    """Espelha `./stack.sh data` até o dbt: meltano -> GA4 (paralelo)."""
    done = meltano_el_op()
    ga4_customer_behavior_op(start=done)
    ga4_site_traffic_op(start=done)
