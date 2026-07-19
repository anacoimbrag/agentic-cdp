#!/usr/bin/env bash
# Orquestra o stack nativo (sem Docker) do ecommerce-data-pipeline: ClickHouse, meltano,
# GA4 loaders e dbt. Ver README.md para o setup inicial de cada venv
# (.venv-py, .venv-dbt, .venv-meltano) e do ClickHouse.
#
# O ecommerce-synthetic-data roda separado (../ecommerce-synthetic-data/stack.sh up/down) -- não é
# gerenciado daqui, só precisa estar no ar antes de `./stack.sh data`. A
# camada de ML também roda separado (../ecomm-ml/stack.sh ml/export/ml-api/
# ml-web) -- ver ecomm-ml/README.md; tem seu próprio projeto dbt
# (../ecomm-ml/transform, feature/activation), que lê staging/marts daqui
# via source() -- só precisa deste `./stack.sh data` já ter rodado antes.
#
# Uso:
#   ./stack.sh up        # garante clickhouse no ar
#   ./stack.sh data       # pipeline ETL/ELT: EL ecommerce-synthetic-data+GA4 -> raw -> dbt (staging+marts)
#   ./stack.sh download-metabase # baixa metabase/metabase.jar (~500MB), uma vez
#   ./stack.sh dashboard         # sobe o metabase em background (:3001)
#   ./stack.sh down       # para clickhouse, metabase, ecommerce-synthetic-data (via ../ecommerce-synthetic-data/stack.sh down) e ecomm-ml (via ../ecomm-ml/stack.sh down)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

set -a
source .env
set +a

CH_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/clickhouse-ecommerce-data-pipeline"
CH_BIN="$(command -v clickhouse || echo "$HOME/.local/bin/clickhouse")"
CH_CONFIG="$CH_HOME/config.xml"
CH_LOG_DIR="$CH_HOME/logs"
METABASE_JAR="$ROOT/metabase/metabase.jar"
METABASE_PORT=3001

log() { echo "[stack] $*"; }

wait_for() {
  local desc="$1" check="$2" tries=30
  for ((i = 0; i < tries; i++)); do
    eval "$check" >/dev/null 2>&1 && { log "$desc: no ar"; return 0; }
    sleep 1
  done
  log "$desc: não respondeu em ${tries}s"
  return 1
}

ensure_clickhouse_config() {
  [ -f "$CH_CONFIG" ] && return
  log "clickhouse: gerando config em $CH_CONFIG"
  mkdir -p "$CH_HOME/data" "$CH_HOME/tmp" "$CH_HOME/user_files" "$CH_HOME/format_schemas" "$CH_LOG_DIR"
  cat >"$CH_CONFIG" <<EOF
<clickhouse>
    <logger>
        <level>information</level>
        <log>$CH_LOG_DIR/clickhouse.log</log>
        <errorlog>$CH_LOG_DIR/clickhouse.err.log</errorlog>
        <size>100M</size>
        <count>3</count>
    </logger>
    <path>$CH_HOME/data/</path>
    <tmp_path>$CH_HOME/tmp/</tmp_path>
    <user_files_path>$CH_HOME/user_files/</user_files_path>
    <format_schema_path>$CH_HOME/format_schemas/</format_schema_path>
    <listen_host>127.0.0.1</listen_host>
    <http_port>${CLICKHOUSE_PORT}</http_port>
    <tcp_port>9000</tcp_port>
    <mysql_port>9004</mysql_port>
    <postgresql_port>9005</postgresql_port>
    <max_connections>1024</max_connections>
    <mark_cache_size>5368709120</mark_cache_size>
    <users>
        <default>
            <password>${CLICKHOUSE_PASSWORD}</password>
            <networks><ip>127.0.0.1</ip><ip>::1</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
    <profiles>
        <default><max_memory_usage>4000000000</max_memory_usage></default>
    </profiles>
    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries><errors>0</errors><result_rows>0</result_rows>
                <read_rows>0</read_rows><execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</clickhouse>
EOF
}

start_clickhouse() {
  if curl -sf -m 2 "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/ping" >/dev/null 2>&1; then
    log "clickhouse: já rodando"
    return
  fi
  ensure_clickhouse_config
  log "clickhouse: iniciando..."
  nohup "$CH_BIN" server -C "$CH_CONFIG" >"$CH_LOG_DIR/stdout.log" 2>&1 &
  disown
  wait_for "clickhouse" "curl -sf -m 2 http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/ping"
  # o container Docker criava o database via env CLICKHOUSE_DB; nativo não tem
  # esse hook, então garantimos aqui (idempotente).
  curl -sf -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DATABASE}" \
    "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" >/dev/null
}

