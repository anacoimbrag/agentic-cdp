{{ config(order_by=['customer_id', 'rank']) }}
-- Vitrine inteligente personalizada (caso de uso 3): top-12 produtos por
-- cliente, combinando 3 sinais em SQL puro (regra de scoring do plano):
-- 1) similaridade de produto (ml/recommendations/train_item_similarity.py),
--    com decaimento por recência da compra original (meia-vida ~90 dias);
-- 2) cesta de compra (product_affinity, lift normalizado 0-1 via x/(1+x));
-- 3) fallback content-based por categoria/marca favorita (cold start),
--    peso fixo 0.5 — só preenche vaga quando 1 e 2 não bastam.
with purchased as (
    select customer_id, product_id, max(purchased_at) as last_purchased_at
    from {{ ref('fct_order_line') }}
    where product_id is not null
    group by 1, 2
),

similarity_candidates as (
    select
        p.customer_id as customer_id,
        sim.product_id_b as product_id,
        max(
            sim.similarity_score
            * exp(-dateDiff('day', p.last_purchased_at, now()) / 90.0)
        ) as score
    from purchased p
    inner join {{ source('raw', 'product_similarity') }} sim
        on p.product_id = sim.product_id_a
    left join purchased already
        on p.customer_id = already.customer_id and sim.product_id_b = already.product_id
    where already.product_id is null
    group by 1, 2
),

basket_candidates as (
    select
        p.customer_id as customer_id,
        pa.product_id_b as product_id,
        max((pa.lift / (1 + pa.lift)) * pa.confidence_a_to_b) as score
    from purchased p
    inner join {{ ref('product_affinity') }} pa on p.product_id = pa.product_id_a
    left join purchased already
        on p.customer_id = already.customer_id and pa.product_id_b = already.product_id
    where already.product_id is null
    group by 1, 2
),

product_popularity as (
    select product_id, category, brand, count(distinct order_id) as order_count
    from {{ ref('fct_order_line') }}
    where product_id is not null
    group by 1, 2, 3
),
max_popularity as (
    select max(order_count) as max_order_count from product_popularity
),
content_candidates as (
    select
        cp.customer_id as customer_id,
        pp.product_id as product_id,
        (pp.order_count::double / mp.max_order_count) * 0.5 as score
    from {{ ref('customer_profile') }} cp
    inner join product_popularity pp
        on pp.category = cp.favorite_category or pp.brand = cp.favorite_brand
    cross join max_popularity mp
    left join purchased already
        on cp.customer_id = already.customer_id and pp.product_id = already.product_id
    where already.product_id is null
      and (cp.favorite_category is not null or cp.favorite_brand is not null)
),

-- SKU representativo por produto (o mais vendido), pra exibir na vitrine.
representative_sku as (
    select product_id, sku_id
    from (
        select
            product_id, sku_id,
            row_number() over (partition by product_id order by sum(quantity) desc) as rn
        from {{ ref('fct_order_line') }}
        where product_id is not null
        group by product_id, sku_id
    )
    where rn = 1
),

all_candidates as (
    select customer_id, product_id, score, 'item_similarity' as reason from similarity_candidates
    union all
    select customer_id, product_id, score, 'basket_affinity' as reason from basket_candidates
    union all
    select customer_id, product_id, score, 'favorite_category_fallback' as reason from content_candidates
),

-- Dedup: um produto pode aparecer via mais de um sinal — fica só com o
-- maior score e o motivo correspondente.
deduped as (
    select customer_id, product_id, score, reason
    from (
        select
            customer_id, product_id, score, reason,
            row_number() over (
                partition by customer_id, product_id order by score desc
            ) as rn
        from all_candidates
    )
    where rn = 1
),

ranked as (
    select
        customer_id, product_id, score, reason,
        row_number() over (partition by customer_id order by score desc) as rank
    from deduped
)

select
    r.customer_id as customer_id,
    r.rank as rank,
    r.product_id as product_id,
    rs.sku_id as sku_id,
    r.reason as reason,
    r.score as score,
    now() as computed_at
from ranked r
left join representative_sku rs on r.product_id = rs.product_id
where r.rank <= 12
