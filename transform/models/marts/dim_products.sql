{{ config(order_by=['sku_id']) }}
select
    JSONExtractString(sku, 'itemId') as sku_id,
    JSONExtractString(sku, 'nameComplete') as sku_name,
    nullIf(JSONExtractString(arrayElement(JSONExtractArrayRaw(sku, 'images'), 1), 'imageUrl'), '') as image_url,
    p.product_id as product_id,
    p.brand_id as brand_id,
    p.category_id as category_id,
    p.selling_price_low as selling_price
from {{ ref('stg_products') }} p
array join JSONExtractArrayRaw(p.bundle_items_json) as sku
