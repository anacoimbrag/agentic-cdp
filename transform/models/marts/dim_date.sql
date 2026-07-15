-- Calendário cobrindo tanto o intervalo de pedidos quanto o de tráfego GA4
-- (fct_site_traffic), que começa bem antes do primeiro pedido observado.
with bounds as (
    select
        least(
            (select cast(min(purchased_at) as date) from {{ ref('stg_customer_orders') }}),
            (select min(traffic_date) from {{ ref('stg_ga4_site_traffic') }})
        ) as min_date,
        greatest(
            (select cast(max(purchased_at) as date) from {{ ref('stg_customer_orders') }}),
            (select max(traffic_date) from {{ ref('stg_ga4_site_traffic') }})
        ) as max_date
)
select
    cast(date_day as date) as order_date,
    extract(year from date_day) as year,
    extract(quarter from date_day) as quarter,
    extract(month from date_day) as month,
    monthname(date_day) as month_name,
    extract(day from date_day) as day_of_month,
    isodow(date_day) as day_of_week,
    dayname(date_day) as day_name,
    extract(week from date_day) as week_of_year,
    isodow(date_day) in (6, 7) as is_weekend
from bounds, generate_series(bounds.min_date, bounds.max_date, interval 1 day) as t(date_day)
