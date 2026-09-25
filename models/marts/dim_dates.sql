-- Date dimension. Keeps the name the reviewed fct model refs.
select * from {{ ref('stg_dates') }}
