{#
  Descarta o schema raw apenas se todos os nós do build tiveram sucesso.
  Um build com falhas mantém raw para depuração. Desativado por padrão;
  ativar via on-run-end no dbt_project.yml.
#}
{% macro drop_raw_schema_if_successful() %}
  {% if execute %}
    {% set failures = results | selectattr("status", "in", ["error", "fail", "skipped"]) | list %}
    {% if failures | length == 0 %}
      {% do run_query("DROP DATABASE IF EXISTS raw") %}
    {% endif %}
  {% endif %}
{% endmacro %}
