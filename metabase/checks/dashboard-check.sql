-- ============================================================
-- Dashboard: Agentic CDP - Dashboard (Metabase dashboard id 19)
-- Versao para rodar direto no DBeaver (sem query parameters nativos
-- do ClickHouse, que o driver JDBC do DBeaver nao resolve sozinho).
--
-- Cenario fixo:
--   periodo  = 2026-06-01 a 2026-06-30
--   categoria = (todas)
--   regiao    = (todas)
--   canal     = (todos)
--
-- Para ver outro periodo, troque as duas datas abaixo com
-- Find & Replace (Ctrl+R): '2026-06-01' e '2026-06-30'.
--
-- Cada SELECT tem uma coluna "card" na frente com o nome do card,
-- pra identificar o resultado quando roda o script inteiro (Alt+X)
-- e varias abas de resultado abrem de uma vez.
--
-- Rode bloco a bloco (Ctrl+Enter) ou o script inteiro (Alt+X).
-- ============================================================


-- ------------------------------------------------------------
-- GMV
-- ------------------------------------------------------------
SELECT
    'GMV' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    sum(ol.line_amount) AS gmv
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Receita Liquida
-- ------------------------------------------------------------
WITH filtered_orders AS (
    SELECT o.order_id, o.order_date
    FROM marts.fct_customer_orders o
    WHERE o.order_status_id != 'Cancelado'
      AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
),
line_revenue AS (
    SELECT
        toStartOfMonth(ol.order_date) AS mes,
        sumIf(ol.line_amount, ol.order_status_id != 'Cancelado') AS bruta
    FROM marts.fct_order_line ol
    WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
    GROUP BY mes
),
refunds AS (
    -- reembolsos sao order-grain (raw.orders.refundvalue), sem categoria
    SELECT toStartOfMonth(fo.order_date) AS mes, sum(r.refundvalue) AS reembolsos
    FROM raw.orders r
    INNER JOIN filtered_orders fo ON fo.order_id = r.orderid
    WHERE r.refundedat IS NOT NULL
    GROUP BY mes
)
SELECT
    'Receita Liquida' AS card,
    lr.mes AS mes,
    lr.bruta - coalesce(rf.reembolsos, 0) AS receita_liquida
FROM line_revenue lr
LEFT JOIN refunds rf ON rf.mes = lr.mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 503: LTV Medio (historico)
-- ------------------------------------------------------------
SELECT
    'LTV Medio (historico)' AS card,
    avg(net_revenue) AS ltv_medio
FROM marts.dim_customers
WHERE total_orders > 0;


-- ------------------------------------------------------------
-- Card 505: Progressao Mensal da Receita
-- ------------------------------------------------------------
SELECT
    toStartOfMonth(ol.order_date) AS mes,
    sum(ol.line_amount) AS receita
FROM marts.fct_order_line ol
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 504: Taxa de Recompra por Janela
-- ------------------------------------------------------------
SELECT
    janela,
    taxa_recompra
FROM (
    WITH customer_orders AS (
        SELECT
            o.customer_id,
            o.order_date,
            row_number() OVER (PARTITION BY o.customer_id ORDER BY o.order_date) AS rn
        FROM marts.fct_customer_orders o
        WHERE o.order_status_id != 'Cancelado'
    ),
    first_second AS (
        SELECT
            customer_id,
            minIf(order_date, rn = 1) AS first_order,
            anyIf(order_date, rn = 2) AS second_order,
            max(rn) AS total_orders
        FROM customer_orders
        GROUP BY customer_id
    ),
    base AS (
        SELECT
            count() AS total_customers,
            countIf(total_orders >= 2 AND dateDiff('day', first_order, second_order) <= 30) AS r30,
            countIf(total_orders >= 2 AND dateDiff('day', first_order, second_order) <= 60) AS r60,
            countIf(total_orders >= 2 AND dateDiff('day', first_order, second_order) <= 90) AS r90
        FROM first_second
    )
    SELECT '30 dias' AS janela, r30 / total_customers AS taxa_recompra, 1 AS ordem FROM base
    UNION ALL
    SELECT '60 dias', r60 / total_customers, 2 FROM base
    UNION ALL
    SELECT '90 dias', r90 / total_customers, 3 FROM base
)
ORDER BY ordem;


