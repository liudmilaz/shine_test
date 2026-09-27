-- One row per conversation. The original model joined conversations to
-- conversation_parts (one-to-many) and aggregated the fanned-out result,
-- which counted parts/messages, not conversations. Reducing parts to one
-- row per conversation first, here, keeps the join below 1:1.
with

conversations as (
    select * from {{ ref('stg_intercom_conversations') }}
),

-- The first agent reply per conversation: the part flagged
-- is_first_agent_reply. The parts table has no sender column, so this flag
-- is the only signal of who replied (an unfiltered min(created_at_utc) would
-- return the customer's first message instead). The source flags at most one
-- part per conversation, so no aggregation is needed; a unique test on
-- stg_intercom_conversation_parts enforces that, so a second flag fails the
-- build instead of silently doubling a conversation in the join below.
first_agent_reply as (

    select
        conversation_id,
        created_at_utc as first_agent_replied_at_utc
    from {{ ref('stg_intercom_conversation_parts') }}
    where is_first_agent_reply

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
        first_agent_reply.first_agent_replied_at_utc,

        -- Still open with no agent reply yet: its reply time isn't known,
        -- so it can't count as reached or not reached.
        coalesce(conversations.is_currently_open, false)
            and first_agent_reply.first_agent_replied_at_utc is null
            as is_awaiting_first_reply,

        datediff(
            'second', conversations.created_at_utc, first_agent_reply.first_agent_replied_at_utc
        ) as time_to_first_agent_reply_seconds,
        datediff(
            'second', conversations.created_at_utc, conversations.first_closed_at_utc
        ) as time_to_first_close_seconds,
        datediff(
            'second', conversations.created_at_utc, conversations.last_closed_at_utc
        ) as time_to_last_close_seconds

    -- Left join so conversations without an agent reply are kept, with an
    -- empty first_agent_replied_at_utc.
    from conversations
    left join first_agent_reply using (conversation_id)

)

select * from final
