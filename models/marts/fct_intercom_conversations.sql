-- One row per conversation: the fact table of a star schema for the BI tool
-- (Omni). Client and calendar attributes live in their dimensions and are
-- joined in the BI tool:
--   client_version_key -> dim_clients.client_version_key  (client as it was then)
--   sev_client_id      -> dim_clients where _is_latest     (client as it is now)
--   created_date_utc   -> dim_dates.date_day
--
-- Times are UTC. Omni converts timestamps from the connection's database
-- timezone (UTC) to the viewer's timezone at query time, so time-based
-- grouping should use created_at_utc; created_date_utc is the join key to
-- dim_dates and must not be converted (convert_tz: false in Omni).
--
-- It stores only additive building blocks (0/1 flags, seconds, ratings);
-- rates and averages are computed in the BI tool from sums, so they stay
-- correct at any grain (day, week, month, plan, ...). No pre-computed
-- ratios here on purpose: averaging them again would give wrong results.
--
-- Real clients only: the inner join to the current client version keeps
-- test-account conversations out (dim_clients holds real clients only).
-- tests/assert_fct_conversations_drops_only_test_accounts.sql fails if any
-- other conversation goes missing.
with

conversations as (
    select * from {{ ref('int_intercom_conversation_metrics') }}
),

client_versions as (
    select * from {{ ref('dim_clients') }}
),

clients_current as (
    select * from client_versions
    where _is_latest
),

-- The client version valid when the conversation started. The SCD2 range
-- is half-open (>= from, < to), so exactly one version can match. When
-- none does - the conversation predates the recorded history, or falls in
-- a gap between versions - the nearest version is used and flagged as
-- estimated: the latest one that started before the conversation, else
-- the first one after it.
conversation_client_version as (

    select
        conversations.conversation_id,
        client_versions.client_version_key,
        not (
            conversations.created_at_utc >= client_versions._valid_from_utc
            and conversations.created_at_utc < coalesce(client_versions._valid_to_utc, '9999-12-31'::timestamp_ntz)
        ) as is_client_version_estimated

    from conversations
    inner join client_versions
        on client_versions.sev_client_id = conversations.sev_client_id

    qualify row_number() over (
        partition by conversations.conversation_id
        order by
            is_client_version_estimated,
            iff(client_versions._valid_from_utc <= conversations.created_at_utc, 0, 1),
            iff(client_versions._valid_from_utc <= conversations.created_at_utc, client_versions._valid_from_utc, null) desc nulls last,
            client_versions._valid_from_utc
    ) = 1

),

final as (

    select
        -- keys
        conversations.conversation_id,
        conversations.sev_client_id,
        conversation_client_version.client_version_key,
        conversations.author_contact_id,
        conversations.agent_assignee_id,

        -- time (UTC)
        conversations.created_at_utc,
        conversations.date_day as created_date_utc,

        -- conversation attributes (degenerate dimensions)
        conversations.status_label,
        conversations.is_currently_open,
        conversations.was_conversation_outside_office_hours as is_outside_office_hours,
        conversation_client_version.is_client_version_estimated,

        -- additive measures (sum / count them in the BI tool)
        iff(conversations.is_awaiting_first_reply, 0, 1) as is_reply_eligible,
        iff(conversations.time_to_first_agent_reply_seconds <= 60, 1, 0) as is_reached_within_60s,
        conversations.time_to_first_agent_reply_seconds as first_reply_seconds,
        conversations.time_to_first_close_seconds as first_close_seconds,
        conversations.time_to_last_close_seconds as handling_seconds,
        conversations.rating,
        iff(conversations.rating is not null, 1, 0) as is_rated

    from conversations
    inner join clients_current
        on clients_current.sev_client_id = conversations.sev_client_id
    inner join conversation_client_version
        on conversation_client_version.conversation_id = conversations.conversation_id

)

select * from final
