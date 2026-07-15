-- Achata a árvore de categorias (3 níveis: raiz -> grupo -> folha) em um
-- registro por nó, em qualquer nível. `children` chega do loader como
-- string JSON (array de objetos, aninhado) -- desmembrado com JSONExtract*.
with roots as (
    select
        id as root_id,
        name as root_name,
        JSONExtractArrayRaw(children) as mids
    from {{ source('raw', 'categories') }}
),

flattened as (
    select
        root_id as category_id,
        root_name as category_name,
        CAST(NULL AS Nullable(Int64)) as parent_category_id,
        1 as level
    from roots

    union all

    select
        CAST(JSONExtractInt(m, 'id') AS Int64) as category_id,
        JSONExtractString(m, 'name') as category_name,
        CAST(root_id AS Nullable(Int64)) as parent_category_id,
        2 as level
    from roots
    array join mids as m

    union all

    select
        CAST(JSONExtractInt(l, 'id') AS Int64) as category_id,
        JSONExtractString(l, 'name') as category_name,
        CAST(JSONExtractInt(m, 'id') AS Nullable(Int64)) as parent_category_id,
        3 as level
    from roots
    array join mids as m
    array join JSONExtractArrayRaw(JSONExtractRaw(m, 'children')) as l
)

select
    category_id,
    category_name,
    parent_category_id,
    level
from flattened
