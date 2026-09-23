select * from {{ source('intercom_raw', 'stg_intercom_conversations') }}
