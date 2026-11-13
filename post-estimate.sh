#!/usr/bin/env bash
# Posts a Terraform pull request's cost estimate to Costfluent, and records when it was applied.
#
#   COSTFLUENT_MODE=estimate  converts Infracost's JSON with infracost-to-estimate.jq and posts it to
#                             POST /v1/cost-estimates, which creates the pull request's estimate or
#                             replaces it while it is not applied yet.
#   COSTFLUENT_MODE=apply     posts the ids Terraform's state gives the resources the plan created
#                             or replaced, collected by terraform-apply.jq, to
#                             POST /v1/cost-estimates/apply, which records the estimate of the same
#                             workspace, repository and pull request as applied.
#
# Environment:
#   COSTFLUENT_API_TOKEN             API token with the capability to submit cost estimates (required)
#   COSTFLUENT_WORKSPACE_ID          workspace the estimate belongs to (required)
#   COSTFLUENT_REPOSITORY            repository, such as acme/infra (required)
#   COSTFLUENT_PULL_REQUEST          pull request number (required)
#   COSTFLUENT_INFRACOST_JSON        Infracost's JSON (estimate)
#   COSTFLUENT_TERRAFORM_PLAN_JSON   `terraform show -json` of the saved plan (estimate: optional;
#                                    apply: the plan that was applied, required)
#   COSTFLUENT_TERRAFORM_STATE_JSON  `terraform show -json` of the state after apply (apply)
#   COSTFLUENT_COMMIT, COSTFLUENT_URL, COSTFLUENT_INFRACOST_VERSION   optional, posted as given
#   COSTFLUENT_BASE_URL              defaults to https://api.costfluent.com; https only
#   COSTFLUENT_COMMENT               true keeps one comment on the pull request with the planned
#                                    change, edited on each push (estimate; default false)
#   COSTFLUENT_GITHUB_TOKEN          GitHub token with pull-requests: write, sent only to
#                                    GITHUB_API_URL (estimate, with COSTFLUENT_COMMENT)
#   COSTFLUENT_FAIL_ABOVE            fail when the planned monthly change is above this amount
#                                    (estimate)
#   GITHUB_STEP_SUMMARY              when set, the comment's Markdown is appended to it (estimate)
#
# Exits 0 on success, 4 when the planned monthly change is above COSTFLUENT_FAIL_ABOVE, which is
# judged only after the summary and the comment are written, and 1 on any other failure.
#
# Each token reaches curl only on stdin, as a config line, and only in requests to its own host,
# so it is never on a command line, and nothing here prints it. Both posts are safe to repeat, both
# being keyed by workspace, repository and pull request and a repeated apply with the same body
# changing nothing, so a 429, a 5xx or no answer is retried three times, honouring Retry-After; any
# other failure stops at once.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max_attempts=4
# Retry-After is honoured up to this many seconds, so a server asking for hours cannot hold the
# job for them.
max_wait=120
# Comments are listed 100 a page, up to this many pages.
max_comment_pages=20
# The contract's pattern for a decimal amount.
decimal='^-?[0-9]+(\.[0-9]{1,8})?$'

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }
# Values in these messages come from the pull request (addresses) and the API (problem details), so
# each message is one line: in GitHub Actions a line that starts with :: is a workflow command.
one_line() { local text="${1//$'\r'/ }"; printf '%s' "${text//$'\n'/ }"; }
escape() { local text="${1//%/%25}"; text="${text//$'\r'/%0D}"; printf '%s' "${text//$'\n'/%0A}"; }
say() { printf '%s\n' "$(one_line "$1")"; }
warn() { if in_actions; then printf '::warning::%s\n' "$(escape "$1")"; else say "warning: $1"; fi >&2; }
die() { if in_actions; then printf '::error::%s\n' "$(escape "$1")"; else say "error: $1"; fi >&2; exit "${2:-1}"; }

token="${COSTFLUENT_API_TOKEN:-}"
[[ -n "$token" ]] || die "COSTFLUENT_API_TOKEN is required"
# Checked before the mask, because a line break would split the mask command and end the curl
# config line, where the rest would be read as curl options.
[[ ! "$token" =~ [[:cntrl:]] ]] || die "COSTFLUENT_API_TOKEN holds a control character"
if in_actions; then printf '::add-mask::%s\n' "$token"; fi

for tool in curl jq; do
  command -v "$tool" >/dev/null || die "$tool is required on PATH"
done

mode="${COSTFLUENT_MODE:-estimate}"
base_url="${COSTFLUENT_BASE_URL:-https://api.costfluent.com}"
base_url="${base_url%/}"
workspace="${COSTFLUENT_WORKSPACE_ID:-}"
repository="${COSTFLUENT_REPOSITORY:-}"
pull_request="${COSTFLUENT_PULL_REQUEST:-}"

