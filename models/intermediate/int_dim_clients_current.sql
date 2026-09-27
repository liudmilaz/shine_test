-- Current state of each client: the _is_latest version of the SCD2 history
-- in dim_clients. This is a business rule (history -> one row per client),
-- so it lives here; removing duplicate copies is hygiene and now happens
-- upstream in stg_clients. With the copies gone there is exactly one
-- _is_latest row per client, so a filter is enough - the unique test on
-- sev_client_id fails loudly if that ever stops being true, instead of a
-- qualify silently picking one.
--
-- Test accounts are excluded here, so every model built on this one reports
-- on real clients only. They stay in stg_clients and dim_clients, where the
-- full client history is kept (e.g. for testing the product itself).
-- If test accounts turn out not to be needed for any analytics, this filter
-- could move further left, into stg_clients, so no model ever sees them -
-- at the cost of losing them from dim_clients as well.
with

clients as (
    select * from {{ ref('dim_clients') }}
)

select *
from clients
where _is_latest
  and not is_test_account
