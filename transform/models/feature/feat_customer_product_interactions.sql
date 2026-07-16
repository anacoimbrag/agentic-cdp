{{ config(order_by=['customer_id', 'product_id']) }}
-- Feature view para ml/training/recommendations/train_item_similarity.py: matriz
-- implícita cliente x produto (grão: 1 linha por customer_id x product_id
-- com interação). O peso vem só de compras reais (fct_order_line) — o
-- comportamento do GA4 disponível hoje é agregado por categoria/marca
-- (viewed_top_category/viewed_top_brand em customer_profile), não por
-- produto individual, então não dá pra usá-lo como peso produto a produto
-- sem inventar dado; esse sinal já é aproveitado como fallback content-based
-- em activation/customer_showcase.sql.
select
    customer_id,
    assumeNotNull(product_id) as product_id,
    sum(quantity) as interaction_weight
from {{ ref('fct_order_line') }}
where product_id is not null
group by 1, 2
