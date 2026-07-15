{{ config(order_by=['product_id_a', 'product_id_b']) }}
-- Market basket puro em SQL (sem ML): "quem comprou X também comprou Y",
-- agregado por product_id (não sku_id, pra não fragmentar variações de
-- tamanho/cor do mesmo produto em pares diferentes). Consumida por
-- customer_showcase.sql como um dos 3 sinais de recomendação.
with order_products as (
    select distinct order_id, assumeNotNull(product_id) as product_id
    from {{ ref('fct_order_line') }}
    where product_id is not null
),

-- Corta pedidos com carrinho muito grande antes do self-join, pra não
-- explodir combinatoriamente (um pedido de 50 itens gera ~2500 pares).
order_product_counts as (
    select order_id, count(*) as item_count
    from order_products
    group by 1
    having count(*) <= 20
),

pairs as (
    select
        a.product_id as product_id_a,
        b.product_id as product_id_b,
        a.order_id as order_id
    from order_products a
    inner join order_products b
        on a.order_id = b.order_id and a.product_id != b.product_id
    inner join order_product_counts opc on a.order_id = opc.order_id
),

co_occurrence as (
    select product_id_a, product_id_b, count(distinct order_id) as co_occurrence_count
    from pairs
    group by 1, 2
    -- lift fica instável em pares raros; exige pelo menos 3 pedidos em comum.
    having count(distinct order_id) >= 3
),

product_order_counts as (
    select product_id, count(distinct order_id) as order_count
    from order_products
    group by 1
),

total_orders as (
    select count(distinct order_id) as n_orders from order_products
)

select
    co.product_id_a as product_id_a,
    co.product_id_b as product_id_b,
    co.co_occurrence_count as co_occurrence_count,
    co.co_occurrence_count::double / t.n_orders as support,
    co.co_occurrence_count::double / poa.order_count as confidence_a_to_b,
    (co.co_occurrence_count::double / poa.order_count)
        / (pob.order_count::double / t.n_orders) as lift
from co_occurrence co
inner join product_order_counts poa on co.product_id_a = poa.product_id
inner join product_order_counts pob on co.product_id_b = pob.product_id
cross join total_orders t
