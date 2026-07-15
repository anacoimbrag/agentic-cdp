{{ config(order_by=['order_date']) }}
-- Calendário cobrindo tanto o intervalo de pedidos quanto o de tráfego GA4
-- (fct_site_traffic), que começa bem antes do primeiro pedido observado.
with bounds as (
    select
        least(
            (select min(cast(purchased_at as Date)) from {{ ref('stg_customer_orders') }}),
            (select min(traffic_date) from {{ ref('stg_ga4_site_traffic') }})
        ) as min_date,
        greatest(
            (select max(cast(purchased_at as Date)) from {{ ref('stg_customer_orders') }}),
            (select max(traffic_date) from {{ ref('stg_ga4_site_traffic') }})
        ) as max_date
),

calendar as (
    select addDays(bounds.min_date, number) as date_day
    from bounds
    array join range(dateDiff('day', bounds.min_date, bounds.max_date) + 1) as number
)

select
    assumeNotNull(date_day) as order_date,
    toYear(date_day) as year,
    toQuarter(date_day) as quarter,
    toMonth(date_day) as month,
    formatDateTime(date_day, '%M') as month_name,
    toDayOfMonth(date_day) as day_of_month,
    toDayOfWeek(date_day) as day_of_week,
    formatDateTime(date_day, '%W') as day_name,
    toISOWeek(date_day) as week_of_year,
    toDayOfWeek(date_day) in (6, 7) as is_weekend
from calendar
