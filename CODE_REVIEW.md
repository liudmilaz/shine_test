# Code Review: fct_intercom_conversations_daily

Dialect reviewed: **Snowflake** (as given in the case).

Setup used to verify these findings: the case's CSV excerpts loaded into
`RAW.INTERCOM.*`, zero-copy cloned to `TEST_ENV.INTERCOM` (`CREATE SCHEMA
TEST_ENV.INTERCOM CLONE RAW.INTERCOM`), and the remodeled version of this
model built and queried against the clone via `dbt run --target test
--vars '{raw_database: TEST_ENV}'`. Every bug below either threw a real
compile/runtime error against this data, or was confirmed by comparing
metric output to a manual count. See `models/` for the corrected models
and `case_review_reference/fct_intercom_conversations_daily_ASIS.sql` for
the original.

## Subtask 1 — Syntactic, logical, and functional mistakes

### Syntax errors (won't compile)

1. **Unquoted `ref()` arguments** — `{{ ref(stg_intercom_conversations) }}`
   (×4, one per upstream model). `ref()` takes a string literal; without
   quotes, Jinja treats the name as an undefined variable. Confirmed:
   `dbt run` fails to parse the model at all with
   `The name argument to ref() must be a string, got ... Undefined`.
   Fix: `{{ ref('stg_intercom_conversations') }}`.

2. **`date_trunc('minutes', a, b)`** (×3) — `date_trunc()` takes exactly
   two arguments (`date_trunc(<part>, <expr>)`); it doesn't compute an
   elapsed interval between two timestamps. Snowflake raises "too many
   arguments for function DATE_TRUNC". The intent was clearly an elapsed
   duration, i.e. `datediff('second', a, b)`. The surrounding `/ 60` is
   also dimensionally wrong for that intent — dividing a minute value by
   60 gives hours, not seconds.

3. **Alias referenced before/within the same `select` it's defined in**
   — twice:
   - `first_agent_replied_at_utc` is defined by a `case when` in the same
     select list as the `date_trunc(...)` expression that immediately
     tries to use it.
   - In `conversations_daily`: `combined.chats_outside_business_hours_count
     - combined.chat_count` and `combined.chat_first_response_60_sec_count
     / coalesce(combined.chat_count, 0)` reference `chat_count`,
     `chats_outside_business_hours_count`, and
     `chat_first_response_60_sec_count` as if they were columns on
     `combined` — but they're aggregate aliases being computed in *this*
     query's own select list, and `combined` has no such columns at all.
     Snowflake doesn't support this kind of lateral alias reference by
     default; this raises `invalid identifier`.

4. **Trailing `;` and a `with ... select` combined into one statement**
   — `final as (...) select * from final;`. A dbt model file must compile
   to a single `select`; the stray semicolon is dead syntax at best and a
   parse hazard in some execution paths.

### Logical / functional mistakes (compiles fine elsewhere, produces wrong numbers)

5. **`count(case when <cond> then 1 else 0 end)`** (×2: outside-hours
   count, 60-second-reply count) — `COUNT()` counts non-NULL values. The
   `else 0` branch means *every* row produces a non-NULL value (0 or 1),
   so both counts always equal `count(*)`, regardless of the condition.
   Confirmed: with this pattern, `chats_outside_business_hours_count`
   would equal `chat_count` on every single day. Fix: drop the `else`
   (so non-matching rows are NULL and excluded) or use `sum(case when
   <cond> then 1 else 0 end)`.

6. **Wrong grain: `conversations join conversation_parts using
   (conversation_id)`** is one-to-many (one conversation, many message
   parts). Every conversation-level column (`rating`,
   `was_conversation_outside_office_hours`, etc.) gets duplicated once
   per part, so `count(*) as chat_count` in `conversations_daily` counts
   **message parts, not conversations**, and `avg(rating)` /
   `avg(time_to_last_close_seconds)` are averaged over duplicated rows,
   skewed by however many parts each conversation happens to have.
   Confirmed against real data: aggregating at the joined grain gave
   chat_count values well above the actual number of conversations per
   day (e.g. 42 vs. 30 actual conversations on one day). This needs a
   conversation-grain intermediate step before the daily aggregation.

7. **Unfiltered join to the SCD2 `dim_clients`** — `combined join clients
   using (sev_client_id)` with no filter to a current/point-in-time
   version. `dim_clients` carries full history (`_valid_from_utc`,
   `_valid_to_utc`, `_is_latest`); joining on `sev_client_id` alone fans
   out across every historical version. Confirmed against real data: even
   after correctly filtering to `_is_latest = true`, several clients still
   had more than one "latest" row (the sample data contains literal
   duplicate rows per SCD2 version), which continued to fan out
   `chat_count`. A safe join needs an explicit tiebreaker, e.g.
   `qualify row_number() over (partition by sev_client_id order by
   _valid_from_utc desc) = 1`, not a bare `using` join.

