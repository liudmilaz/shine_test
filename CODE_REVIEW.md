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

The as-given SQL was also run directly in Snowflake, with its four `ref()`s
replaced by the untouched upstream tables in `RAW.INTERCOM`. Snowflake
reports one compile error at a time, so each was fixed in a scratch copy to
reach the next. In the order Snowflake reported them: the trailing comma
after the last CTE (#5), `date_trunc` with three arguments (#2), the
`combined.`-prefixed aggregate aliases (#3), and the missing `group by`
(#4). With those four fixed the query compiles - and returns **no rows at
all**, because of #10.

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

3. **Aggregate aliases referenced as columns of `combined`** — in
   `conversations_daily`, `combined.chats_outside_business_hours_count -
   combined.chat_count` and `combined.chat_first_response_60_sec_count /
   coalesce(combined.chat_count, 0)` treat `chat_count`,
   `chats_outside_business_hours_count` and
   `chat_first_response_60_sec_count` as columns of the `combined` CTE.
   They aren't: they're aliases computed in this same select list.
   Confirmed: `invalid identifier 'COMBINED.CHATS_OUTSIDE_BUSINESS_HOURS_COUNT'`.
   The `combined.` prefix is the error, not the reuse itself — Snowflake
   does allow referring to an alias defined earlier in the same select
   (a lateral column alias), and dropping the prefix compiles. The same
   pattern on `first_agent_replied_at_utc` in `combined` compiles fine;
   its problem is logical, see #7. Relying on lateral aliases is still
   worth avoiding: it's Snowflake-specific and breaks on a port to most
   other warehouses.

4. **Missing `group by` in `conversations_daily`** — it mixes aggregates
   (`count`, `avg`) with a plain column (`combined.created_at_utc::date`)
   and has no `group by` at all. Confirmed: `[CREATED_AT_UTC] is not a
   valid group by expression`. Fix: `group by 1`.

5. **Trailing comma after the last CTE, and a trailing `;`** — `final as
   (...),` is followed directly by `select * from final;`. The comma tells
   Snowflake another CTE follows. Confirmed: this is the first error
   Snowflake reports, `syntax error line 120 at position 0 unexpected
   'select'`. The `;` is a separate problem: a dbt model must compile to a
   single statement, so the semicolon is at best dead syntax and at worst
   breaks the statement dbt wraps around the model.

### Logical / functional mistakes (compiles fine elsewhere, produces wrong numbers)

6. **`count(case when <cond> then 1 else 0 end)`** (×2: outside-hours
   count, 60-second-reply count) — `COUNT()` counts non-NULL values. The
   `else 0` branch means *every* row produces a non-NULL value (0 or 1),
   so both counts always equal `count(*)`, regardless of the condition.
   Confirmed: with this pattern, `chats_outside_business_hours_count`
   would equal `chat_count` on every single day. Fix: drop the `else`
   (so non-matching rows are NULL and excluded) or use `sum(case when
   <cond> then 1 else 0 end)`.

7. **`coalesce(time_to_first_agent_reply, 0)` turns "no reply on this row"
   into "replied in 0 seconds"** — `first_agent_replied_at_utc` is a
   `case when is_first_agent_reply ...` evaluated per message part, so it
   is `NULL` on every part except the first agent reply. The elapsed time
   is then `NULL` on those rows, and `coalesce(..., 0)` makes it 0 seconds
   — which passes `<= 60`. Confirmed against real data: of the 3,303
   joined rows, 3,213 count as "first reply within 60 seconds", and none
   of those 3,213 is a reply at all; the 90 actual first replies all took
   longer than 60 seconds (fastest: 82s). Even with #6 fixed,
   `chat_reachability` would come out near 97% instead of the true 0%.
   Fix: resolve the first reply per conversation (`min(created_at_utc)
   where is_first_agent_reply`) and leave a missing reply as `NULL`.

8. **Wrong grain: `conversations join conversation_parts using
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

9. **Unfiltered join to the SCD2 `dim_clients`** — `combined join clients
   using (sev_client_id)` with no filter to a current/point-in-time
   version. `dim_clients` carries full history (`_valid_from_utc`,
   `_valid_to_utc`, `_is_latest`); joining on `sev_client_id` alone fans
   out across every historical version. Confirmed against real data: even
   after correctly filtering to `_is_latest = true`, several clients still
   had more than one "latest" row (the sample data contains literal
   duplicate rows per SCD2 version), which continued to fan out
   `chat_count`. The duplicates are exact copies (2,026 rows, 1,831
   distinct), so the fix has two parts: remove the copies as early as
   possible (in the remodel: `qualify row_number() over (partition by
   sev_client_id, _valid_from_utc ...) = 1` in `stg_clients`), then join
   only the `_is_latest` version, guarded by a `unique` test on
   `sev_client_id` — not a bare `using` join.

10. **`where clients.is_test_account != true`** — `NULL != true`
    evaluates to `NULL`, not `TRUE`, so any client whose flag is unset is
    dropped rather than treated as "not a test account". In this data
    that is every real client: `is_test_account` is never `FALSE` — it is
    `TRUE` for the 4 test clients and `NULL` for all 83 others. Confirmed:
    with the syntax errors fixed, the as-given query returns **zero
    rows**. Fix: `where coalesce(clients.is_test_account, false) = false`.

11. **`combined.chat_first_response_60_sec_count / coalesce(combined.chat_count,
   0)`** — beyond the alias-reference syntax error (#3), dividing by
   `coalesce(chat_count, 0)` will raise a division-by-zero error on any
   day with zero conversations, rather than a safe `NULL`. Should be
   `nullif(chat_count, 0)` in the denominator.

12. **`coalesce(conversations.rating, 0) as rating`** applied *before*
    `avg(rating)` downstream — unrated conversations become a rating of
    `0` (the worst possible score) rather than being excluded. `AVG()`
    already ignores `NULL`s correctly on its own; coalescing beforehand
    silently drags `chat_avg_rating` down. Confirmed: leaving `rating`
    as `NULL` for unrated conversations and only coalescing the *count*
    metrics (never the rating itself) changes `chat_avg_rating` materially
    on days with any unrated chats.

13. **`from dates join conversations_daily using (date_day)`** — an
    `INNER JOIN`, despite the comment directly above it saying "Fill up
    dates without any created chats". An inner join does the opposite: it
    drops every date that has no matching row in `conversations_daily`,
    i.e. exactly the zero-chat days the comment says should be kept. The
    `coalesce(chat_count, 0)` immediately below becomes dead code, since
    an inner join guarantees `chat_count` is never `NULL`. Confirmed: with
    an inner join, day `2025-01-05` (a real day with zero chats in the
    sample) disappears from the output entirely instead of showing zeros.
    Fix: `left join conversations_daily using (date_day)`.

14. **Dead columns**: `is_first_conversation_part` and
    `is_last_conversation_part` are computed with `row_number() over
    (order by conversation_parts.created_at_utc)` — with **no
    `partition by conversation_id`** — so they number rows across the
    *entire* result set, not per conversation. Even if partitioned
    correctly, neither column is referenced anywhere downstream of
    `combined`; they're computed and then dropped.

## Subtask 2 — Modeling approach feedback

**Grain discipline.** The core issue behind several bugs above (#6, #7,
#8, #11) is that the model does everything in one flat `combined` CTE at
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
made bugs #6–#11 much harder to introduce in the first place.

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
