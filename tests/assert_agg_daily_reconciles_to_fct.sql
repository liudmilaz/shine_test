-- A singular test: fails (returns rows) if any day's totals in
-- agg_intercom_conversations_daily differ from the conversation-grain fact
-- it is built from.
with

fct as (
    select
        created_date_utc as date_day,
        count(*) as chat_count,
        sum(is_reached_within_60s) as reached_within_60s_count,
        sum(is_rated) as rated_count
    from {{ ref('fct_intercom_conversations') }}
    group by all
)

select
    coalesce(agg.date_day, fct.date_day) as date_day,
    agg.chat_count as agg_chat_count,
    fct.chat_count as fct_chat_count
from {{ ref('agg_intercom_conversations_daily') }} as agg
full outer join fct
    on fct.date_day = agg.date_day
where coalesce(agg.chat_count, 0) != coalesce(fct.chat_count, 0)
   or coalesce(agg.reached_within_60s_count, 0) != coalesce(fct.reached_within_60s_count, 0)
   or coalesce(agg.rated_count, 0) != coalesce(fct.rated_count, 0)
