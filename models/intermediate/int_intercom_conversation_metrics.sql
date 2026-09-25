-- One row per conversation. The original model joined conversations to
-- conversation_parts (one-to-many) and aggregated the fanned-out result,
-- which counted parts/messages, not conversations. Aggregating parts down
-- to conversation grain first, here, keeps everything downstream 1:1.
with

conversations as (
    select * from {{ ref('stg_intercom_conversations') }}
),

conversation_parts as (
    select * from {{ ref('stg_intercom_conversation_parts') }}
),

first_agent_reply as (

    select
        conversation_id,
        min(created_at_utc) as first_agent_replied_at_utc
    from conversation_parts
    where is_first_agent_reply
    group by 1

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

    from conversations
    left join first_agent_reply using (conversation_id)

)

select * from final
