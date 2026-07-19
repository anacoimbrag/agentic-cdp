import os
from pathlib import Path

from dagster import (
    AssetSelection,
    DagsterRunStatus,
    Definitions,
    RunRequest,
    define_asset_job,
    run_status_sensor,
)
from dagster_dbt import DbtCliResource

from .assets_dbt import transform_dbt_assets
from .ops_el import el_job
from .project import dbt_project


def _load_dotenv() -> None:
    """Mesma .env que o stack.sh usa (CLICKHOUSE_*, ECOMM_DATA_API_URL, GA4_*)."""
    env_path = Path(__file__).parent.parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"'))


_load_dotenv()

dbt_build_job = define_asset_job("dbt_build_job", selection=AssetSelection.all())


@run_status_sensor(
    run_status=DagsterRunStatus.SUCCESS,
    monitored_jobs=[el_job],
    request_job=dbt_build_job,
)
def run_dbt_after_el(context):
    """Dispara o dbt build assim que o el_job (meltano + GA4) termina com sucesso."""
    return RunRequest()


defs = Definitions(
    assets=[transform_dbt_assets],
    jobs=[el_job, dbt_build_job],
    sensors=[run_dbt_after_el],
    resources={
        "dbt": DbtCliResource(project_dir=dbt_project),
    },
)