-- ------------------------------------------------------------
-- Card 516: Matriz de Cohort (retencao de recompra) por Segmento
-- ------------------------------------------------------------
WITH first_purchase AS (
    SELECT o.customer_id, min(o.order_date) AS cohort_date
    FROM marts.fct_customer_orders o
    WHERE o.order_status_id != 'Cancelado'
    GROUP BY o.customer_id
),
customer_segment AS (
    SELECT cp.customer_id, cp.segment_label
    FROM activation.customer_profile cp
    WHERE cp.segment_label != 'no_purchase'
),
base AS (
    SELECT fp.customer_id, cs.segment_label, toStartOfMonth(fp.cohort_date) AS cohort_month
    FROM first_purchase fp
    INNER JOIN customer_segment cs ON cs.customer_id = fp.customer_id
),
orders_with_offset AS (
    SELECT o.customer_id, dateDiff('month', b.cohort_month, toStartOfMonth(o.order_date)) AS mes_apos_aquisicao
    FROM marts.fct_customer_orders o
    INNER JOIN base b ON b.customer_id = o.customer_id
    WHERE o.order_status_id != 'Cancelado'
),
bounds AS (
    SELECT toStartOfMonth(max(order_date)) AS max_month
    FROM marts.fct_customer_orders
    WHERE order_status_id != 'Cancelado'
)
SELECT
    b.segment_label AS segmento,
    count(DISTINCT b.customer_id) AS clientes_no_segmento,
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 0) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 0) <= bd.max_month), 0) AS "M0",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 1) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 1) <= bd.max_month), 0) AS "M1",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 2) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 2) <= bd.max_month), 0) AS "M2",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 3) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 3) <= bd.max_month), 0) AS "M3",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 4) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 4) <= bd.max_month), 0) AS "M4",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 5) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 5) <= bd.max_month), 0) AS "M5",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 6) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 6) <= bd.max_month), 0) AS "M6",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 7) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 7) <= bd.max_month), 0) AS "M7",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 8) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 8) <= bd.max_month), 0) AS "M8",
    uniqExactIf(o.customer_id, o.mes_apos_aquisicao = 9) / nullif(uniqExactIf(b.customer_id, addMonths(b.cohort_month, 9) <= bd.max_month), 0) AS "M9"
FROM base b
LEFT JOIN orders_with_offset o ON o.customer_id = b.customer_id
CROSS JOIN bounds bd
GROUP BY segmento
ORDER BY multiIf(
    segmento = 'Champions', 1,
    segmento = 'Loyal', 2,
    segmento = 'Promising', 3,
    segmento = 'At Risk', 4,
    segmento = 'Hibernating', 5,
    segmento = 'Lost', 6,
    7
);


-- ------------------------------------------------------------
-- Card 498: Ticket Medio
-- ------------------------------------------------------------
SELECT
    'Ticket Medio' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    sum(ol.line_amount) / count(DISTINCT ol.order_id) AS ticket_medio
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 499: Taxa de Conversao
-- ------------------------------------------------------------
SELECT
    'Taxa de Conversao' AS card,
    toStartOfMonth(ft.traffic_date) AS mes,
    sum(ft.purchasing_sessions) / sum(ft.sessions) AS taxa_conversao
FROM marts.fct_site_traffic ft
WHERE ft.traffic_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 502: Taxa de Cancelamento
-- ------------------------------------------------------------
SELECT
    'Taxa de Cancelamento' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    uniqExactIf(ol.order_id, ol.order_status_id = 'Cancelado') / uniqExact(ol.order_id) AS taxa_cancelamento
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 510: Nunca Compraram
-- ------------------------------------------------------------
SELECT
    'Nunca Compraram' AS card,
    count() AS nunca_compraram
