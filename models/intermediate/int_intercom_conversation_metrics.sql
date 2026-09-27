-- One row per conversation. The original model joined conversations to
-- conversation_parts (one-to-many) and aggregated the fanned-out result,
-- which counted parts/messages, not conversations. Reducing parts to one
-- row per conversation first, here, keeps the join below 1:1.
with

conversations as (
    select * from {{ ref('stg_intercom_conversations') }}
),

-- The first agent reply per conversation, as a window column. The window
-- only looks at flagged parts: an unfiltered min(created_at_utc) would
-- return the conversation's first message of any kind (typically the
-- customer's, ~1s after opening), not the agent's reply. The parts table
-- has no sender column, so is_first_agent_reply is the only signal of who
-- replied. qualify keeps one row per conversation, so the join below
-- can't multiply rows; conversations with no flagged part get NULL.
conversation_parts as (

    select
        conversation_id,
        min(case when is_first_agent_reply then created_at_utc end)
            over (partition by conversation_id) as first_agent_replied_at_utc
    from {{ ref('stg_intercom_conversation_parts') }}
    qualify row_number() over (partition by conversation_id order by created_at_utc) = 1

),

final as (

    select
        conversations.conversation_id,
        conversations.sev_client_id,
        conversations.author_contact_id,
        conversations.agent_assignee_id,

        conversations.created_at_utc,
        conversations.created_at_utc::date as date_day,

        conversations.is_currently_open,
        conversations.status_label,
        conversations.rating,
        conversations.was_conversation_outside_office_hours,

        conversations.first_closed_at_utc,
        conversations.last_closed_at_utc,
        conversation_parts.first_agent_replied_at_utc,

        -- Still open with no agent reply yet: its reply time isn't known,
        -- so it can't count as reached or not reached.
        coalesce(conversations.is_currently_open, false)
            and conversation_parts.first_agent_replied_at_utc is null
            as is_awaiting_first_reply,

        datediff(
            'second', conversations.created_at_utc, conversation_parts.first_agent_replied_at_utc
        ) as time_to_first_agent_reply_seconds,
        datediff(
            'second', conversations.created_at_utc, conversations.first_closed_at_utc
        ) as time_to_first_close_seconds,
        datediff(
            'second', conversations.created_at_utc, conversations.last_closed_at_utc
        ) as time_to_last_close_seconds

    -- One join is unavoidable: the conversation attributes and the reply time
    -- come from two different tables. It stays a left join so conversations
    -- without any parts are kept.
    from conversations
    left join conversation_parts using (conversation_id)

)

select * from final
