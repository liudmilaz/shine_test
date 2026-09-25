-- Passthrough for now; see stg_clients.sql.
select * from {{ source('intercom_raw', 'src_dates') }}
