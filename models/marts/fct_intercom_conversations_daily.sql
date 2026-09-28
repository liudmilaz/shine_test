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
--   - test accounts are excluded without the `!= true` trap (which dropped
--     every client with a NULL flag): stg_clients turns NULL into false,
--     and dim_clients (so int_dim_clients_current) holds real clients only
--   - date spine is a left join (was inner join), so days with zero
--     chats survive; rate/average columns are left NULL on those days
--     instead of coalesced to 0, since 0% reachability or a 0 avg rating
--     would misrepresent "no data" as "bad data"
--   - rating is no longer coalesced to 0 before AVG(), which had been
--     dragging chat_avg_rating down for every unrated conversation
--   - date spine is bounded to the observed (non-test) conversation range
--     instead of enumerating the full multi-year dim_dates table
--   - a conversation with no client at all can't be dropped silently: the
--     relationships test on int_intercom_conversation_metrics fails first
--   - the metric formulas are otherwise the task's own: inside = chat_count
--     - outside (operands in the right order), reachability = 60-second
--     replies / chat_count. They are correct as written because the flags
--     are cleansed in staging (was_conversation_outside_office_hours
--     recalculated, is_test_account NULL -> false). Leaving still-open
--     chats out of reachability is a definition change, so it lives in the
--     subtask 2 models (fct_intercom_conversations, agg_*), not here.

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

        -- Same calculations as the task, with only the bugs fixed. The
        -- office-hours flag is recalculated in staging and never NULL, so it
        -- needs no coalesce here.
        count(*) as chat_count,
        sum(case when conversations.was_conversation_outside_office_hours then 1 else 0 end)
            as chats_outside_business_hours_count,
        count(*) - sum(case when conversations.was_conversation_outside_office_hours then 1 else 0 end)
            as chats_inside_business_hours_count,

        sum(case when conversations.time_to_first_agent_reply_seconds <= 60 then 1 else 0 end)
            as chat_first_response_60_sec_count,
        sum(case when conversations.time_to_first_agent_reply_seconds <= 60 then 1 else 0 end)
            / nullif(count(*), 0)
            as chat_reachability,

        avg(conversations.time_to_last_close_seconds) as chat_avg_handling_time_seconds,
        avg(conversations.rating) as chat_avg_rating

    from conversations
    -- Inner join on purpose: clients are real clients only (dim_clients),
    -- so this join is what excludes test-account conversations. (A left
    -- join would keep them - they'd just have no client match.) It would
    -- also drop a conversation whose client is missing altogether, but that
    -- can't happen silently: the relationships test on
    -- int_intercom_conversation_metrics.sev_client_id fails the build first.
    inner join clients using (sev_client_id)

    group by 1

),

-- First and last day with (non-test) chats: the spine's range.
date_bounds as (

    select
        min(date_day) as start_date,
        max(date_day) as end_date
    from conversations_daily

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
    inner join date_bounds
        on dates.date_day between date_bounds.start_date and date_bounds.end_date
    left join conversations_daily
        on conversations_daily.date_day = dates.date_day

)

select * from spined
