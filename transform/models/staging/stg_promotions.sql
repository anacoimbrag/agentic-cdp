select
    name as promotion_name,
    description,
    type as promotion_type,
    isactive as is_active,
    isarchived as is_archived,
    hasmaxpriceperitem as has_max_price_per_item,
    maxusage as max_usage,
    parseDateTimeBestEffort(lastmodifiedutc) as last_modified_at,
    utmsource as utm_source,
    utmicampaign as utm_campaign,
    conditionsids as condition_ids_json
from {{ source('raw', 'promotions') }}
