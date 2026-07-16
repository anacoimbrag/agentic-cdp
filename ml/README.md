# Camada de ML

Resolve 3 casos de uso do CDP a partir de `activation.customer_profile` e
`marts.fct_order_line`: clusterização dinâmica de clientes, próxima campanha
sugerida e vitrine inteligente personalizada. Ver
`transform/models/activation/customer_profile.sql`,
`transform/models/activation/segment_campaign_affinity.sql` e
`transform/models/activation/customer_showcase.sql` para a lógica de
negócio (tudo em SQL); os scripts aqui em `ml/` só rodam o algoritmo de ML
e gravam o resultado cru em `raw.*` — quem rotula/rankeia/combina é dbt.

## Ordem de execução do pipeline batch

`customer_profile.sql` lê a saída do Python (`raw.customer_clusters`,
`raw.campaign_propensity`), e o Python lê as views de
`transform/models/feature/`. Isso exige rodar o `dbt build` em duas
passagens — a segunda só depois que os scripts de treino já escreveram em
`raw.*`. `./stack.sh ml` (raiz do projeto) encadeia tudo isso:

```bash
./stack.sh data   # pré-requisito: staging/marts + as 4 feature views base já em raw/feature
./stack.sh ml     # treino (training/segmentation, training/campaigns, training/recommendations) -> dbt build completo -> export
./stack.sh ml-api  # sobe a ml-api (lê só output/serving_store.sqlite, nunca o ClickHouse)
```

Por baixo dos panos, `./stack.sh ml` roda, na ordem:

```bash
# 1. (feito por ./stack.sh data) as 4 feature views que os scripts de treino
#    consomem já foram materializadas — NÃO inclui feat_customer_segment_labels,
#    que depende de raw.customer_clusters (só existe depois do passo 2 abaixo).

# 2. os 3 scripts de treino (cada um só lê a feature view e grava
#    UMA tabela crua em raw.*)
python ml/training/segmentation/train_kmeans.py
python ml/training/campaigns/train_propensity.py
python ml/training/recommendations/train_item_similarity.py

# 3. dbt build completo — agora customer_profile.sql, customer_showcase.sql
#    etc. conseguem ler raw.customer_clusters/campaign_propensity/product_similarity
(cd transform && dbt build)

# 4. publica os resultados finais num SQLite de leitura pra API consumir
python ml/export_to_serving_store.py
```

É o mesmo tipo de job one-shot que `dbt build` já é hoje — dá pra encadear
num único script de cron, sem orquestrador novo (é exatamente o que
`stack.sh` faz).

## Por que Python só treina

Cada script em `ml/training/<caso_de_uso>/train_*.py` faz uma única coisa: ler uma
feature view, rodar o algoritmo de ML, e escrever uma tabela crua em
`raw.*` (mesmo padrão de `scripts/load_ga4_customer_behavior.py`). Toda
rotulagem de negócio, ranking, fallback e combinação com outras tabelas
fica em SQL/dbt — mais fácil de auditar e testar (`dbt test`).

| Caso de uso | Algoritmo | Script | Saída crua |
|---|---|---|---|
| Clusterização dinâmica | K-Means (k via silhouette) | `training/segmentation/train_kmeans.py` | `raw.customer_clusters` |
| Próxima campanha | Regressão Logística por campanha | `training/campaigns/train_propensity.py` | `raw.campaign_propensity` |
| Vitrine personalizada | Cosine similarity produto x produto | `training/recommendations/train_item_similarity.py` | `raw.product_similarity` |
