-- Daily rollup of fct_intercom_conversations for regular reporting and
-- SQL self-service in Snowflake (subtask 2 proposal). Every metric is
-- defined once, in the conversation-grain fact; this model only sums it,
-- so the two can't drift apart (tests/assert_agg_daily_reconciles_to_fct.sql).
--
-- Grain: one row per UTC calendar day, from the first to the last day with
-- chats, including days without any (the date spine).
--
-- It stores the additive building blocks next to each ratio, so a week or
-- month is computed as sum(numerator) / sum(denominator) - never by
-- averaging the daily ratios. The ratios are a convenience for one-day reads.
with

conversations as (
    select * from {{ ref('fct_intercom_conversations') }}
),

dates as (
    select * from {{ ref('dim_dates') }}
),

conversations_daily as (

    select
        created_date_utc as date_day,

        count(*) as chat_count,
        count_if(is_outside_office_hours) as chats_outside_business_hours_count,
        count_if(not is_outside_office_hours) as chats_inside_business_hours_count,

        sum(is_reply_eligible) as reply_eligible_count,
        sum(is_reached_within_60s) as reached_within_60s_count,

        count(handling_seconds) as handled_count,
        sum(handling_seconds) as handling_seconds_sum,

        sum(is_rated) as rated_count,
        sum(rating) as rating_sum

    from conversations
    group by all

),

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

        -- building blocks (sum these across days)
        coalesce(conversations_daily.reply_eligible_count, 0) as reply_eligible_count,
        coalesce(conversations_daily.reached_within_60s_count, 0) as reached_within_60s_count,
        coalesce(conversations_daily.handled_count, 0) as handled_count,
        coalesce(conversations_daily.handling_seconds_sum, 0) as handling_seconds_sum,
        coalesce(conversations_daily.rated_count, 0) as rated_count,
        coalesce(conversations_daily.rating_sum, 0) as rating_sum,

        -- one-day ratios; NULL on days with nothing to divide by, since 0%
        -- or a 0 rating would present "no data" as "bad data"
        conversations_daily.reached_within_60s_count
            / nullif(conversations_daily.reply_eligible_count, 0) as chat_reachability,
        conversations_daily.handling_seconds_sum
            / nullif(conversations_daily.handled_count, 0) as chat_avg_handling_time_seconds,
        conversations_daily.rating_sum
            / nullif(conversations_daily.rated_count, 0) as chat_avg_rating

    from dates
    inner join date_bounds
        on dates.date_day between date_bounds.start_date and date_bounds.end_date
    left join conversations_daily
        on conversations_daily.date_day = dates.date_day

)

select * from spined
