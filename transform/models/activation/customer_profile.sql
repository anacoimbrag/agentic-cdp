{{ config(order_by=['customer_id']) }}
with profiles as (
    select * from {{ ref('stg_cdp_customer_profiles') }}
),

order_agg as (
    select
        customer_id,
        count(*) as total_orders,
        sum(revenue) as total_revenue,
        avg(revenue) as avg_order_value,
        min(purchased_at) as first_purchase_at,
        max(purchased_at) as last_purchase_at
    from {{ ref('stg_customer_orders') }}
    group by 1
),

refund_agg as (
    select
        customer_id,
        count(*) as total_refunds,
        sum(refund_value) as total_refund_value
    from {{ ref('stg_customer_refunds') }}
    group by 1
),

category_totals as (
    select customer_id, category, sum(quantity) as qty
    from {{ ref('stg_customer_order_items') }}
    group by 1, 2
),
favorite_category as (
    select customer_id, category as favorite_category
    from (
        select customer_id, category,
               row_number() over (partition by customer_id order by qty desc, category) as rn
        from category_totals
    )
    where rn = 1
),

brand_totals as (
    select customer_id, brand, sum(quantity) as qty
    from {{ ref('stg_customer_order_items') }}
    group by 1, 2
),
favorite_brand as (
    select customer_id, brand as favorite_brand
    from (
        select customer_id, brand,
               row_number() over (partition by customer_id order by qty desc, brand) as rn
        from brand_totals
    )
    where rn = 1
),

-- Comportamento e localização do GA4, unidos por user_pseudo_id.
behavior as (
    select * from {{ ref('stg_ga4_customer_behavior') }}
),

-- Segmento/tier calculados por ml/segmentation/train_kmeans.py + rotulados
-- em feat_customer_segment_labels.sql (caso de uso 1: clusterização
-- dinâmica). Clientes sem histórico de compra não entram no K-Means, então
-- ficam sem cluster_id/segment_label — tratados como 'no_purchase' abaixo.
segments as (
    select * from {{ ref('feat_customer_segment_labels') }}
),

-- Próxima campanha sugerida (caso de uso 2), em 4 camadas de prioridade:
-- 1) modelo de propensão (ml/campaigns/train_propensity.py) quando o
--    cliente tem exposição registrada; 2) conversão histórica do segmento
--    do cliente; 3) conversão histórica geral; 4) promoção ativa mais
--    recente, como último recurso.
propensity_ranked as (
    select
        cp.customer_id as customer_id,
        cp.promotion_id as promotion_id,
        cp.propensity_score as propensity_score,
        cp.propensity_score * coalesce(r.avg_order_value, 0) as expected_value,
        row_number() over (
            partition by cp.customer_id
            order by cp.propensity_score * coalesce(r.avg_order_value, 0) desc
        ) as rn
    from {{ source('raw', 'campaign_propensity') }} cp
    inner join {{ ref('dim_promotions') }} dp on cp.promotion_id = dp.promotion_id
    left join {{ ref('feat_rfm_features') }} r on cp.customer_id = r.customer_id
    where dp.is_active and not dp.is_archived
),
best_propensity as (
    select customer_id, promotion_id, expected_value as score
    from propensity_ranked
    where rn = 1
),

segment_fallback_ranked as (
    select
        s.customer_id as customer_id,
        sca.promotion_id as promotion_id,
        sca.conversion_rate as conversion_rate,
        row_number() over (
            partition by s.customer_id
            order by sca.rank_in_segment
        ) as rn
    from segments s
    inner join {{ ref('segment_campaign_affinity') }} sca
        on s.segment_label = sca.segment_label
    where sca.rank_in_segment = 1
),
best_segment_fallback as (
    select customer_id, promotion_id, conversion_rate as score
    from segment_fallback_ranked
    where rn = 1
),

