select * from {{ source('intercom_raw', 'dim_clients') }}
