# ecommerce-data-pipeline

Pipeline ELT (Meltano + dbt) que extrai dados do CDP e os transforma em um
data warehouse ClickHouse, usado para BI e agentes.

O fluxo é: **Meltano** extrai da API `ecommerce-synthetic-data` e do GA4 e carrega no schema
(database) `raw` do ClickHouse; **dbt** transforma `raw` em modelos `staging`
(limpeza) e `marts` (as tabelas consultadas por dashboards e agentes).

ClickHouse foi escolhido no lugar de um arquivo embutido (DuckDB/SQLite)
porque o pipeline tem vários writers concorrentes (Meltano, os loaders de
GA4, o dbt e os jobs de ML) — um banco embutido single-writer trava sempre
que dois desses processos tentam escrever ao mesmo tempo; o ClickHouse é
client-server e suporta múltiplos writers nativamente.

## Estrutura

Stack roda nativo (sem Docker), orquestrado por [`stack.sh`](stack.sh) — ver
[Dependências](#dependências) e [Executar o pipeline](#executar-o-pipeline)
abaixo.

- `meltano.yml` — configuração dos plugins e do job de extração/carga (EL).
- `stack.sh` — sobe/derruba tudo: ClickHouse nativo, pipeline de dados
  (meltano + GA4 + dbt) e `dashboard` (Metabase) como comando separado. O
  `ecommerce-synthetic-data` roda à parte via `../ecommerce-synthetic-data/stack.sh`, e a camada de ML
  roda totalmente à parte via `../ecomm-ml/stack.sh` — projeto irmão
  independente, com seu próprio dbt (só depende de `staging`/`marts` já
  materializados aqui, lidos via `source()`; nada é chamado deste projeto
  pra lá nem vice-versa).
- `scripts/load_ga4_customer_behavior.py` e `scripts/load_ga4_site_traffic.py`
  — leem os arquivos de export do GA4 (`../ga4_bigquery_export/events/*.json.gz`)
  em paralelo (tabelas e cursors incrementais disjuntos, sem contenção): o
  primeiro filtra pelos clientes conhecidos e agrega por cliente em
  `raw.ga4_customer_behavior`; o segundo agrega tráfego de todos os
  visitantes em `raw.ga4_site_traffic`.
- `transform/` — projeto dbt (`dbt-clickhouse`): modelos `staging`
  (materializados como `view`, não `ephemeral` — de propósito, pra
  `../ecomm-ml/transform` conseguir lê-los via `source()`) alimentam os
  modelos `marts`. `feature/` e `activation/` (segmentação, próxima
  campanha, vitrine personalizada) vivem no projeto irmão
  [ecomm-ml](../ecomm-ml), ver [ecomm-ml/README.md](../ecomm-ml/README.md).
- O warehouse ClickHouse persiste em
  `${XDG_DATA_HOME:-~/.local/share}/clickhouse-ecommerce-data-pipeline/data/`
  (fora do repo).

## Fontes → `raw` → marts

| Fonte (ecommerce-synthetic-data / GA4)            | Tabela `raw`             | Modelos staging                                                           | Modelos marts |
|-------------------------------------|--------------------------|---------------------------------------------------------------------------|---------------|
| `GET /categories`                   | `raw.categories`         | `stg_categories`                                                          | `dim_categories` |
| `GET /promotions`                   | `raw.promotions`         | `stg_promotions`                                                          | `dim_promotions` |
| `GET /affiliates`                   | `raw.affiliates`         | `stg_affiliates`                                                          | `dim_affiliates` |
| `GET /products?page=N`              | `raw.products`           | `stg_products`                                                            | `dim_products`, `dim_brands` |
| `GET /profiles?page=N`              | `raw.cdp_customer_profiles` | `stg_cdp_customer_profiles`                                            | `dim_customers` |
| `GET /orders?page=N`                | `raw.orders`             | `stg_customer_orders`, `stg_customer_order_items`, `stg_customer_refunds` | `fct_customer_orders`, `fct_order_line`, `dim_order_status`, `dim_channel`, `dim_payment_methods`, `dim_date` |
| GA4 (arquivos locais, agregado)     | `raw.ga4_customer_behavior` | `stg_ga4_customer_behavior`                                            | alimenta campos de GA4 em `dim_customers` |

## Dependências

Ferramentas que precisam estar instaladas na máquina (uma vez, fora do
`stack.sh`), pelo método oficial do seu sistema operacional — cada uma com
link pra documentação de instalação:

- **[Python 3.11](https://www.python.org/downloads/)** — usado pelas venvs `.venv-py`, `.venv-dbt` e `.venv-meltano` (não commitadas; ver `.gitignore`).
- **[ClickHouse](https://clickhouse.com/docs/install)** — warehouse (client-server, suporta múltiplos writers concorrentes).
- **[Node.js](https://nodejs.org/)** — necessário pro `ecommerce-synthetic-data` (ver README do projeto).
- **[Java 11+](https://adoptium.net/)** — necessário pra rodar o [Metabase](https://www.metabase.com/docs/latest/) via `./stack.sh dashboard`/`download-metabase`.
- **[Meltano](https://docs.meltano.com/getting-started/installation)** — instalado dentro da venv `.venv-meltano` (`pip install meltano` + `meltano install` pros plugins).
- **[dbt-clickhouse](https://github.com/ClickHouse/dbt-clickhouse)** — instalado dentro da venv `.venv-dbt` via `transform/requirements.txt`.

Depois de instaladas, `./stack.sh` cuida de subir/orquestrar tudo (ver
abaixo) — dados/config do ClickHouse ficam em
`${XDG_DATA_HOME:-~/.local/share}/clickhouse-ecommerce-data-pipeline/`, mesma
convenção em qualquer SO. `cp .env.example .env` e ajuste
`CLICKHOUSE_PASSWORD` (não pode ficar vazio — o driver HTTP usado pelo
Meltano/dbt rejeita senha vazia mesmo pro usuário `default` sem senha
configurada) antes do primeiro run.

## Executar o pipeline

```bash
(cd ../ecommerce-synthetic-data && ./stack.sh up)  # fonte de dados que o meltano extrai (ver README do projeto)
./stack.sh up                         # garante o ClickHouse no ar
./stack.sh data                       # meltano (ecommerce-synthetic-data -> raw) + GA4 (comportamento + tráfego, em paralelo) -> dbt build (staging + marts)
(cd ../ecomm-ml && ./stack.sh ml)     # pipeline de ML completo e independente: dbt build (feature) -> treino -> dbt build (completo) -> export
```

`./stack.sh down` para o ClickHouse, o Metabase, o `ecommerce-synthetic-data` (via
`../ecommerce-synthetic-data/stack.sh down`) e o `ecomm-ml` (via `../ecomm-ml/stack.sh down`).

Pra rodar dbt manualmente (outros subcomandos além de `build`, por exemplo
gerar documentação):

```bash
source .venv-dbt/bin/activate
cd transform
dbt docs generate
python3 -m http.server --directory target 8080   # abrir http://localhost:8080
```

Camada de ML (segmentação, próxima campanha, vitrine personalizada): projeto
irmão independente, ver [ecomm-ml/README.md](../ecomm-ml/README.md).

## Inspecionar o resultado

```bash
source .venv-dbt/bin/activate
(cd transform && dbt show --inline "select * from marts.dim_customers limit 5")
```

(ou `~/.local/bin/clickhouse client --user default --password ... ` direto
em `localhost:8123`/`:9000`, ou abra o Metabase em `http://localhost:3001`
— ver seção abaixo.)

## BI com Metabase

```bash
./stack.sh download-metabase   # baixa o jar standalone (~500MB), uma vez
./stack.sh dashboard           # sobe o metabase (:3001) em background
```

Abra `http://localhost:3001`, complete o setup inicial (ou reaproveite a
conexão já salva em `metabase/data/metabase.db`, preservado da configuração
anterior) e adicione uma conexão **ClickHouse**: host `localhost`, porta
`8123`, database o schema que você quer explorar (`raw`, `staging`,
`marts`, `activation`, `feature`), usuário/senha do `.env`. O driver
ClickHouse já vem embutido no jar oficial do Metabase — não precisa de
plugin/JAR adicional.

## Adicionar um endpoint do ecommerce-synthetic-data

Adicione uma entrada em `extractors.tap-rest-api-msdk.config.streams` no
`meltano.yml`: `name` (nome do stream/tabela), `path` (concatenado à
`api_url`), `records_path` (JSONPath para o array de registros) e,
opcionalmente, `primary_keys`.

## Adicionar um modelo

- **Staging**: crie um `.sql` em `transform/models/staging/` fazendo
  `select` de `{{ source('raw', '<tabela>') }}` (declarada em
  `sources.yml`). Materializado como `view` por padrão — de propósito, não
  `ephemeral`, pra ficar visível fisicamente no ClickHouse e poder ser lido
  via `source()` pelo projeto irmão `../ecomm-ml/transform` (se um novo
  model de staging só interessa a este projeto, `ephemeral` continua válido
  como override pontual).
- **Marts**: crie um `.sql` em `transform/models/marts/` a partir de
  `{{ ref('stg_...') }}` e adicione descrição e testes no `schema.yml` da
  pasta — todo modelo deve ter ao menos `not_null` + `unique` na chave
  primária. Cuidado pra não criar um `ref()` na direção contrária (marts
  dependendo de um model de `../ecomm-ml/transform/models/activation/`) —
  isso cria um ciclo entre os dois projetos dbt; se `feature`/`activation`
  precisar disso, quem lê de quem é sempre `ecomm-ml` lendo daqui via
  `source()`, nunca o inverso (ver `dim_customers.sql`, que recalcula direto
  das staging sources em vez de depender de `activation.customer_profile`
  por esse motivo).
- **Feature/Activation** (segmentação, próxima campanha, vitrine
  personalizada): vivem em `../ecomm-ml/transform`, não aqui — ver
  [ecomm-ml/README.md](../ecomm-ml/README.md).

## Licença

Distribuído sob a licença [MIT](LICENSE).
