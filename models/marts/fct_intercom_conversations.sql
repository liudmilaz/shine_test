-- One row per conversation: the self-service table for the BI tool.
-- It stores only additive building blocks (0/1 flags, seconds, ratings);
-- rates and averages are computed in the BI tool from sums, so they stay
-- correct at any grain (day, week, month, plan, ...). No pre-computed
-- ratios here on purpose: averaging them again would give wrong results.
with

conversations as (
    select * from {{ ref('int_intercom_conversation_metrics') }}
),

-- Full SCD2 client history, for the plan as it was when the chat happened.
client_versions as (
    select * from {{ ref('dim_clients') }}
),

-- Fallback for conversations older than the client's recorded history.
client_first_versions as (
    select *
    from client_versions
    qualify row_number() over (partition by sev_client_id order by _valid_from_utc) = 1
),

-- Current state, only for the test-account flag: the daily fact excludes
-- test accounts by their current flag, and this table must match it.
clients_current as (
    select * from {{ ref('int_dim_clients_current') }}
),

dates as (
    select * from {{ ref('dim_dates') }}
),

conversations_local as (
    select
        *,
        convert_timezone('UTC', 'Europe/Berlin', created_at_utc) as created_at_local
    from conversations
),

final as (

    select
        -- keys
        conversations_local.conversation_id,
        conversations_local.sev_client_id,
        conversations_local.author_contact_id,
        conversations_local.agent_assignee_id,

        -- dates: calendar days in Berlin time, where the clients are
        conversations_local.created_at_utc,
        conversations_local.created_at_local,
        conversations_local.created_at_local::date as created_date_local,
        dates.first_day_of_week  as created_week_start_local,
        dates.first_day_of_month as created_month_start_local,
        dates.is_weekday,
        dates.is_holiday_de,
        dates.is_holiday_at,

        -- conversation attributes
        conversations_local.status_label,
        conversations_local.is_currently_open,
        coalesce(conversations_local.was_conversation_outside_office_hours, false) as is_outside_office_hours,

        -- client attributes as of the conversation (point in time)
        coalesce(clients_current.is_test_account, false) as is_test_account,
        coalesce(pit.active_plan, first_version.active_plan) as client_active_plan,
        coalesce(pit.has_active_contract_current, first_version.has_active_contract_current) as client_has_active_contract,
        coalesce(pit.is_small_settlement, first_version.is_small_settlement) as client_is_small_settlement,
        pit.sev_client_id is null as is_client_version_estimated,

        -- additive measures (sum / count them in the BI tool)
        iff(conversations_local.is_awaiting_first_reply, 0, 1) as is_reply_eligible,
        iff(conversations_local.time_to_first_agent_reply_seconds <= 60, 1, 0) as is_reached_within_60s,
        conversations_local.time_to_first_agent_reply_seconds as first_reply_seconds,
        conversations_local.time_to_first_close_seconds as first_close_seconds,
        conversations_local.time_to_last_close_seconds as handling_seconds,
        conversations_local.rating,
        iff(conversations_local.rating is not null, 1, 0) as is_rated

    from conversations_local
    left join client_versions as pit
        on pit.sev_client_id = conversations_local.sev_client_id
        and conversations_local.created_at_utc >= pit._valid_from_utc
        and conversations_local.created_at_utc < coalesce(pit._valid_to_utc, '9999-12-31'::timestamp_ntz)
    left join client_first_versions as first_version
        on first_version.sev_client_id = conversations_local.sev_client_id
    left join clients_current
        on clients_current.sev_client_id = conversations_local.sev_client_id
    left join dates
        on dates.date_day = conversations_local.created_at_local::date

)

select * from final
