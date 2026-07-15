{{ config(order_by=['brand_id']) }}
select distinct
    brand_id,
    brand as brand_name
from {{ ref('stg_products') }}