FROM activation.customer_profile cp
WHERE cp.total_orders = 0;


-- ------------------------------------------------------------
-- Card 511: Recencia Media (dias)
-- ------------------------------------------------------------
SELECT
    'Recência Média (dias)' AS card,
    avg(cp.recency_days) AS recencia_media
FROM activation.customer_profile cp
WHERE cp.total_orders > 0;


-- ------------------------------------------------------------
-- Card 500: Numero de Pedidos
-- ------------------------------------------------------------
SELECT
    'Numero de Pedidos' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    count(DISTINCT ol.order_id) AS numero_pedidos
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 501: Numero de Clientes Ativos
-- ------------------------------------------------------------
SELECT
    'Numero de Clientes Ativos' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    count(DISTINCT ol.customer_id) AS clientes_ativos
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 506: Funil de Vendas
-- ------------------------------------------------------------
SELECT
    etapa,
    valor
FROM (
    SELECT 'Sessoes' AS etapa, sum(ft.sessions) AS valor, 1 AS ordem
    FROM marts.fct_site_traffic ft
    WHERE ft.traffic_date BETWEEN '2026-06-01' AND '2026-06-30'
    UNION ALL
    SELECT 'Adicoes ao carrinho', sum(ft.cart_sessions), 2
    FROM marts.fct_site_traffic ft
    WHERE ft.traffic_date BETWEEN '2026-06-01' AND '2026-06-30'
    UNION ALL
    SELECT 'Compra', sum(ft.purchasing_sessions), 3
    FROM marts.fct_site_traffic ft
    WHERE ft.traffic_date BETWEEN '2026-06-01' AND '2026-06-30'
)
ORDER BY ordem;


-- ------------------------------------------------------------
-- Card 513: Receita Liquida Media por Faixa de Recencia
-- ------------------------------------------------------------
WITH base AS (
    SELECT
        multiIf(cp.recency_days <= 30, '0-30 dias', cp.recency_days <= 60, '31-60 dias', cp.recency_days <= 90, '61-90 dias', '90+ dias') AS faixa_recencia,
        multiIf(cp.recency_days <= 30, 1, cp.recency_days <= 60, 2, cp.recency_days <= 90, 3, 4) AS ordem,
        cp.net_revenue AS receita_liquida
    FROM activation.customer_profile cp
    WHERE cp.total_orders > 0
),
stats AS (
    SELECT
        faixa_recencia,
        any(ordem) AS ordem,
        quantileExact(0.25)(receita_liquida) AS q1,
        quantileExact(0.5)(receita_liquida) AS mediana,
        quantileExact(0.75)(receita_liquida) AS q3,
        avg(receita_liquida) AS media
    FROM base
    GROUP BY faixa_recencia
),
bounds AS (
    SELECT
        faixa_recencia,
        ordem,
        q1,
        mediana,
        q3,
        media,
        q1 - 1.5 * (q3 - q1) AS lower_bound,
        q3 + 1.5 * (q3 - q1) AS upper_bound
    FROM stats
)
SELECT
    b.faixa_recencia,
    maxIf(base.receita_liquida, base.receita_liquida <= b.upper_bound) AS "Bigode superior",
    b.q3 AS "Q3 (75º percentil)",
    b.mediana AS "Mediana",
    b.media AS "Media",
    b.q1 AS "Q1 (25º percentil)",
    minIf(base.receita_liquida, base.receita_liquida >= b.lower_bound) AS "Bigode inferior"
FROM bounds b
INNER JOIN base ON base.faixa_recencia = b.faixa_recencia
GROUP BY b.faixa_recencia, b.q3, b.mediana, b.media, b.q1, b.ordem
ORDER BY b.ordem;


