-- One row per calendar day, plus the UTC -> CEST conversion used to derive
-- office hours (stg_intercom_conversations.was_conversation_outside_office_hours).
--
-- Assumption: the company's markets (Copenhagen, Paris, Amsterdam, Berlin,
-- Gdansk) share Central European time, taken as CEST = UTC+2 all year by
-- default. Office hours are 09:00-18:00 CEST, Monday to Friday. A fixed
-- offset reproduces the source flag exactly (0 mismatches on 100 chats);
-- the daylight-saving-aware Europe/Berlin zone (UTC+1 in winter) would
-- disagree on 3. To switch, derive cest_utc_offset_hours from
-- convert_timezone('Europe/Berlin', ...) instead of the constant.
with

dates as (
    select
        *,
        2 as cest_utc_offset_hours
    from {{ source('intercom_raw', 'src_dates') }}
)

select
    *,
    dateadd('hour', 9 - cest_utc_offset_hours, date_day::timestamp_ntz) as office_opens_at_utc,
    dateadd('hour', 18 - cest_utc_offset_hours, date_day::timestamp_ntz) as office_closes_at_utc
from dates
