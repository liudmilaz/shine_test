-- Current state of each client: the _is_latest version of the SCD2 history
-- in dim_clients. This is a business rule (history -> one row per client),
-- so it lives here; removing duplicate copies is hygiene and now happens
-- upstream in stg_clients. With the copies gone there is exactly one
-- _is_latest row per client, so a filter is enough - the unique test on
-- sev_client_id fails loudly if that ever stops being true, instead of a
-- qualify silently picking one.
with

clients as (
    select * from {{ ref('dim_clients') }}
)

select *
from clients
where _is_latest
