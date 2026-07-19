from pathlib import Path

from dagster_dbt import DbtProject

DBT_PROJECT_DIR = Path(__file__).parent.parent / "transform"

dbt_project = DbtProject(project_dir=DBT_PROJECT_DIR)
# gera o manifest em dev se ainda não existir / estiver desatualizado (em
# produção o manifest já viria pronto de um build anterior).
dbt_project.prepare_if_dev()
