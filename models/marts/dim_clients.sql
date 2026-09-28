-- Client dimension: full SCD2 history (one row per client version), real
-- clients only. Keeps the name the reviewed fct model refs; picking the
-- current version lives downstream in int_dim_clients_current.
--
-- client_version_key identifies one version. It is a hash of the natural
-- key and the version start, so it stays the same on every rebuild and
-- fct_intercom_conversations can point at the version that was valid when
-- a conversation happened.
--
-- Test accounts are excluded here, so every mart and everything built on
-- this dimension reports on real clients only. They stay in stg_clients,
-- where they remain available (e.g. for testing the product itself).
-- If test accounts turn out not to be needed for any analytics, this filter
-- could move further left, into stg_clients, so no model ever sees them.
select
    {{ dbt_utils.generate_surrogate_key(['sev_client_id', '_valid_from_utc']) }} as client_version_key,
    *
from {{ ref('stg_clients') }}
where not is_test_account
