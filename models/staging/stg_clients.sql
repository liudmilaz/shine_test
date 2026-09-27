-- Deduplicated here, at the first layer dbt controls (shift left): the
-- source sends each SCD2 version several times as exact copies, and every
-- consumer of dim_clients should get clean history - not only the path
-- through int_dim_clients_current, which used to do this.
--
-- Grain: one row per client version (sev_client_id, _valid_from_utc).
-- The copies are identical, so which one survives doesn't matter; the
-- order by only keeps the choice deterministic should two copies ever
-- differ (the open-ended version wins).
--
-- is_test_account: the source only sets the flag when it is true (it is
-- TRUE or NULL, never FALSE), so NULL means "not a test account" and is
-- made explicit here once, instead of being coalesced in every model.
select * replace (coalesce(is_test_account, false) as is_test_account)
from {{ source('intercom_raw', 'src_clients') }}
qualify row_number() over (
    partition by sev_client_id, _valid_from_utc
    order by _valid_to_utc desc nulls first
) = 1
