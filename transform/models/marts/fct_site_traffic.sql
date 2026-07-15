-- Grao: dia x canal x midia. Mede o funil de sessao do GA4 (todos os
-- visitantes) em 3 etapas -- sessions -> cart_sessions -> purchasing_sessions
-- -- para calcular taxa de conversao real, que dim_customers nao consegue
-- medir por so conter clientes ja identificados no CDP.
select
    traffic_date,
    channel_id,
    medium,
    sum(sessions) as sessions,
    sum(cart_sessions) as cart_sessions,
    sum(purchasing_sessions) as purchasing_sessions,
    sum(visitors) as visitors,
    round(sum(cart_sessions)::double / nullif(sum(sessions), 0), 4) as cart_conversion_rate,
    round(sum(purchasing_sessions)::double / nullif(sum(cart_sessions), 0), 4) as checkout_conversion_rate,
    round(sum(purchasing_sessions)::double / nullif(sum(sessions), 0), 4) as conversion_rate
from {{ ref('stg_ga4_site_traffic') }}
group by 1, 2, 3
