select * from {{ source('intercom_raw', 'src_intercom_conversation_parts') }}
