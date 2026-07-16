{{ config(order_by=['customer_id']) }}
-- Traduz raw.customer_clusters (cluster_id cru, saída do K-Means) em rótulos
-- de negócio (segment_label/tier). Fica em feature/, não em activation/,
-- porque tem dois consumidores que não podem depender um do outro:
-- activation/customer_profile.sql e activation/segment_campaign_affinity.sql
-- (essa última mede conversão histórica POR segmento, então não pode
-- depender de customer_profile, senão vira ciclo).
--
-- Rotulagem: em vez de rankear só por net_revenue e espalhar numa escala fixa
-- de 6 posições, calcula o centroid de cada cluster nas 3 dimensões RFM
-- (recency_days, total_orders, net_revenue), posiciona cada cluster num
-- tercil (high/mid/low) por dimensão relativo aos outros clusters do mesmo
-- k, e aplica uma grade de decisão RFM (ex: recência baixa + frequência alta
-- + valor alto = Champions). O nome passa a refletir o comportamento real do
-- cluster, não só sua posição num rank de receita — e continua batendo com
-- qualquer k que o K-Means escolher (3 a 8, ver ml/training/segmentation/train_kmeans.py).
with cluster_stats as (
    select
        cc.cluster_id as cluster_id,
        avg(f.recency_days) as avg_recency_days,
        avg(f.total_orders) as avg_total_orders,
        avg(f.net_revenue) as avg_net_revenue
    from {{ source('raw', 'customer_clusters') }} cc
    inner join {{ ref('feat_rfm_features') }} f on cc.customer_id = f.customer_id
    group by 1
),

cluster_count as (
    select count(*) as k from cluster_stats
),

ranked_clusters as (
    select
        cs.cluster_id as cluster_id,
        dense_rank() over (order by cs.avg_recency_days asc) as recency_rank,
        dense_rank() over (order by cs.avg_total_orders desc) as frequency_rank,
        dense_rank() over (order by cs.avg_net_revenue desc) as monetary_rank
    from cluster_stats cs
),

-- posição relativa de cada cluster por dimensão: 0 = melhor, 1 = pior,
-- normalizada pelo número de clusters (k) em vez de um rank fixo
tiered_clusters as (
    select
        rc.cluster_id as cluster_id,
        (rc.recency_rank - 1) / greatest(cc.k - 1, 1) as recency_pct,
        (rc.frequency_rank - 1) / greatest(cc.k - 1, 1) as frequency_pct,
        (rc.monetary_rank - 1) / greatest(cc.k - 1, 1) as monetary_pct
    from ranked_clusters rc
    cross join cluster_count cc
),

rfm_tiers as (
    select
        cluster_id,
        case when recency_pct < 0.34 then 'high' when recency_pct < 0.67 then 'mid' else 'low' end as recency_tier,
        case when frequency_pct < 0.34 then 'high' when frequency_pct < 0.67 then 'mid' else 'low' end as frequency_tier,
        case when monetary_pct < 0.34 then 'high' when monetary_pct < 0.67 then 'mid' else 'low' end as monetary_tier
    from tiered_clusters
),

labeled_clusters as (
    select
        cluster_id,
        case
            when recency_tier = 'high' and frequency_tier = 'high' and monetary_tier = 'high' then 'Champions'
            when frequency_tier = 'high' and monetary_tier in ('high', 'mid') then 'Loyal'
            when recency_tier = 'low' and (frequency_tier in ('high', 'mid') or monetary_tier in ('high', 'mid')) then 'At Risk'
            when recency_tier = 'high' then 'Promising'
            when recency_tier = 'low' and frequency_tier = 'low' and monetary_tier = 'low' then 'Lost'
            else 'Hibernating'
        end as segment_label
    from rfm_tiers
),

tiers as (
    select
        customer_id,
        ntile(3) over (order by net_revenue desc) as tier_bucket
    from {{ ref('feat_rfm_features') }}
    where has_purchase_history
)

select
    cc.customer_id as customer_id,
    cc.cluster_id as cluster_id,
    lc.segment_label as segment_label,
    case t.tier_bucket when 1 then 'Gold' when 2 then 'Silver' else 'Bronze' end as tier,
    now() as segmented_at
from {{ source('raw', 'customer_clusters') }} cc
left join labeled_clusters lc on cc.cluster_id = lc.cluster_id
left join tiers t on cc.customer_id = t.customer_id
