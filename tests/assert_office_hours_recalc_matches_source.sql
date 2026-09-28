-- Data-quality check (warn): fails (returns rows) where the recalculated
-- office-hours flag disagrees with the source flag, read as NULL = false.
-- 0 rows on the case data; rows here would mean the CEST 09:00-18:00
-- assumption in stg_dates doesn't match how the source defines office hours.
{{ config(severity='warn') }}

select
    conversation_id,
    created_at_utc,
    was_conversation_outside_office_hours as recalculated,
    was_conversation_outside_office_hours_source as source_value
from {{ ref('stg_intercom_conversations') }}
where was_conversation_outside_office_hours != coalesce(was_conversation_outside_office_hours_source, false)
