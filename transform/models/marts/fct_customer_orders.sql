{{ config(order_by=['order_id']) }}
select
    o.customer_id as customer_id,
    o.order_id as order_id,
    -- coupon é a referência de promoção do pedido (dim_promotions.promotion_id).
    o.coupon as promotion_id,
    o.purchased_at as purchased_at,
    cast(o.purchased_at as date) as order_date,
    o.revenue as revenue,
    o.shipping_value as shipping_value,
    o.tax_value as tax_value,
    o.payment_type as payment_method_id,
    o.order_status_id as order_status_id,
    o.channel_id as channel_id,
    o.affiliate_id as affiliate_id
from {{ ref('stg_customer_orders') }} o
