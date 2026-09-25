-- Remodeled fix of the as-given fct_intercom_conversations_daily
-- (see case_review_reference/fct_intercom_conversations_daily_ASIS.sql
-- for the original and CODE_REVIEW.md for the full bug list). Changes:
--   - reads from int_intercom_conversation_metrics (conversation grain)
--     instead of joining conversation_parts directly, fixing the fan-out
--     that made chat_count/averages count parts, not conversations
--   - datediff(...) instead of date_trunc(...) for elapsed time
--   - sum(case when ... then 1 else 0 end) instead of count(...), which
--     always counted every row regardless of the condition
--   - joins int_dim_clients_current (deduped to _is_latest) instead of
--     the raw SCD2 dim_clients, avoiding a historical-version fan-out
--   - coalesce(is_test_account, false) so NULL flags don't silently drop
--     real clients via `!= true`
--   - date spine is a left join (was inner join), so days with zero
--     chats survive; rate/average columns are left NULL on those days
--     instead of coalesced to 0, since 0% reachability or a 0 avg rating
--     would misrepresent "no data" as "bad data"
--   - rating is no longer coalesced to 0 before AVG(), which had been
--     dragging chat_avg_rating down for every unrated conversation
--   - date spine is bounded to the observed (non-test) conversation range
--     instead of enumerating the full multi-year dim_dates table
--   - left join to clients, so a conversation with no current client row
--     is kept rather than silently dropped (caught by a relationships test)
--   - chats still open with no agent reply are left out of reachability,
--     so recent days aren't understated and then revised upward later

with

conversations as (
    select * from {{ ref('int_intercom_conversation_metrics') }}
),

clients as (
    select * from {{ ref('int_dim_clients_current') }}
),

dates as (
    select * from {{ ref('dim_dates') }}
),

conversations_daily as (

    select
        conversations.date_day,

        count(*) as chat_count,
        sum(case when conversations.was_conversation_outside_office_hours then 1 else 0 end)
            as chats_outside_business_hours_count,
        sum(case when not coalesce(conversations.was_conversation_outside_office_hours, false) then 1 else 0 end)
            as chats_inside_business_hours_count,

        sum(case when conversations.time_to_first_agent_reply_seconds <= 60 then 1 else 0 end)
            as chat_first_response_60_sec_count,
        sum(case when conversations.time_to_first_agent_reply_seconds <= 60 then 1 else 0 end)
            / nullif(sum(case when not conversations.is_awaiting_first_reply then 1 else 0 end), 0)
            as chat_reachability,

        avg(conversations.time_to_last_close_seconds) as chat_avg_handling_time_seconds,
        avg(conversations.rating) as chat_avg_rating

    from conversations
    left join clients using (sev_client_id)
    where coalesce(clients.is_test_account, false) = false

    group by 1

),

spined as (

    select
        dates.date_day,

        coalesce(conversations_daily.chat_count, 0) as chat_count,
        coalesce(conversations_daily.chats_outside_business_hours_count, 0) as chats_outside_business_hours_count,
        coalesce(conversations_daily.chats_inside_business_hours_count, 0) as chats_inside_business_hours_count,
        coalesce(conversations_daily.chat_first_response_60_sec_count, 0) as chat_first_response_60_sec_count,

        conversations_daily.chat_reachability,
        conversations_daily.chat_avg_handling_time_seconds,
        conversations_daily.chat_avg_rating

    from dates
    left join conversations_daily using (date_day)
    where dates.date_day between (select min(date_day) from conversations_daily)
                             and (select max(date_day) from conversations_daily)

)

select * from spined
