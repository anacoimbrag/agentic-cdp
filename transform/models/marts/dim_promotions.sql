{{ config(order_by=['promotion_id']) }}
select
    -- utm_campaign é a chave natural referenciada por fct_customer_orders.coupon.
    utm_campaign as promotion_id,
    promotion_name,
    description,
    promotion_type,
    is_active,
    is_archived,
    has_max_price_per_item,
    max_usage,
    last_modified_at,
    utm_source,
    condition_ids_json
from {{ ref('stg_promotions') }}
