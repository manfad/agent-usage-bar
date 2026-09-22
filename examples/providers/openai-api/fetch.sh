#!/bin/sh
# TEMPLATE — read it before you trust it.
#
# Mode A provider: print the normalized JSON on stdout and exit 0. Anything on stderr is
# discarded, and a non-zero exit shows as "OpenAI API script failed" in the menu.
#
# This one turns organization spend into a credits row. What it needs from you:
#
#   OPENAI_ADMIN_KEY   an admin key with api.usage.read (a plain API key will 401)
#   OPENAI_MONTHLY_CAP optional; your own budget, e.g. 50. Without it the row shows spend
#                      with no bar, since the API does not publish your limit.
#
# TODO before relying on this:
#   1. Confirm the response shape against the current docs:
#      https://platform.openai.com/docs/api-reference/usage/costs
#      This script assumes { "data": [ { "results": [ { "amount": { "value": 0.06 } } ] } ] }
#      and sums every bucket's results. If that changed, fix the jq filter below.
#   2. Decide the window. This asks for costs since the first of the current UTC month and
#      reports the next month's first as the reset, which matches a calendar billing period.
#   3. Paging: costs responses can be paginated (has_more / next_page). One page of daily
#      buckets covers a month, so this ignores it. Fix that if you widen the window.

set -eu

fail() {
  # An "error" with no sessions is what the app shows as the agent's unavailable reason.
  printf '{ "sessions": [], "error": %s }\n' "$1"
  exit 0
}

[ -n "${OPENAI_ADMIN_KEY:-}" ] || fail '"Set OPENAI_ADMIN_KEY"'
command -v jq >/dev/null 2>&1 || fail '"jq is not installed"'

start_time=$(date -u -v1d -v0H -v0M -v0S +%s)
resets_at=$(date -u -v1d -v0H -v0M -v0S -v+1m +%Y-%m-%dT%H:%M:%SZ)

response=$(
  curl -sS --max-time 15 -G \
    -H "Authorization: Bearer ${OPENAI_ADMIN_KEY}" \
    --data-urlencode "start_time=${start_time}" \
    --data-urlencode "bucket_width=1d" \
    --data-urlencode "limit=31" \
    https://api.openai.com/v1/organization/costs
) || fail '"Couldn'"'"'t reach OpenAI"'

# An error body means the key or the scope is wrong, not that spend is zero.
message=$(printf '%s' "$response" | jq -r '.error.message // empty')
[ -z "$message" ] || fail "$(printf '%s' "$message" | jq -Rs .)"

used=$(printf '%s' "$response" | jq '[.data[]?.results[]?.amount.value // 0] | add // 0')

if [ -n "${OPENAI_MONTHLY_CAP:-}" ]; then
  cap=", \"cap\": ${OPENAI_MONTHLY_CAP}"
else
  cap=""
fi

cat <<JSON
{
  "sessions": [
    {
      "id": "credits",
      "name": "Spend this month",
      "kind": "credits",
      "used": ${used}${cap},
      "unit": "$",
      "resetsAt": "${resets_at}"
    }
  ]
}
JSON
