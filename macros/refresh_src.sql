{#- Dev only: zero-copy clones of the SHINE_RAW.INTERCOM tables into
    <target database>.SRC, under the src_ names the sources use. Costs no
    storage until the data diverges. Re-running replaces the whole SRC schema,
    so nothing else may live in it. Prod reads SHINE_RAW.INTERCOM directly.

    Tables are cloned one by one rather than as one schema clone: a schema
    clone keeps each table's original owner, so the dbt role could not rename
    them; a table clone is owned by the role that creates it.

    Usage:  dbt run-operation refresh_src          (then dbt build) -#}
{% macro refresh_src() %}
    {% if target.name == 'prod' %}
        {{ exceptions.raise_compiler_error("refresh_src is dev-only: the prod target reads SHINE_RAW.INTERCOM directly.") }}
    {% endif %}

    {% set clones = {
        'SRC_INTERCOM_CONVERSATIONS':      'STG_INTERCOM_CONVERSATIONS',
        'SRC_INTERCOM_CONVERSATION_PARTS': 'STG_INTERCOM_CONVERSATION_PARTS',
        'SRC_CLIENTS':                     'DIM_CLIENTS',
        'SRC_DATES':                       'DIM_DATES',
    } %}
    {% set src = target.database ~ '.SRC' %}

    {% do run_query('create or replace schema ' ~ src) %}
    {% for src_name, raw_name in clones.items() %}
        {% do run_query('create table ' ~ src ~ '.' ~ src_name ~ ' clone SHINE_RAW.INTERCOM.' ~ raw_name) %}
    {% endfor %}

    {{ log('Cloned ' ~ (clones | length) ~ ' tables from SHINE_RAW.INTERCOM into ' ~ src ~ ' as SRC_*', info=True) }}
{% endmacro %}
