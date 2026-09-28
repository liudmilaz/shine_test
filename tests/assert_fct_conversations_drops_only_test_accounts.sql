-- A singular test: fails (returns rows) if fct_intercom_conversations is
-- missing a conversation for any reason other than its client currently
-- being a test account - e.g. a client with no _is_latest version, which the
-- inner joins in the fact would otherwise drop silently.
select conversations.conversation_id
from {{ ref('int_intercom_conversation_metrics') }} as conversations
left join {{ ref('fct_intercom_conversations') }} as fct
    on fct.conversation_id = conversations.conversation_id
left join {{ ref('stg_clients') }} as test_clients
    on test_clients.sev_client_id = conversations.sev_client_id
    and test_clients._is_latest
    and test_clients.is_test_account
where fct.conversation_id is null
  and test_clients.sev_client_id is null
