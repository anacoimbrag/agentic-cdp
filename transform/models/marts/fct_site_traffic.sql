{{ config(order_by=['traffic_date', 'medium']) }}
-- Grao: dia x canal x midia. Mede o funil de sessao do GA4 (todos os
-- visitantes) em 3 etapas -- sessions -> cart_sessions -> purchasing_sessions
-- -- para calcular taxa de conversao real, que dim_customers nao consegue
-- medir por so conter clientes ja identificados no CDP.
with agg as (
    select
        assumeNotNull(traffic_date) as traffic_date,
        channel_id,
        medium,
        sum(sessions) as sessions,
        sum(cart_sessions) as cart_sessions,
        sum(purchasing_sessions) as purchasing_sessions,
        sum(visitors) as visitors
    from {{ ref('stg_ga4_site_traffic') }}
    group by 1, 2, 3
)
select
    traffic_date,
    channel_id,
    medium,
    sessions,
    cart_sessions,
    purchasing_sessions,
    visitors,
    round(cart_sessions::double / nullif(sessions, 0), 4) as cart_conversion_rate,
    round(purchasing_sessions::double / nullif(cart_sessions, 0), 4) as checkout_conversion_rate,
    round(purchasing_sessions::double / nullif(sessions, 0), 4) as conversion_rate
from agg
