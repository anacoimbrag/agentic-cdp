{{ config(order_by=['payment_method_id']) }}
-- payment_method_id é a chave natural; payment_method_name é o rótulo de exibição.
select distinct
    payment_type as payment_method_id,
    payment_type as payment_method_name
from {{ ref('stg_customer_orders') }}
