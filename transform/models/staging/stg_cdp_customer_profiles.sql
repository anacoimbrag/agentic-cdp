with parsed as (
    select
        identity_cdpid as customer_id,
        identity_userpseudoid as user_pseudo_id,
        identity_documentid as document_id,
        identity_documenttype as document_type,
        identity_firstname as first_name,
        identity_lastname as last_name,
        descriptive_gender as gender,
        {{ try_cast('descriptive_birthdate', 'date') }} as birth_date,
        descriptive_languagepreference as language_preference,
        descriptive_communicationpreferences_emailoptin as email_opt_in,
        descriptive_communicationpreferences_smsoptin as sms_opt_in,
        descriptive_communicationpreferences_pushoptin as push_opt_in,
        descriptive_communicationpreferences_whatsappoptin as whatsapp_opt_in,
        -- identity_emails/identity_phones chegam do loader como string JSON
        -- (array de objetos) -- desmembrados abaixo com JSONExtract*.
        JSONExtractArrayRaw(identity_emails) as emails,
        JSONExtractArrayRaw(identity_phones) as phones,
        row_number() over (partition by identity_cdpid order by identity_cdpid) as rn
    from {{ source('raw', 'cdp_customer_profiles') }}
),

-- raw é append-only e não tem chave primária configurada no loader, então
-- recargas do mesmo perfil geram linhas duplicadas; mantém uma por cliente.
deduped as (
    select * from parsed where rn = 1
),

emails_resolved as (
    select
        customer_id,
        if(
            arrayFirst(x -> JSONExtractBool(x, 'isPrimary'), emails) != '',
            arrayFirst(x -> JSONExtractBool(x, 'isPrimary'), emails),
            arrayElement(emails, 1)
        ) as resolved_email_json
    from deduped
)

select
    d.customer_id as customer_id,
    d.user_pseudo_id as user_pseudo_id,
    d.first_name as first_name,
    d.last_name as last_name,
    d.first_name || ' ' || d.last_name as full_name,
    d.document_id as document_id,
    d.document_type as document_type,
    d.gender as gender,
    d.birth_date as birth_date,
    dateDiff('year', d.birth_date, today()) as age,
    d.language_preference as language_preference,
    d.email_opt_in as email_opt_in,
    d.sms_opt_in as sms_opt_in,
    d.push_opt_in as push_opt_in,
    d.whatsapp_opt_in as whatsapp_opt_in,
    nullIf(JSONExtractString(er.resolved_email_json, 'address'), '') as primary_email,
    coalesce(JSONExtractBool(er.resolved_email_json, 'verified'), false) as email_verified,
    arrayExists(x -> JSONExtractBool(x, 'verified'), d.phones) as has_verified_phone
from deduped d
left join emails_resolved er on d.customer_id = er.customer_id
