{{ config(order_by=['customer_id', 'promotion_slug']) }}
-- Exposição a campanha por cliente (não por user_pseudo_id): junta
-- raw.ga4_promotion_engagement (gravada por
-- scripts/load_ga4_customer_behavior.py) ao customer_id via
-- stg_cdp_customer_profiles. Alimenta feat_campaign_training_data.sql.
select
    p.customer_id as customer_id,
    e.promotion_slug as promotion_slug,
    e.view_count as view_count,
    e.select_count as select_count,
    e.first_seen_at as first_seen_at,
    e.last_seen_at as last_seen_at
from {{ source('raw', 'ga4_promotion_engagement') }} e
inner join {{ ref('stg_cdp_customer_profiles') }} p
    on e.user_pseudo_id = p.user_pseudo_id
