{# ClickHouse não tem um try_cast genérico (era `try_cast(col as tipo)` no
   DuckDB) -- despacha pro `toXOrNull` certo por tipo. #}
{% macro try_cast(column, type) %}
  {%- if type | lower == 'date' -%}
    toDateOrNull({{ column }})
  {%- elif type | lower == 'timestamp' -%}
    parseDateTimeBestEffortOrNull({{ column }})
  {%- elif type | lower in ('integer', 'int') -%}
    toInt32OrNull({{ column }})
  {%- elif type | lower in ('bigint', 'long') -%}
    toInt64OrNull({{ column }})
  {%- elif type | lower in ('double', 'float') -%}
    toFloat64OrNull({{ column }})
  {%- else -%}
    {{ exceptions.raise_compiler_error("try_cast: tipo nao suportado '" ~ type ~ "'") }}
  {%- endif -%}
{% endmacro %}