-- ------------------------------------------------------------
-- Card 515: Sessoes por Origem
-- ------------------------------------------------------------
WITH base_traffic AS (
    SELECT
        ft.medium AS origem,
        sum(ft.sessions) AS sessoes,
        sum(ft.cart_sessions) AS carrinho,
        sum(ft.purchasing_sessions) AS compras
    FROM marts.fct_site_traffic ft
    WHERE ft.traffic_date BETWEEN '2026-06-01' AND '2026-06-30'
    GROUP BY origem
)
SELECT 1 AS ordem, 'Sessoes no Site' AS etapa_origem, origem AS etapa_destino, sessoes AS volume FROM base_traffic
UNION ALL
SELECT 2 AS ordem, origem, 'Adicionou ao Carrinho', carrinho FROM base_traffic
UNION ALL
SELECT 3 AS ordem, 'Adicionou ao Carrinho', 'Compra Concluida', compras FROM base_traffic
ORDER BY ordem;


-- ------------------------------------------------------------
-- Card 514: Receita por Regiao (Mapa)
-- ------------------------------------------------------------
SELECT
    c.location_region  AS regiao,
    sum(ol.line_amount) AS receita
FROM marts.fct_order_line ol
LEFT JOIN marts.dim_customers c ON ol.customer_id = c.customer_id
  AND c.location_region != ''
GROUP BY regiao;


-- ------------------------------------------------------------
-- Card 512: Detalhamento de Afiliados
-- ------------------------------------------------------------
SELECT
    af.affiliate_name AS afiliado,
    af.commission_rate AS comissao,
    af.value_accumulated AS receita_acumulada,
    coalesce(agg.pedidos_no_periodo, 0) AS pedidos_no_periodo
FROM marts.dim_affiliates af
LEFT JOIN (
    SELECT o.affiliate_id, count(DISTINCT o.order_id) AS pedidos_no_periodo
    FROM marts.fct_customer_orders o
    WHERE o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
    GROUP BY o.affiliate_id
) agg ON agg.affiliate_id = af.affiliate_id
ORDER BY receita_acumulada DESC;


-- ------------------------------------------------------------
-- Card 517: Pedidos Faturados
-- ------------------------------------------------------------
SELECT
    'Pedidos Faturados' AS card,
    toStartOfMonth(o.order_date) AS mes,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
WHERE o.order_status_id = 'Faturado'
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 518: Pedidos Cancelados
-- ------------------------------------------------------------
SELECT
    'Pedidos Cancelados' AS card,
    toStartOfMonth(o.order_date) AS mes,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
WHERE o.order_status_id = 'Cancelado'
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 519: Pedidos Faturando
-- ------------------------------------------------------------
SELECT
    'Pedidos Faturando' AS card,
    toStartOfMonth(o.order_date) AS mes,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
WHERE o.order_status_id = 'Faturando'
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 520: Pedidos Preparando Entrega
-- ------------------------------------------------------------
SELECT
    'Pedidos Preparando Entrega' AS card,
    toStartOfMonth(o.order_date) AS mes,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
WHERE o.order_status_id = 'Preparando Entrega'
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 521: Pedidos Pagamento Aprovado
-- ------------------------------------------------------------
SELECT
    'Pedidos Pagamento Aprovado' AS card,
    toStartOfMonth(o.order_date) AS mes,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
WHERE o.order_status_id = 'Pagamento Aprovado'
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 522: SKUs Vendidos
-- ------------------------------------------------------------
SELECT
    'SKUs Vendidos' AS card,
    toStartOfMonth(ol.order_date) AS mes,
    count(DISTINCT ol.sku_id) AS qtd_skus
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY mes
ORDER BY mes;


-- ------------------------------------------------------------
-- Card 523: Volume de Pedidos por Dia da Semana
-- ------------------------------------------------------------
SELECT
    d.day_name AS dia_semana,
    d.day_of_week AS dow,
    coalesce(ch.channel_name, 'Desconhecido') AS canal,
    count(DISTINCT o.order_id) AS pedidos
FROM marts.fct_customer_orders o
LEFT JOIN marts.dim_channel ch ON o.channel_id = ch.channel_id
LEFT JOIN marts.dim_date d ON o.order_date = d.order_date
WHERE o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
GROUP BY dia_semana, dow, canal
ORDER BY dow;


