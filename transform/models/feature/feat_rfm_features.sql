{{ config(order_by=['customer_id']) }}
-- Feature view para ml/segmentation/train_kmeans.py. Recalcula RFM direto das
-- staging sources (não a partir de activation.customer_profile) para não
-- criar uma dependência circular entre o model que consome o output do
-- K-Means e o model que alimenta o treino.
with profiles as (
    select customer_id from {{ ref('stg_cdp_customer_profiles') }}
),

order_agg as (
    select
        customer_id,
        count(*) as total_orders,
        sum(revenue) as total_revenue,
        avg(revenue) as avg_order_value,
        max(purchased_at) as last_purchase_at
    from {{ ref('stg_customer_orders') }}
    group by 1
),

refund_agg as (
    select
        customer_id,
        sum(refund_value) as total_refund_value
    from {{ ref('stg_customer_refunds') }}
    group by 1
)

select
    p.customer_id as customer_id,
    coalesce(oa.total_orders, 0) as total_orders,
    coalesce(oa.total_revenue, 0) - coalesce(ra.total_refund_value, 0) as net_revenue,
    oa.avg_order_value as avg_order_value,
    dateDiff('day', oa.last_purchase_at, now()) as recency_days,
    oa.total_orders is not null and oa.total_orders > 0 as has_purchase_history
from profiles p
left join order_agg oa on p.customer_id = oa.customer_id
left join refund_agg ra on p.customer_id = ra.customer_id