8. **`where clients.is_test_account != true`** — if `is_test_account` is
   `NULL` for any client, `NULL != true` evaluates to `NULL`, not `TRUE`,
   so that row is silently dropped from the `WHERE` clause — a client with
   an unset flag is excluded from the report entirely rather than treated
   as "not a test account". Fix: `where coalesce(clients.is_test_account,
   false) = false`.

9. **`combined.chat_first_response_60_sec_count / coalesce(combined.chat_count,
   0)`** — beyond the alias-reference syntax error (#3), dividing by
   `coalesce(chat_count, 0)` will raise a division-by-zero error on any
   day with zero conversations, rather than a safe `NULL`. Should be
   `nullif(chat_count, 0)` in the denominator.

10. **`coalesce(conversations.rating, 0) as rating`** applied *before*
    `avg(rating)` downstream — unrated conversations become a rating of
    `0` (the worst possible score) rather than being excluded. `AVG()`
    already ignores `NULL`s correctly on its own; coalescing beforehand
    silently drags `chat_avg_rating` down. Confirmed: leaving `rating`
    as `NULL` for unrated conversations and only coalescing the *count*
    metrics (never the rating itself) changes `chat_avg_rating` materially
    on days with any unrated chats.

11. **`from dates join conversations_daily using (date_day)`** — an
    `INNER JOIN`, despite the comment directly above it saying "Fill up
    dates without any created chats". An inner join does the opposite: it
    drops every date that has no matching row in `conversations_daily`,
    i.e. exactly the zero-chat days the comment says should be kept. The
    `coalesce(chat_count, 0)` immediately below becomes dead code, since
    an inner join guarantees `chat_count` is never `NULL`. Confirmed: with
    an inner join, day `2025-01-05` (a real day with zero chats in the
    sample) disappears from the output entirely instead of showing zeros.
    Fix: `left join conversations_daily using (date_day)`.

12. **Dead columns**: `is_first_conversation_part` and
    `is_last_conversation_part` are computed with `row_number() over
    (order by conversation_parts.created_at_utc)` — with **no
    `partition by conversation_id`** — so they number rows across the
    *entire* result set, not per conversation. Even if partitioned
    correctly, neither column is referenced anywhere downstream of
    `combined`; they're computed and then dropped.

## Subtask 2 — Modeling approach feedback

**Grain discipline.** The core issue behind several bugs above (#5, #6,
#9) is that the model does everything in one flat `combined` CTE at
conversation-*part* grain, then tries to compute conversation- and
day-level metrics on top of it in a single pass. Splitting this into
clear layers fixes it structurally, not just patches the symptoms:
- an intermediate model at **conversation grain** (one row per
  `conversation_id`) that resolves `first_agent_replied_at_utc` via an
  aggregate (`min(created_at_utc) where is_first_agent_reply`) rather
  than a join that fans out, and computes elapsed times there
- the daily fact model aggregates *that*, so `count(*)` is guaranteed to
  mean "count of conversations", not "count of whatever the last join
  happened to multiply the grain by"

This is the classic staging → intermediate → mart shape and would have
made bugs #5–#9 much harder to introduce in the first place.

**Defensive dimension joins.** Never join a dimension "using" its
business key alone if the dimension is SCD-tracked, even one flagged with
`_is_latest`, without also asserting uniqueness (tested here: the sample
data had actual duplicate `_is_latest = true` rows per client). A
`unique` dbt test on `(sev_client_id)` in the intermediate "current
clients" model would catch this immediately in CI rather than silently
inflating a downstream count.

**NULL vs. zero is a modeling decision, not a formatting detail.** The
original model coalesces every rate/average to `0` at the end, including
on days with zero chats. A day with *no conversations* isn't "0%
reachability" or "a 0 average rating" — those are meaningless / actively
misleading numbers for a stakeholder skimming a dashboard. Only the
*count* columns should default to 0 on empty days (there really were zero
conversations); rate and average columns should stay `NULL` (there is no
rate to report).

**Bound the date spine to something meaningful.** `dim_dates` spans 2020
through the multi-year present. Left-joining the entire spine into a
report meant to describe "in-app chat performance" produces thousands of
all-zero/all-null rows outside the period the business actually has data
for. Bound it to the observed range (or a rolling window appropriate to
the report's use case) rather than the full calendar.

**Naming vs. actual semantics.** `chat_count` should mean "number of
conversations" — worth a `not_null` + a documented grain in a
`schema.yml`, plus a test asserting `chats_inside_business_hours_count +
chats_outside_business_hours_count = chat_count`, which is exactly the
kind of regression the bugs above would have been caught by.

**Suggested improvements, if extending this further:**
- add `schema.yml` docs + tests (`unique`/`not_null` on `date_day`,
  relationships tests from the intermediate model back to
  `stg_intercom_conversations`)
- consider incremental materialization once volume grows beyond a
  CSV-sized sample — daily fact tables are a textbook incremental use
  case
- expose `chat_first_response_60_sec_count` itself in the final output,
  not just the derived rate, so the numerator is auditable without
  re-deriving it from the rate and the count
