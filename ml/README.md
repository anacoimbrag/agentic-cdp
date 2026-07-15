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
`raw.*`:

```bash
# 1. Materializa só as 4 feature views que os scripts de treino consomem
#    (NÃO inclui feat_customer_segment_labels — essa depende de
#    raw.customer_clusters, que só existe depois do passo 2).
docker compose run --rm dbt build --select \
    feat_rfm_features feat_promotion_engagement \
    feat_campaign_training_data feat_customer_product_interactions

# 2. Roda os 3 scripts de treino (cada um só lê a feature view e grava
#    UMA tabela crua em raw.*)
docker compose run --rm ml-segmentation
docker compose run --rm ml-campaigns
docker compose run --rm ml-recommendations

# 3. dbt build completo — agora customer_profile.sql, customer_showcase.sql
#    etc. conseguem ler raw.customer_clusters/campaign_propensity/product_similarity
docker compose run --rm dbt build

# 4. Publica os resultados finais num SQLite de leitura pra API consumir
docker compose run --rm ml-export

# 5. Sobe a API (lê só output/serving_store.sqlite, nunca o ClickHouse)
docker compose up -d ml-api
```

Passos 1–4 são o mesmo tipo de job one-shot que `dbt build` já é hoje — dá
pra encadear num único script de cron, sem orquestrador novo.

## Por que Python só treina

Cada script em `ml/<caso_de_uso>/train_*.py` faz uma única coisa: ler uma
feature view, rodar o algoritmo de ML, e escrever uma tabela crua em
`raw.*` (mesmo padrão de `scripts/load_ga4_customer_behavior.py`). Toda
rotulagem de negócio, ranking, fallback e combinação com outras tabelas
fica em SQL/dbt — mais fácil de auditar e testar (`dbt test`).

| Caso de uso | Algoritmo | Script | Saída crua |
|---|---|---|---|
| Clusterização dinâmica | K-Means (k via silhouette) | `segmentation/train_kmeans.py` | `raw.customer_clusters` |
| Próxima campanha | Regressão Logística por campanha | `campaigns/train_propensity.py` | `raw.campaign_propensity` |
| Vitrine personalizada | Cosine similarity produto x produto | `recommendations/train_item_similarity.py` | `raw.product_similarity` |
