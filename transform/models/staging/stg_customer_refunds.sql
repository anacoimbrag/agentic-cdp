-- Reembolsos: pedidos cancelados (refundedat preenchido).
select
    clientid as customer_id,
    orderid as order_id,
    {{ try_cast('refundedat', 'timestamp') }} as refunded_at,
    refundvalue as refund_value
from {{ source('raw', 'orders') }}
where refundedat is not null
