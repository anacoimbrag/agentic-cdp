{{ config(order_by=['channel_id']) }}
-- Um registro por canal de venda (1 Site, 2 App, 4 Marketplace).
select
    channel_id,
    case channel_id
        when 1 then 'Site'
        when 2 then 'App'
        when 4 then 'Marketplace'
    end as channel_name
from (select distinct channel_id from {{ ref('stg_customer_orders') }})
