{{ config(order_by=['customer_id']) }}
-- Traduz raw.customer_clusters (cluster_id cru, saída do K-Means) em rótulos
-- de negócio (segment_label/tier). Fica em feature/, não em activation/,
-- porque tem dois consumidores que não podem depender um do outro:
-- activation/customer_profile.sql e activation/segment_campaign_affinity.sql
-- (essa última mede conversão histórica POR segmento, então não pode
-- depender de customer_profile, senão vira ciclo).
--
-- Rotulagem: ordena os clusters por net_revenue médio (dense_rank desc) e
-- espalha a posição proporcionalmente sobre uma escala fixa de 6 rótulos
-- (Champions...Lost), não hardcoded para um k específico — b­ate com
-- qualquer k que o K-Means escolher (3 a 8, ver ml/segmentation/train_kmeans.py).
with cluster_stats as (
    select
        cc.cluster_id as cluster_id,
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
        cluster_id,
        dense_rank() over (order by avg_net_revenue desc) as value_rank
    from cluster_stats
),

labeled_clusters as (
    select
        rc.cluster_id as cluster_id,
        ['Champions', 'Loyal', 'Promising', 'At Risk', 'Hibernating', 'Lost'][
            least(6, 1 + cast(floor((rc.value_rank - 1) * 6.0 / cc.k) as integer))
        ] as segment_label
    from ranked_clusters rc
    cross join cluster_count cc
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
