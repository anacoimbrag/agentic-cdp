{{ config(order_by=['order_id', 'sku_id']) }}
-- Grão: um registro por item de pedido (order_id, sku_id). product_id,
-- category_id e brand_id vêm de dim_products (join por sku_id); os demais
-- atributos do pedido são denormalizados a partir de stg_customer_orders.
select
    oi.customer_id as customer_id,
    oi.order_id as order_id,
    dp.product_id as product_id,
    dp.category_id as category_id,
    dp.brand_id as brand_id,
    o.coupon as promotion_id,
    o.payment_type as payment_method_id,
    o.order_status_id as order_status_id,
    o.channel_id as channel_id,
    o.affiliate_id as affiliate_id,
    oi.purchased_at as purchased_at,
    cast(oi.purchased_at as date) as order_date,
    oi.item_id as sku_id,
    oi.item_name as item_name,
    oi.brand as brand,
    oi.category as category,
    oi.variant as variant,
    oi.quantity as quantity,
    oi.price as price,
    oi.quantity * oi.price as line_amount
from {{ ref('stg_customer_order_items') }} oi
left join {{ ref('dim_products') }} dp on oi.item_id = dp.sku_id
left join {{ ref('stg_customer_orders') }} o on oi.order_id = o.order_id
