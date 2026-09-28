-- One row per conversation.
--
-- was_conversation_outside_office_hours is recalculated here and overwrites
-- the source value. The source only sets it when true (TRUE or NULL, never
-- FALSE), so NULL was ambiguous. The original value is kept as
-- was_conversation_outside_office_hours_source for audit.
--
-- Assumption: created_at_utc is the base column for the calculation, and
-- office hours are 09:00-18:00 CEST (UTC+2), Monday to Friday - see
-- stg_dates, which holds the UTC -> CEST conversion. The office window
-- (07:00-16:00 UTC) never crosses midnight, so the UTC date finds the
-- right day. Public holidays are not treated as closed: the markets have
-- no common holiday calendar.
with

conversations as (
    select * from {{ source('intercom_raw', 'src_intercom_conversations') }}
),

dates as (
    select * from {{ ref('stg_dates') }}
)

select
    conversations.* replace (
        not (
            dates.is_weekday
            and conversations.created_at_utc >= dates.office_opens_at_utc
            and conversations.created_at_utc < dates.office_closes_at_utc
        ) as was_conversation_outside_office_hours
    ),
    conversations.was_conversation_outside_office_hours as was_conversation_outside_office_hours_source
from conversations
left join dates
    on dates.date_day = conversations.created_at_utc::date