-- Subselects escalares (não `limit 1` sobre um join/cross join) para
-- garantir sempre exatamente 1 linha, mesmo quando não há nenhuma
-- conversão histórica ainda (senão o cross join abaixo zeraria todo mundo).
overall_fallback as (
    select
        (select promotion_id from {{ ref('segment_campaign_affinity') }}
         where rank_overall = 1 limit 1) as promotion_id,
        (select overall_conversion_rate from {{ ref('segment_campaign_affinity') }}
         where rank_overall = 1 limit 1) as score
),

most_recent_active_promotion as (
    select
        (select promotion_id from {{ ref('dim_promotions') }}
         where is_active and not is_archived
         order by last_modified_at desc limit 1) as promotion_id
),

next_best_campaign as (
    select
        p.customer_id as customer_id,
        coalesce(bp.promotion_id, bsf.promotion_id, ofb.promotion_id, mrap.promotion_id)
            as promotion_id,
        coalesce(bp.score, bsf.score, ofb.score) as score,
        case
            when bp.promotion_id is not null then 'propensity_model'
            when bsf.promotion_id is not null then 'segment_affinity'
            when ofb.promotion_id is not null then 'overall_affinity'
            else 'most_recent_fallback'
        end as reason
    from profiles p
    left join best_propensity bp on p.customer_id = bp.customer_id
    left join best_segment_fallback bsf on p.customer_id = bsf.customer_id
    cross join overall_fallback ofb
    cross join most_recent_active_promotion mrap
)

select
    p.customer_id as customer_id,
    p.user_pseudo_id as user_pseudo_id,
    p.first_name as first_name,
    p.last_name as last_name,
    p.full_name as full_name,
    p.document_id as document_id,
    p.document_type as document_type,
    p.gender as gender,
    p.birth_date as birth_date,
    p.age as age,
    p.language_preference as language_preference,
    p.email_opt_in as email_opt_in,
    p.sms_opt_in as sms_opt_in,
    p.push_opt_in as push_opt_in,
    p.whatsapp_opt_in as whatsapp_opt_in,
    p.primary_email as primary_email,
    p.email_verified as email_verified,
    p.has_verified_phone as has_verified_phone,
    b.location_country as location_country,
    b.location_region as location_region,
    b.location_city as location_city,
    b.preferred_device_category as preferred_device_category,
    b.viewed_top_category as viewed_top_category,
    b.viewed_top_brand as viewed_top_brand,
    b.total_events as ga4_total_events,
    b.distinct_days_active as ga4_distinct_days_active,
    b.ga4_first_seen_at as ga4_first_seen_at,
    b.ga4_last_seen_at as ga4_last_seen_at,
    coalesce(oa.total_orders, 0) as total_orders,
    coalesce(oa.total_revenue, 0) as total_revenue,
    oa.avg_order_value as avg_order_value,
    oa.first_purchase_at as first_purchase_at,
    oa.last_purchase_at as last_purchase_at,
    dateDiff('day', oa.last_purchase_at, now()) as recency_days,
    coalesce(ra.total_refunds, 0) as total_refunds,
    coalesce(ra.total_refund_value, 0) as total_refund_value,
    coalesce(oa.total_revenue, 0) - coalesce(ra.total_refund_value, 0) as net_revenue,
    fc.favorite_category as favorite_category,
    fb.favorite_brand as favorite_brand,
    s.cluster_id as cluster_id,
    coalesce(s.segment_label, 'no_purchase') as segment_label,
    s.tier as tier,
    s.segmented_at as segmented_at,
    nbc.promotion_id as next_best_promotion_id,
    dp.promotion_name as next_best_promotion_name,
    nbc.score as next_best_campaign_score,
    nbc.reason as next_best_campaign_reason,
    now() as campaign_scored_at
from profiles p
left join behavior b on p.user_pseudo_id = b.user_pseudo_id
left join order_agg oa on p.customer_id = oa.customer_id
left join refund_agg ra on p.customer_id = ra.customer_id
left join favorite_category fc on p.customer_id = fc.customer_id
left join favorite_brand fb on p.customer_id = fb.customer_id
left join segments s on p.customer_id = s.customer_id
left join next_best_campaign nbc on p.customer_id = nbc.customer_id
left join {{ ref('dim_promotions') }} dp on nbc.promotion_id = dp.promotion_id
