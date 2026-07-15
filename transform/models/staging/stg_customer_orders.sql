-- revenue = totalvalue (itens + frete + impostos).
select
    orderid as order_id,
    clientid as customer_id,
    {{ try_cast('authorizeddate', 'timestamp') }} as purchased_at,
    totalvalue as revenue,
    shippingvalue as shipping_value,
    taxvalue as tax_value,
    coupon,
    paymentnames as payment_type,
    status as order_status_code,
    statusdescription as order_status_id,
    saleschannel as channel_id,
    nullif(affiliateid, '') as affiliate_id
from {{ source('raw', 'orders') }}
