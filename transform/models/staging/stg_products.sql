select
    productid as product_id,
    productname as product_name,
    productreference as product_reference,
    description,
    brand,
    brandid as brand_id,
    link,
    {{ try_cast('categoryid', 'integer') }} as category_id,
    pricerange_listprice_lowprice as list_price_low,
    pricerange_listprice_highprice as list_price_high,
    pricerange_sellingprice_lowprice as selling_price_low,
    pricerange_sellingprice_highprice as selling_price_high,
    categories as category_paths_json,
    categoriesids as category_ids_json,
    productclusters as product_clusters_json,
    properties as properties_json,
    items as bundle_items_json  -- desmembrado em SKUs por dim_products
from {{ source('raw', 'products') }}
