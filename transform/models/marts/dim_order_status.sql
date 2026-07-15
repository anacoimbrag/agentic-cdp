{{ config(order_by=['order_status_id']) }}
-- order_status_id (descrição em português) é a chave natural;
-- order_status_code é o código técnico e status_name o rótulo de exibição.
select distinct
    order_status_id,
    order_status_code,
    order_status_id as status_name
from {{ ref('stg_customer_orders') }}
