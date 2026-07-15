with parsed as (
    select
        orderid as order_id,
        clientid as customer_id,
        {{ try_cast('authorizeddate', 'timestamp') }} as purchased_at,
        JSONExtractArrayRaw(items) as items
    from {{ source('raw', 'orders') }}
)
select
    customer_id,
    order_id,
    purchased_at,
    JSONExtractString(i, 'itemId') as item_id,
    JSONExtractString(i, 'itemName') as item_name,
    JSONExtractString(i, 'brand') as brand,
    JSONExtractString(i, 'category') as category,
    JSONExtractString(i, 'variant') as variant,
    JSONExtractInt(i, 'quantity') as quantity,
    JSONExtractFloat(i, 'price') as price
from parsed
array join items as i
