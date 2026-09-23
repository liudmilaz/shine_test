with

-- chats
conversations as (
    select * from {{ ref(stg_intercom_conversations) }}
),

-- chat messages
conversation_parts as (
    select * from {{ ref(stg_intercom_conversation_parts) }}
),

-- clients
clients as (
    select * from {{ ref(dim_clients) }}
),

-- dates
dates as (
    select * from {{ ref(dim_dates) }}
),


combined as (

    select
        conversations.conversation_id,
        conversation_parts.conversation_part_id,

        conversations.sev_client_id,
        conversations.author_contact_id,
        conversations.agent_assignee_id,

        conversations.created_at_utc,

        conversations.is_currently_open,
        conversations.status_label,
        coalesce(conversations.rating, 0) as rating,

        conversations.was_conversation_outside_office_hours,

        conversation_parts.created_at_utc as part_created_at_utc,
        conversation_parts.updated_at_utc as part_updated_at_utc,
        conversation_parts.part_type,

        conversation_parts.is_first_agent_reply,
        case when conversation_parts.is_first_agent_reply then conversation_parts.created_at_utc end as first_agent_replied_at_utc,
        conversations.first_closed_at_utc,
        conversations.last_closed_at_utc,

        coalesce(date_trunc('minutes', conversations.created_at_utc, first_agent_replied_at_utc) / 60, 0) as time_to_first_agent_reply_seconds,
        coalesce(date_trunc('minutes', conversations.created_at_utc, conversations.first_closed_at_utc) / 60, 0) as time_to_first_close_seconds,
        coalesce(date_trunc('minutes', conversations.created_at_utc, conversations.last_closed_at_utc) / 60, 0) as time_to_last_close_seconds,

        -- Get first/last message per chat
        row_number() over (order by conversation_parts.created_at_utc) = 1 as is_first_conversation_part,
        row_number() over (order by conversation_parts.created_at_utc desc) = 1 as is_last_conversation_part

    from conversations
    join conversation_parts using (conversation_id)

),

conversations_daily as (

    select
        combined.created_at_utc :: date as date_day,

        count(*) as chat_count,
        count(case when combined.was_conversation_outside_office_hours then 1 else 0 end) as chats_outside_business_hours_count,
        combined.chats_outside_business_hours_count - combined.chat_count as chats_inside_business_hours_count,

        count(case when combined.time_to_first_agent_reply_seconds <= 60 then 1 else 0 end) as chat_first_response_60_sec_count,
        combined.chat_first_response_60_sec_count / coalesce(combined.chat_count, 0) as chat_reachability,
        avg(combined.time_to_last_close_seconds) as chat_avg_handling_time_seconds,
        avg(combined.rating) as chat_avg_rating

    from combined
    join clients using (sev_client_id)
    where clients.is_test_account != true

),

-- Fill up dates without any created chats
spined as (

    select
        date_day,

        coalesce(chat_count, 0) as chat_count,
        coalesce(chats_outside_business_hours_count, 0) as chats_outside_business_hours_count,
        coalesce(chats_inside_business_hours_count, 0) as chats_inside_business_hours_count,

        coalesce(chat_reachability, 0) as chat_reachability,
        coalesce(chat_avg_handling_time_seconds, 0) as chat_avg_handling_time_seconds,
        coalesce(chat_avg_rating, 0) as chat_avg_rating

    from dates
    join conversations_daily using (date_day)

),

final as (

    select
        date_day,

        chat_count,
        chats_outside_business_hours_count,
        chats_inside_business_hours_count,

        chat_reachability,
        chat_avg_handling_time_seconds,
        chat_avg_rating

    from spined

),

select * from final;
