-- Trafego de sessao do GA4 por dia/plataforma/midia, ja agregado por
-- scripts/load_ga4_site_traffic.py (todos os visitantes, nao so clientes).
select
    toDate(parseDateTimeOrNull(event_date, '%Y%m%d')) as traffic_date,
    platform,
    -- so ha equivalente de canal para Site/App: o GA4 da propria loja nao
    -- rastreia compras feitas dentro do Marketplace (dim_channel.channel_id = 4).
    case
        when platform = 'WEB' then 1
        when platform in ('ANDROID', 'IOS') then 2
    end as channel_id,
    coalesce(medium, '(not set)') as medium,
    sessions,
    cart_sessions,
    purchasing_sessions,
    visitors
from {{ source('raw', 'ga4_site_traffic') }}
