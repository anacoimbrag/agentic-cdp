{{ config(order_by=['affiliate_id']) }}
-- value_accumulated: receita total dos pedidos atribuídos ao afiliado.
with orders_by_affiliate as (
    select
        affiliate_id,
        sum(revenue) as value_accumulated
    from {{ ref('stg_customer_orders') }}
    where affiliate_id is not null
    group by 1
)
select
    a.affiliate_id as affiliate_id,
    a.affiliate_name as affiliate_name,
    a.follow_up_email as follow_up_email,
    a.store_handle as store_handle,
    a.commission_rate as commission_rate,
    coalesce(o.value_accumulated, 0) as value_accumulated
from {{ ref('stg_affiliates') }} a
left join orders_by_affiliate o on a.affiliate_id = o.affiliate_id