-- ------------------------------------------------------------
-- Card 525: Opt-in
-- ------------------------------------------------------------
SELECT
    *
FROM (
    SELECT 'Email opt-in' AS flag, countIf(c.email_opt_in) / count(c.customer_id) AS qtd
    FROM marts.dim_customers c
    UNION ALL
    SELECT 'SMS opt-in', countIf(c.sms_opt_in) / count(c.customer_id)
    FROM marts.dim_customers c
    UNION ALL
    SELECT 'Push opt-in', countIf(c.push_opt_in) / count(c.customer_id)
    FROM marts.dim_customers c
    UNION ALL
    SELECT 'WhatsApp opt-in', countIf(c.whatsapp_opt_in) / count(c.customer_id)
    FROM marts.dim_customers c
    UNION ALL
    SELECT 'Email verificado', countIf(c.email_verified = 1) / count(c.customer_id)
    FROM marts.dim_customers c
    UNION ALL
    SELECT 'Telefone verificado', countIf(c.has_verified_phone = 1) / count(c.customer_id)
    FROM marts.dim_customers c
)
ORDER BY qtd DESC;


-- ------------------------------------------------------------
-- Card 524: Pedidos Nao Faturados
-- ------------------------------------------------------------
SELECT
    o.order_id AS pedido,
    o.order_date AS data,
    o.order_status_id AS status,
    ch.channel_name AS canal,
    o.payment_method_id AS pagamento,
    o.revenue AS receita
FROM marts.fct_customer_orders o
LEFT JOIN marts.dim_channel ch ON o.channel_id = ch.channel_id
WHERE o.order_status_id NOT IN ('Faturado', 'Cancelado')
  AND o.order_date BETWEEN '2026-06-01' AND '2026-06-30'
ORDER BY o.order_date asc
LIMIT 5;


-- ------------------------------------------------------------
-- Card 507: Top 10 Marcas
-- ------------------------------------------------------------
SELECT
    ol.brand AS marca,
    sum(ol.line_amount) AS receita
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
  AND ol.brand != ''
GROUP BY marca
ORDER BY receita DESC
LIMIT 10;


-- ------------------------------------------------------------
-- Card 508: Top 10 Categorias
-- ------------------------------------------------------------
SELECT
    ol.category AS categoria,
    sum(ol.line_amount) AS receita
FROM marts.fct_order_line ol
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
  AND ol.category != ''
GROUP BY categoria
ORDER BY receita DESC
LIMIT 10;


-- ------------------------------------------------------------
-- Card 509: Top 5 Afiliados
-- ------------------------------------------------------------
SELECT
    coalesce(af.affiliate_name, 'Sem afiliado') AS afiliado,
    sum(ol.line_amount) AS receita
FROM marts.fct_order_line ol
LEFT JOIN marts.dim_affiliates af ON ol.affiliate_id = af.affiliate_id
WHERE ol.order_date BETWEEN '2026-06-01' AND '2026-06-30'
  AND ol.affiliate_id != ''
GROUP BY afiliado
ORDER BY receita DESC
LIMIT 5;


-- ------------------------------------------------------------
-- Card 526: Tendencia de Receita (30d + previsao 90d)
-- ------------------------------------------------------------
SELECT
    'Tendencia de Receita' AS card,
    day,
    actual_revenue,
    predicted_revenue
FROM activation.revenue_trend
WHERE is_forecast
   OR day >= (SELECT max(day) - interval 29 day FROM activation.revenue_trend WHERE NOT is_forecast)
ORDER BY day;


-- ------------------------------------------------------------
-- Card 528: Tendencia de Volume de Pedidos (30d + previsao 90d)
-- ------------------------------------------------------------
SELECT
    'Tendencia de Volume de Pedidos' AS card,
    day,
    actual_order_count,
    predicted_order_count
FROM activation.order_volume_trend
WHERE is_forecast
   OR day >= (SELECT max(day) - interval 29 day FROM activation.order_volume_trend WHERE NOT is_forecast)
ORDER BY day;
