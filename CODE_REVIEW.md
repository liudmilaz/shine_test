# Code Review: fct_intercom_conversations_daily

Dialect reviewed: **Snowflake** (as given in the case).

Setup used to verify these findings: the case's CSV excerpts loaded into
`SHINE_RAW.INTERCOM` (never modified; dbt can only read it), zero-copy cloned
into `SHINE_DEV.SRC` (`dbt run-operation refresh_src`), and the remodeled
version of this model built and queried there with `dbt build` (the default
`dev` target, one schema per layer: `STAGING`, `INTERMEDIATE`, `MARTS`).
Every bug below either threw a real compile/runtime error against this data,
or was confirmed by comparing metric output to a manual count. See `models/`
for the corrected models and
`case_review_reference/fct_intercom_conversations_daily_ASIS.sql` for the
original.

The as-given SQL was also run directly in Snowflake, with its four `ref()`s
replaced by the untouched upstream tables in `SHINE_RAW.INTERCOM`. Snowflake
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
    0)`** — beyond the alias-reference syntax error (#3), the `coalesce`
    does nothing. `conversations_daily` groups rows that exist, so each
    day's `count(*)` is at least 1 and never `NULL`; a day with no
    conversations has no row here at all and only appears later, in the
    date spine. So the query can't divide by zero as written - but the
    `coalesce(..., 0)` shows the intent was the opposite of safe: had a 0
    ever reached the denominator, it would raise a division-by-zero error.
    The correct guard is `nullif(chat_count, 0)`, which returns `NULL`.

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

15. **Inverted subtraction for the inside-hours count** —
    `chats_outside_business_hours_count - chat_count as
    chats_inside_business_hours_count` subtracts the total from the part.
    Inside-hours chats are the total minus the outside-hours ones, so the
    operands are the wrong way round and the result is always zero or
    negative. Today #6 hides it (the outside-hours count equals the total,
    so the result is 0); once #6 is fixed, a day with 30 chats, 10 of them
    outside hours, shows `10 - 30 = -20`. Fix: `chat_count -
    chats_outside_business_hours_count`, or count inside-hours chats
    directly. A test asserting inside + outside = total catches it.

16. **Inner join to `clients` drops conversations without a client** —
    `join clients using (sev_client_id)` is an inner join, so a
    conversation whose `sev_client_id` is `NULL` or has no row in
    `dim_clients` disappears from every count without any warning. It has
    no effect on this sample (every conversation has a client), but
    nothing in the model would notice if one didn't. Fix: either left-join
    and decide explicitly how such conversations are reported, or keep the
    inner join and add a `relationships` test on `sev_client_id` so a
    missing client fails the build instead of shrinking the numbers (the
    remodel does the latter).

### Data quality of the flags behind the metrics

The upstream outputs are used as given: `SHINE_RAW` is never modified.
Cleansing happens in the staging layer this project owns, and only for
flags that feed a metric of `fct_intercom_conversations_daily`.

| Metric | Flag it depends on | Raw data quality | Action |
|---|---|---|---|
| outside / inside business hours counts | `was_conversation_outside_office_hours` | TRUE 10 / NULL 90, never FALSE | Recalculated in `stg_intercom_conversations` |
| `chat_count` and every metric (filter) | `is_test_account` | TRUE / NULL only | NULL -> false in `stg_clients` |
| `chat_count` (client join) | `_is_latest` | Correct, but 195 exact duplicate rows | Deduplicated in `stg_clients` |
| first response in 60 s, reachability | `is_first_agent_reply` | At most 1 per chat, never after the close; the 10 chats without one are out-of-hours auto-closes | None - can't be verified without an author column |
| average rating | `rating` | 1-5; NULL = unrated | None |
| average handling time | `created_at_utc`, `last_closed_at_utc` | Consistent order; no reopened chats | None |

**Office hours are recalculated, not coalesced.** A NULL flag could mean
"inside office hours" or "unknown". `stg_intercom_conversations` derives
the flag from `created_at_utc` and overwrites the source value, keeping it
as `was_conversation_outside_office_hours_source` for audit. Assumption:
`created_at_utc` is the base column, and office hours are 09:00-18:00 CEST,
Monday to Friday, for all markets (Copenhagen, Paris, Amsterdam, Berlin,
Gdansk). `stg_dates` holds the UTC -> CEST conversion
(`cest_utc_offset_hours`, `office_opens_at_utc`, `office_closes_at_utc`),
so it flows into `dim_dates`. A fixed CEST (UTC+2) reproduces the source
flag on all 100 chats; the daylight-saving-aware Europe/Berlin zone (UTC+1
in January) would disagree on 3. The warn-level test
`assert_office_hours_recalc_matches_source` reports any disagreement.

**With clean flags, the task's own formulas are correct.** The fixed model
therefore keeps the task's calculations and changes only the bugs:
inside = `chat_count - outside` (#15, operands swapped back), and
reachability = 60-second replies / `nullif(chat_count, 0)` (#11). Leaving
still-open chats out of reachability changes the metric's definition, so
it appears only in the subtask 2 models. On the sample, every daily metric
is identical before and after the cleansing.

## Subtask 2 — Modeling approach feedback

**Grain discipline.** Two of the bugs above come directly from grain: the
model does everything in one flat `combined` CTE at conversation-*part*
grain, so `chat_count` counts messages (#8), and the first-reply time
exists only on one message row and is coalesced to 0 on all the others
(#7). Splitting this into clear layers fixes those structurally:
- an intermediate model at **conversation grain** (one row per
  `conversation_id`) that takes `first_agent_replied_at_utc` from the one
  flagged part (`where is_first_agent_reply`) instead of a join that fans
  out, and computes elapsed times there
- the daily fact model aggregates *that*, so `count(*)` is guaranteed to
  mean "count of conversations", not "count of whatever the last join
  happened to multiply the grain by"

This is the classic staging → intermediate → mart shape. It does not by
itself prevent the other logic bugs - `count` vs `sum` (#6), the SCD2 join
(#9), `!= true` against `NULL` (#10) or the denominator (#11) are wrong at
any grain. What layering does is give each step one grain that can be
tested on its own, and those tests (unique keys, inside + outside =
total, relationships) are what catch the rest.

**Defensive dimension joins.** Never join a dimension "using" its
business key alone if the dimension is SCD-tracked, even one flagged with
`_is_latest`, without also asserting uniqueness (tested here: the sample
data had actual duplicate `_is_latest = true` rows per client). A
`unique` dbt test on `(sev_client_id)` in the intermediate "current
clients" model would catch this immediately in CI rather than silently
inflating a downstream count.

**NULL vs. zero is a modeling decision, not a formatting detail.** The
original model coalesces every rate and average to `0` in `spined`. As
written that is dead code: its inner join (#13) drops days with no chats
entirely, so no row ever has a `NULL` to replace. The problem appears as
soon as #13 is fixed with a left join and the coalesces are left in:
empty days would then show "0% reachability" and "a 0 average rating",
which are meaningless and actively misleading for a stakeholder skimming a
dashboard. So the two have to be fixed together: only the *count* columns
should default to 0 on empty days (there really were zero conversations);
rate and average columns should stay `NULL` (there is no rate to report).

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

**Two lineages: fix the deliverable, remodel next to it.** Subtask 1 says
"the evaluation of the modelling is not intended here", so the fixes above
keep `fct_intercom_conversations_daily` as it was delivered: the same
name, the same grain, the same consumers. Dropping or renaming it would be
a breaking change. The remodel is this subtask's answer, and it sits next
to the deliverable instead of replacing it:

- `fct_intercom_conversations` - one row per conversation, the fact of a
  star schema with `dim_clients` and `dim_dates`. Every metric is defined
  here, once, as an additive building block (0/1 flags, seconds, rating).
  Client attributes are not copied onto the fact: `client_version_key`
  points at the `dim_clients` version valid when the chat started. When
  no version was valid, the nearest one is used and
  `is_client_version_estimated` is set. The contract is enforced, because
  the BI tool depends on the column set.
- `agg_intercom_conversations_daily` - a rollup of that fact, one row per
  UTC day. It only sums the fact and stores the numerator and denominator
  next to each ratio, so a week or a month is `sum / sum`, never an
  average of daily ratios. `tests/assert_agg_daily_reconciles_to_fct.sql`
  fails if any day's totals differ from the fact. On the sample, both
  daily tables return identical numbers: 8 days, 0 differences.

Why not keep only the daily table? It works for regular reporting, and
it's one click to export. But a day-grain table with finished ratios
answers exactly one question. The predictable follow-up is weekly,
monthly, yearly, by plan - each one another pre-aggregated table with its
own copy of the metric logic. And daily ratios can't be rolled up into a
correct weekly ratio. The conversation-grain fact answers all of those
from one place.

**Times in UTC; the BI tool converts.** Both tables store UTC
(`created_at_utc`, `created_date_utc`). The BI tool (Omni) converts
timestamps from the connection's database timezone (UTC) to the viewer's
timezone at query time. A date that was already shifted to Berlin time
could not be converted again, and it would disagree with a UTC daily
table. In Omni, time is grouped on `created_at_utc`, and
`convert_tz: false` is set on the date columns. The one limit: a finished
daily aggregate can't be re-bucketed into another timezone, so
Berlin-day reporting has to come from the conversation fact.

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
