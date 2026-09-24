-- dim_clients is SCD2 (_valid_from_utc / _valid_to_utc / _is_latest).
-- Joining the raw dimension straight into a fact model fans out one row
-- per historical version per client. This isolates "current state" so
-- downstream joins stay 1:1 (or 1:many only on the intended key).
--
-- _is_latest alone isn't safe to trust here: the sample data has exact
-- duplicate rows per SCD2 version (confirmed while testing against the
-- clone - see CODE_REVIEW.md), so several clients have more than one row
-- flagged _is_latest = true. QUALIFY enforces exactly one row per client
-- regardless of how many duplicates exist upstream.
with

clients as (
    select * from {{ ref('dim_clients') }}
)

select *
from clients
where _is_latest
qualify row_number() over (partition by sev_client_id order by _valid_from_utc desc) = 1
