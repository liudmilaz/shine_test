select * from {{ source('intercom_raw', 'stg_intercom_conversation_parts') }}
