{{ config(order_by=['sku_id']) }}
select
    JSONExtractString(sku, 'itemId') as sku_id,
    JSONExtractString(sku, 'nameComplete') as sku_name,
    JSONExtractString(sku, 'ean') as ean,
    p.product_id as product_id,
    p.product_name as product_name,
    p.product_reference as product_reference,
    p.description as description,
    p.brand as brand,
    p.brand_id as brand_id,
    p.link as link,
    p.category_id as category_id,
    p.list_price_low as list_price_low,
    p.list_price_high as list_price_high,
    p.selling_price_low as selling_price_low,
    p.selling_price_high as selling_price_high,
    p.category_paths_json as category_paths_json,
    p.category_ids_json as category_ids_json,
    p.product_clusters_json as product_clusters_json,
    p.properties_json as properties_json
from {{ ref('stg_products') }} p
array join JSONExtractArrayRaw(p.bundle_items_json) as sku
