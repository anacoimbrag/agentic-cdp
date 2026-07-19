import json

from dagster import AssetExecutionContext
from dagster_dbt import DbtCliResource, dbt_assets

from .project import dbt_project


def _dbt_model_names(layer: str) -> list[str]:
    """Nomes dos modelos dbt em models/<layer>/, na ordem do manifest."""
    manifest = json.loads(dbt_project.manifest_path.read_text())
    return sorted(
        node["name"]
        for node in manifest["nodes"].values()
        if node["resource_type"] == "model" and node["fqn"][1] == layer
    )


def _build_dbt_asset(model_name: str):
    @dbt_assets(manifest=dbt_project.manifest_path, select=model_name, name=f"{model_name}_dbt_asset")
    def _dbt_asset(context: AssetExecutionContext, dbt: DbtCliResource):
        yield from dbt.cli(["build", "--select", model_name], context=context).stream()

    return _dbt_asset


# Uma op dbt por model -- permite que o Dagster execute cada view de staging
# (transformation) e cada tabela de marts (gold) em paralelo, respeitando as
# dependências reais entre os models (ver group_name em transform/dbt_project.yml).
transformation_dbt_assets = [_build_dbt_asset(name) for name in _dbt_model_names("staging")]
gold_dbt_assets = [_build_dbt_asset(name) for name in _dbt_model_names("marts")]
