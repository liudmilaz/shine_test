{#- Each layer gets the same schema name in every environment (STAGING,
    INTERMEDIATE, MARTS), instead of dbt's default <target_schema>_<custom>.
    The environment is told apart by the database the target writes to
    (SHINE_DEV vs SHINE_ANALYTICS_PROD), not by the schema name. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim | upper }}
    {%- endif -%}
{%- endmacro %}
