{{ config(order_by=['category_id']) }}
select
    category_id,
    category_name,
    parent_category_id,
    level
from {{ ref('stg_categories') }}
