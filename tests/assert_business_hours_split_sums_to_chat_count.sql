-- A singular test: fails (returns rows) if the inside/outside business
-- hours split doesn't add back up to the total chat count for that day.
select
    date_day,
    chat_count,
    chats_inside_business_hours_count,
    chats_outside_business_hours_count
from {{ ref('fct_intercom_conversations_daily') }}
where chats_inside_business_hours_count + chats_outside_business_hours_count != chat_count
