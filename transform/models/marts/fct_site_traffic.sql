-- Grao: dia x canal x midia. Mede trafego de sessao do GA4 (todos os
-- visitantes) para calcular taxa de conversao real (sessao -> compra),
-- que dim_customers nao consegue medir por so conter clientes ja
-- identificados no CDP.
select
    traffic_date,
    channel_id,
    medium,
    sum(sessions) as sessions,
    sum(purchasing_sessions) as purchasing_sessions,
    sum(visitors) as visitors,
    round(sum(purchasing_sessions)::double / nullif(sum(sessions), 0), 4) as conversion_rate
from {{ ref('stg_ga4_site_traffic') }}
group by 1, 2, 3
