-- Passthrough for now: the simulated source is already clean. Renames,
-- casts and light cleanup for the clients source belong here, 1:1 with it.
select * from {{ source('intercom_raw', 'src_clients') }}
