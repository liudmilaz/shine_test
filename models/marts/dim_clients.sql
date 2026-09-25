-- Client dimension, SCD2 history as delivered by the source. Keeps the
-- name the reviewed fct model refs; current-row dedup lives downstream in
-- int_dim_clients_current.
select * from {{ ref('stg_clients') }}