[[ "$mode" == estimate || "$mode" == apply ]] || die "COSTFLUENT_MODE is estimate or apply, not $mode"
[[ "$base_url" =~ ^https://[^[:space:]]+$ ]] || die "COSTFLUENT_BASE_URL must be an https URL, so the token never travels in clear"
[[ -n "$workspace" ]] || die "COSTFLUENT_WORKSPACE_ID is required"
[[ -n "$repository" ]] || die "COSTFLUENT_REPOSITORY is required"
[[ "$pull_request" =~ ^[1-9][0-9]{0,9}$ ]] || die "COSTFLUENT_PULL_REQUEST must be a pull request number, not '$pull_request'"

comment="${COSTFLUENT_COMMENT:-false}"
fail_above="${COSTFLUENT_FAIL_ABOVE:-}"
[[ "$comment" == true || "$comment" == false ]] || die "COSTFLUENT_COMMENT is true or false, not $comment"
[[ -z "$fail_above" || "$fail_above" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || die "COSTFLUENT_FAIL_ABOVE must be a non-negative amount such as 500 or 99.50, not '$fail_above'"
[[ "$mode" == estimate ]] || comment=false
github_token=""
marker=""
if [[ "$comment" == true ]]; then
  github_token="${COSTFLUENT_GITHUB_TOKEN:-}"
  [[ -n "$github_token" ]] || die "COSTFLUENT_GITHUB_TOKEN is required to comment"
  [[ ! "$github_token" =~ [[:cntrl:]] ]] || die "COSTFLUENT_GITHUB_TOKEN holds a control character"
  if in_actions; then printf '::add-mask::%s\n' "$github_token"; fi
  github_url="${GITHUB_API_URL:-}"
  github_url="${github_url%/}"
  [[ "$github_url" =~ ^https://[^[:space:]]+$ ]] \
    || die "GITHUB_API_URL must be GitHub's https API URL to comment, as GitHub Actions sets it"
  # Both go into the comment's address and its hidden marker, which a quote or a > would break out of.
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "COSTFLUENT_REPOSITORY must be owner/name to comment, not $repository"
  [[ "$workspace" =~ ^[A-Za-z0-9_-]+$ ]] || die "COSTFLUENT_WORKSPACE_ID must be a workspace id such as wsp_... to comment"
  marker="<!-- costfluent-cost-estimate workspace=$workspace -->"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# auth_config <token>: the curl config line that sends the token as a bearer, quoted for curl.
auth_config() { local value="${1//\\/\\\\}"; printf 'header = "Authorization: Bearer %s"' "${value//\"/\\\"}"; }
costfluent_config="$(auth_config "$token")"
github_config="$(auth_config "$github_token")"$'\n''header = "X-GitHub-Api-Version: 2022-11-28"'
unset token github_token

# json_file <variable> <path>: refuses a missing file or one that is not a JSON object.
json_file() {
  [[ -n "$2" ]] || die "$1 is required in $mode mode"
  [[ -f "$2" ]] || die "$1 ($2) is not a file"
  jq -e 'type == "object"' "$2" >/dev/null 2>&1 || die "$1 ($2) is not JSON"
}

# The problem document's title, detail and field errors, or the body itself, on one line.
problem() {
  jq -r '[.title, .detail, .message,
          (.errors // {} | to_entries[]? | "\(.key): \(.value | if type == "array" then join(" ") else tostring end)")]
         | map(select(type == "string" and . != "")) | join(": ")' "$1" 2>/dev/null \
    || head -c 2000 "$1"
}

# request <method> <url> [body] [status]: sends the curl config in $auth and leaves the answer in
# $tmp/response and its status in $http_status, or stops with the reason; a failure status given
# as the fourth argument is returned to the caller instead. Call it through costfluent_request or
# github_request, so each token goes only to its own host.
request() {
  local method="$1" url="$2" body="${3:-}" accepted="${4:-}" attempt=1 code wait retry_after tries
  local args=(--silent --show-error --fail-with-body --max-time 60 --proto "=https" --config -
    --request "$method" --header "Accept: application/json"
    --output "$tmp/response" --dump-header "$tmp/headers" --write-out '%{http_code}')
  [[ -z "$body" ]] || args+=(--header "Content-Type: application/json" --data-binary "@$body")
  while :; do
    : >"$tmp/response"
    : >"$tmp/headers"
    code=0
    http_status="$(printf '%s\n' "$auth" | curl "${args[@]}" "$url" 2>"$tmp/curl-error")" || code=$?
    case "$http_status" in
      2??) return 0 ;;
      429 | 5??) ;;
      000)
        # Only a request that may not have arrived is retried: no address, no connection, a
        # timeout or a dropped answer. Any other curl failure is a local problem a retry repeats.
        case "$code" in
          5 | 6 | 7 | 28 | 35 | 52 | 55 | 56) ;;
          *) die "$method $url failed: $(head -c 500 "$tmp/curl-error")" ;;
        esac
        ;;
      *)
        [[ -z "$accepted" || "$http_status" != "$accepted" ]] || return 0
        die "$method $url answered $http_status: $(problem "$tmp/response")"
        ;;
    esac
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      tries=""
      [[ "$max_attempts" -eq 1 ]] || tries=" after $max_attempts attempts"
      if [[ "$http_status" == 000 ]]; then
        die "$method $url failed$tries: $(head -c 500 "$tmp/curl-error")"
      fi
      die "$method $url answered $http_status$tries: $(problem "$tmp/response")"
    fi
    retry_after="$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9]\{1,9\}\)[[:space:]]*$/\1/p' "$tmp/headers" | tr -d '\r' | tail -1)"
    if [[ -n "$retry_after" ]]; then
      wait=$((10#$retry_after > max_wait ? max_wait : 10#$retry_after))
    else
      wait=$((2 ** attempt))
    fi
    say "$method $url answered ${http_status}; retrying in ${wait}s (attempt $((attempt + 1)) of $max_attempts)"
    sleep "$wait"
    attempt=$((attempt + 1))
  done
}

costfluent_request() { local auth="$costfluent_config"; request "$@"; }
github_request() {
  local auth="$github_config"
  request "$1" "$2" "${3:-}" 403
  [[ "$http_status" != 403 ]] \
    || die "$1 $2 answered 403 ($(problem "$tmp/response")): commenting needs the job's token to hold the pull-requests: write permission, which a pull request from a fork or from Dependabot never gets"
}

# write_output <name> <value>: a step output, when there is a step to give it to.
write_output() {
  [[ -n "${GITHUB_OUTPUT:-}" && -n "$2" && "$2" != *[[:cntrl:]]* ]] || return 0
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# render <posted|unchanged> <currency> <estimate id>: the comment's Markdown, from the planned
# totals in $tmp/planned.json (null when the receipt held none).
render() {
  jq -n -r --arg marker "$marker" --arg state "$1" --slurpfile planned "$tmp/planned.json" \
    --arg currency "$2" --arg id "$3" --arg commit "${COSTFLUENT_COMMIT:-}" --arg workspace "$workspace" '
    # A value from the pull request, the cloud or the API goes into a code span, where no Markdown,
    # link, HTML or @-mention works. The fence is a backtick longer than any run in the value, with
    # a space inside it when the value starts or ends with a backtick or a space, which CommonMark
    # strips, and a long value is cut first, so a cut never leaves a span open.
    def code: gsub("[[:cntrl:]]"; " ") | (if length > 256 then .[:253] + "..." else . end)
      | ("`" * ([scan("`+") | length] + [0] | max + 1)) as $fence
      | (if test("^[` ]|[` ]$") then " " else "" end) as $pad
      | "\($fence)\($pad)\(.)\($pad)\($fence)";
    def money: "\(.) \($currency)" | code;
    def signed: if startswith("-") or test("^[0.]+$") then . else "+" + . end;
    $planned[0] as $planned
    | [if $marker != "" then $marker else empty end, "### Costfluent cost estimate", ""]
      + if $state == "unchanged" then
          ["This push changes no priced resource, so nothing was posted to Costfluent, which keeps the estimate posted before."]
        elif $planned == null then
          ["The planned totals are unavailable: Costfluent answered without them."]
        else
          ["| Planned monthly cost | |", "|---|---|",
           "| Before | \($planned.monthlyCostBefore | money) |",
           "| After | \($planned.monthlyCostAfter | money) |",
           "| Change | \($planned.monthlyChange | signed | money) |",
           "| Resources without a price | \($planned.unpricedResources | tostring | code) |"]
        end
      + ["", ([if $id != "" then "estimate \($id | code)" else empty end,
               if $commit != "" then "commit \($commit | code)" else empty end,
               "workspace \($workspace | code)"]
              | join(", ") | (.[:1] | ascii_upcase) + .[1:] + ".")]
    | join("\n")'
}

# report <posted|unchanged> <currency> <estimate id>: appends the comment's Markdown to the job
# summary and, with COSTFLUENT_COMMENT, edits the pull request's comment or creates it. A push with
# no priced change only edits one, so a pull request that never had a cost gets no comment.
report() {
  local comment_id=""
  render "$@" >"$tmp/comment.md"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || cat "$tmp/comment.md" >>"$GITHUB_STEP_SUMMARY"
  [[ "$comment" == true ]] || return 0
  [[ "$(jq -Rs length "$tmp/comment.md")" -lt 65536 ]] || die "the comment is longer than the 65,536 characters GitHub takes"
  jq -n --rawfile body "$tmp/comment.md" '{body: $body}' >"$tmp/comment.json"
  find_comment
  if [[ -n "$comment_id" ]]; then
    github_request PATCH "$github_url/repos/$repository/issues/comments/$comment_id" "$tmp/comment.json"
    say "Updated the cost estimate comment on $repository#$pull_request."
  elif [[ "$1" == posted ]]; then
    # A create that failed may still have landed, so it is sent once: a second comment would never
    # be edited again.
    local max_attempts=1
    github_request POST "$github_url/repos/$repository/issues/$pull_request/comments" "$tmp/comment.json"
    say "Commented the cost estimate on $repository#$pull_request."
  fi
}

# find_comment: sets comment_id to the first comment on the pull request that a bot wrote and that
# starts with the marker. A person's comment quoting the marker is never taken, so never edited.
find_comment() {
  local page=1 url
  while [[ "$page" -le "$max_comment_pages" ]]; do
    url="$github_url/repos/$repository/issues/$pull_request/comments?per_page=100&page=$page"
    github_request GET "$url"
    jq -e 'type == "array"' "$tmp/response" >/dev/null 2>&1 || die "GET $url answered no list of comments"
    comment_id="$(jq -r --arg marker "$marker" 'first(.[] | select(.user.type? == "Bot"
        and (.body? | type == "string" and startswith($marker + "\n"))) | .id | numbers) // empty' "$tmp/response")"
    [[ -z "$comment_id" ]] || { [[ "$comment_id" =~ ^[0-9]+$ ]] || die "GitHub gave the comment the id $comment_id"; return 0; }
    [[ "$(jq length "$tmp/response")" -eq 100 ]] || return 0
    page=$((page + 1))
  done
  warn "the estimate's comment is not among the pull request's first $((max_comment_pages * 100)) comments"
}

# above <change> <limit>: whether the decimal change is greater than the non-negative decimal limit,
# compared as digits: a double rounds amounts with more than 15 or so significant digits, and the
# API's carry up to 8 decimal places beside any number of whole ones.
above() {
  local change="$1" limit="$2" whole limit_whole fraction limit_fraction i
  [[ "$change" != -* ]] || return 1
  whole="${change%%.*}"
  limit_whole="${limit%%.*}"
  fraction="${change#"$whole"}"
  limit_fraction="${limit#"$limit_whole"}"
  fraction="${fraction#.}"
  limit_fraction="${limit_fraction#.}"
  whole="${whole#"${whole%%[!0]*}"}"
  limit_whole="${limit_whole#"${limit_whole%%[!0]*}"}"
  [[ "${#whole}" -eq "${#limit_whole}" ]] || { [[ "${#whole}" -gt "${#limit_whole}" ]]; return; }
  while [[ "${#fraction}" -lt "${#limit_fraction}" ]]; do fraction+="0"; done
  while [[ "${#limit_fraction}" -lt "${#fraction}" ]]; do limit_fraction+="0"; done
  change="$whole$fraction"
  limit="$limit_whole$limit_fraction"
  for ((i = 0; i < ${#change}; i++)); do
    [[ "${change:i:1}" == "${limit:i:1}" ]] || { [[ "${change:i:1}" > "${limit:i:1}" ]]; return; }
  done
  return 1
}

estimate() {
  local infracost="${COSTFLUENT_INFRACOST_JSON:-}" plan="${COSTFLUENT_TERRAFORM_PLAN_JSON:-}" plan_args=() count id
  local currency change
  json_file COSTFLUENT_INFRACOST_JSON "$infracost"
  if [[ -n "$plan" ]]; then
    json_file COSTFLUENT_TERRAFORM_PLAN_JSON "$plan"
    plan_args=(--slurpfile terraformPlan "$plan")
  fi
  if ! jq -f "$here/infracost-to-estimate.jq" \
    --arg workspaceId "$workspace" --arg repository "$repository" --arg pullRequest "$pull_request" \
    --arg commit "${COSTFLUENT_COMMIT:-}" --arg url "${COSTFLUENT_URL:-}" \
    --arg sourceVersion "${COSTFLUENT_INFRACOST_VERSION:-}" \
    ${plan_args[@]+"${plan_args[@]}"} "$infracost" >"$tmp/estimate.json" 2>"$tmp/jq-error"; then
    die "$(sed 's/^jq: error (at [^)]*): //' "$tmp/jq-error")"
  fi
  count="$(jq '.resources | length' "$tmp/estimate.json")"
  currency="$(jq -r '.currency' "$tmp/estimate.json")"
  if [[ "$count" -eq 0 ]]; then
    say "No resource's cost changes in $infracost: nothing to post."
    echo null >"$tmp/planned.json"
    report unchanged "$currency" ""
    return 0
  fi
  costfluent_request POST "$base_url/v1/cost-estimates" "$tmp/estimate.json"
  id="$(jq -r '.id // empty | strings' "$tmp/response")"
  say "Posted the cost estimate ${id:-(no id)} for $repository#$pull_request: $count resources, $([[ "$http_status" == 201 ]] && echo created || echo updated)."
  write_output estimate-id "$id"

  # The server's own totals, so nothing here adds decimals; null from a server older than them, and
  # for totals that are not the contract's decimals, which are never shown or judged.
  jq --arg decimal "$decimal" '.planned | if type == "object"
      and all(.monthlyCostBefore, .monthlyCostAfter, .monthlyChange; type == "string" and test($decimal))
      and (.unpricedResources | type == "number" and . >= 0 and . == floor)
    then . else null end' "$tmp/response" >"$tmp/planned.json"
  change="$(jq -r '.monthlyChange // empty' "$tmp/planned.json")"
  write_output monthly-change "$change"
  report posted "$currency" "$id"

  [[ -n "$fail_above" ]] || return 0
  if [[ -z "$change" ]]; then
    # Failing here would fail every pull request until the API answers with totals, so the gate is
    # left open, loudly.
    warn "fail-above is not applied: Costfluent answered without the planned totals, so the change cannot be judged"
  elif above "$change" "$fail_above"; then
    die "the planned monthly change, $change $currency, is above fail-above, $fail_above $currency" 4
  else
    say "The planned monthly change, $change $currency, is not above fail-above, $fail_above $currency."
  fi
}

apply() {
  local plan="${COSTFLUENT_TERRAFORM_PLAN_JSON:-}" state="${COSTFLUENT_TERRAFORM_STATE_JSON:-}" count id missing
  json_file COSTFLUENT_TERRAFORM_PLAN_JSON "$plan"
  json_file COSTFLUENT_TERRAFORM_STATE_JSON "$state"
  jq -e 'has("resource_changes") or has("planned_values")' "$plan" >/dev/null \
    || die "COSTFLUENT_TERRAFORM_PLAN_JSON ($plan) is not \`terraform show -json\` of a saved plan"
  jq -e '(has("resource_changes") or has("planned_values") | not) and has("format_version")' "$state" >/dev/null \
    || die "COSTFLUENT_TERRAFORM_STATE_JSON ($state) is not \`terraform show -json\` of the state"

  # The plan's whole set of creates and replaces, not guessed down to the estimate's lines;
  # terraform-apply.jq says why. One the state holds no id for is named and left out.
  jq -n -f "$here/terraform-apply.jq" --slurpfile plan "$plan" --slurpfile state "$state" \
    --arg workspaceId "$workspace" --arg repository "$repository" --argjson pullRequest "$pull_request" \
    >"$tmp/apply.json"
  while IFS= read -r missing; do
    warn "$missing is created or replaced by the plan, but the state holds no id for it; it is left out"
  done < <(jq -r '.missing[]' "$tmp/apply.json")
  jq '.body' "$tmp/apply.json" >"$tmp/apply-body.json"
  count="$(jq '.resources | length' "$tmp/apply-body.json")"
  [[ "$count" -le 2000 ]] || die "the plan creates or replaces $count resources with ids, more than the 2,000 one apply takes"

  costfluent_request POST "$base_url/v1/cost-estimates/apply" "$tmp/apply-body.json" 404
  if [[ "$http_status" == 404 ]]; then
    # A pull request whose plan changed no priced resource posted no estimate, so this is no failure.
    # The API's reason is printed: a mistyped workspace answers 404 too, and would otherwise pass
    # unseen here, though the estimate post on the pull request already failed on it.
    say "No cost estimate for $repository#$pull_request in this workspace: nothing to apply ($(problem "$tmp/response"))."
    return 0
  fi
  id="$(jq -r '.id // empty | strings' "$tmp/response")"
  say "Recorded the apply of the cost estimate ${id:-(no id)} for $repository#$pull_request: $count created or replaced resources with ids."
  write_output estimate-id "$id"
}

"$mode"
