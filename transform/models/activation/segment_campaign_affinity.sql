{{ config(order_by=['segment_label', 'promotion_id']) }}
-- "O que funciona melhor por segmento" calculado a partir do histórico real
-- de conversão (uso de cupom em fct_order_line), não de uma tabela de
-- regras escrita à mão. Grão: 1 linha por (segment_label, promotion_id).
-- Depende de feat_customer_segment_labels (não de activation.customer_profile)
-- para não criar um ciclo: customer_profile lê esta tabela pra escolher a
-- próxima campanha quando não há propensity_score do cliente.
with segment_sizes as (
    select segment_label, count(*) as segment_customer_count
    from {{ ref('feat_customer_segment_labels') }}
    where segment_label is not null
    group by 1
),

total_customers as (
    select count(*) as overall_customer_count
    from {{ ref('feat_customer_segment_labels') }}
    where segment_label is not null
),

conversions as (
    select
        s.segment_label as segment_label,
        o.promotion_id as promotion_id,
        count(distinct o.customer_id) as distinct_customers_converted
    from {{ ref('fct_order_line') }} o
    inner join {{ ref('feat_customer_segment_labels') }} s on o.customer_id = s.customer_id
    where o.promotion_id is not null and s.segment_label is not null
    group by 1, 2
),

overall_conversions as (
    select
        promotion_id,
        count(distinct customer_id) as overall_customers_converted
    from {{ ref('fct_order_line') }}
    where promotion_id is not null
    group by 1
),

overall_ranked as (
    select
        promotion_id,
        overall_customers_converted,
        dense_rank() over (order by overall_customers_converted desc) as rank_overall
    from overall_conversions
)

select
    assumeNotNull(c.segment_label) as segment_label,
    assumeNotNull(c.promotion_id) as promotion_id,
    c.distinct_customers_converted as distinct_customers_converted,
    ss.segment_customer_count as segment_customer_count,
    c.distinct_customers_converted::double / ss.segment_customer_count as conversion_rate,
    row_number() over (
        partition by c.segment_label
        order by c.distinct_customers_converted::double / ss.segment_customer_count desc
    ) as rank_in_segment,
    orank.overall_customers_converted as overall_customers_converted,
    tc.overall_customer_count as overall_customer_count,
    orank.overall_customers_converted::double / tc.overall_customer_count as overall_conversion_rate,
    orank.rank_overall as rank_overall
from conversions c
inner join segment_sizes ss on c.segment_label = ss.segment_label
inner join overall_ranked orank on c.promotion_id = orank.promotion_id
cross join total_customers tc