require_ecomm_data() {
  if ! curl -sf -m 2 "$ECOMM_DATA_API_URL/health" >/dev/null 2>&1; then
    log "ecommerce-synthetic-data não está respondendo em $ECOMM_DATA_API_URL"
    log "suba com: (cd /path/to/ecommerce-synthetic-data && ./stack.sh up)"
    exit 1
  fi
}

cmd_up() {
  start_clickhouse
}

cmd_data() {
  start_clickhouse
  require_ecomm_data

  log "meltano: EL ecommerce-synthetic-data -> raw"
  source .venv-meltano/bin/activate
  meltano run el_ecomm_data
  deactivate

  log "GA4: carga de comportamento e tráfego (em paralelo -- escrevem em tabelas raw.* e cursors incrementais disjuntos)"
  source .venv-py/bin/activate
  python scripts/load_ga4_customer_behavior.py &
  ga4_behavior_pid=$!
  python scripts/load_ga4_site_traffic.py &
  ga4_traffic_pid=$!
  set +e
  wait "$ga4_behavior_pid"; ga4_behavior_status=$?
  wait "$ga4_traffic_pid"; ga4_traffic_status=$?
  set -e
  if [ "$ga4_behavior_status" -ne 0 ] || [ "$ga4_traffic_status" -ne 0 ]; then
    log "GA4: falha (comportamento exit=$ga4_behavior_status, tráfego exit=$ga4_traffic_status)"
    exit 1
  fi
  deactivate

  log "dbt build (staging + marts)"
  source .venv-dbt/bin/activate
  (cd transform && dbt build)
  deactivate

  log "pipeline de dados completo."
}

cmd_download_metabase() {
  if [ -f "$METABASE_JAR" ]; then
    log "metabase: jar já existe em $METABASE_JAR"
    return
  fi
  log "metabase: baixando jar (~500MB) de https://downloads.metabase.com/latest/metabase.jar ..."
  mkdir -p "$(dirname "$METABASE_JAR")"
  curl -fSL -o "$METABASE_JAR" https://downloads.metabase.com/latest/metabase.jar
  log "metabase: jar salvo em $METABASE_JAR"
}

cmd_dashboard() {
  if curl -sf -m 2 "http://localhost:$METABASE_PORT" >/dev/null 2>&1; then
    log "metabase: já rodando"
    return
  fi
  if [ ! -f "$METABASE_JAR" ]; then
    log "metabase: jar não encontrado em $METABASE_JAR"
    cmd_download_metabase
    if [ ! -f "$METABASE_JAR" ]; then
      log "metabase: falha ao baixar jar"
      exit 1
    fi
  fi
  # Metabase resolve o próprio jar como URI (jar:file:...!/) pra ler os
  # manifests dos drivers embutidos, e essa URI quebra se o caminho tiver
  # espaço (caso de "$ROOT" aqui). Rodamos a partir de uma cópia em path
  # estável sem espaço.
  local jar_cache="${XDG_DATA_HOME:-$HOME/.local/share}/ecommerce-data-pipeline-metabase/metabase.jar"
  mkdir -p "$(dirname "$jar_cache")"
  if [ ! -f "$jar_cache" ] || [ "$METABASE_JAR" -nt "$jar_cache" ]; then
    log "metabase: copiando jar para path sem espaço ($jar_cache)"
    cp "$METABASE_JAR" "$jar_cache"
  fi
  log "metabase: iniciando..."
  MB_DB_FILE="$ROOT/metabase/data/metabase.db" MB_JETTY_PORT="$METABASE_PORT" \
    nohup java -jar "$jar_cache" >"$ROOT/.stack-metabase.log" 2>&1 &
  disown
  wait_for "metabase" "curl -sf -m 2 http://localhost:$METABASE_PORT"
}

cmd_down() {
  for port_desc in "$METABASE_PORT:metabase" "${CLICKHOUSE_PORT}:clickhouse"; do
    port="${port_desc%%:*}"; desc="${port_desc##*:}"
    pid=$(lsof -ti "tcp:$port" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill $pid 2>/dev/null && log "$desc: parado (porta $port)"
    else
      log "$desc: não estava rodando"
    fi
  done
  (cd ../ecommerce-synthetic-data && ./stack.sh down)
  [ -x ../ecomm-ml/stack.sh ] && (cd ../ecomm-ml && ./stack.sh down)
}

case "${1:-}" in
  up) cmd_up ;;
  data) cmd_data ;;
  download-metabase) cmd_download_metabase ;;
  dashboard) cmd_dashboard ;;
  down) cmd_down ;;
  *)
    echo "Uso: $0 {up|data|download-metabase|dashboard|down}" >&2
    exit 1
    ;;
esac
