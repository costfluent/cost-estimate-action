#!/usr/bin/env bash
# Tests infracost-to-estimate.jq, terraform-apply.jq and post-estimate.sh on Infracost's own output
# in tests/fixtures and a stub curl and sleep on PATH, which record what they were asked to do and
# answer from a queue. Nothing here reaches the network. Every body posted is held to its request
# schema in the Public API contract with openapi-shape.py, so a change on either side fails here.
# The contract is the OpenAPI document of the Costfluent Public API, passed as the one argument.
#
#   bash tests/post-estimate.test.sh <public.v1.json>
#   WRITE_EXPECTED=1 bash tests/post-estimate.test.sh <public.v1.json>   # rewrites tests/fixtures/expected/ first
set -euo pipefail

contract="${1:?usage: bash tests/post-estimate.test.sh <public.v1.json>, the Public API contract every posted body is held to}"
[[ -f "$contract" ]] || { echo "error: $contract is not the Public API contract file" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action="$(dirname "$here")"
fixtures="$here/fixtures"
filter="$action/infracost-to-estimate.jq"
apply_program="$action/terraform-apply.jq"
script="$action/post-estimate.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  [[ $# -lt 2 ]] || printf '     %s\n' "$2"
  failures=$((failures + 1))
}
# check <name> <command...>: passes when the command succeeds.
check() {
  local name="$1"
  shift
  if "$@" >/dev/null; then pass "$name"; else fail "$name"; fi
}
# same_json <name> <actual file> <expected JSON>: compares with sorted keys.
same_json() {
  local name="$1" actual="$2" expected="$3"
  if diff <(jq -S . "$actual") <(jq -S . <<<"$expected") >"$work/diff" 2>&1; then
    pass "$name"
  else
    fail "$name" "$(head -40 "$work/diff")"
  fi
}

stub_bin="$work/bin"
mkdir -p "$stub_bin"
# curl: records argv and stdin (the config) per call, copies the posted body, and answers from
# response-<n>.{status,headers,body} in STUB_DIR, or response-default.*, keeping the status and
# body it answered with as call-<n>.{status,answer}. A status of 000 stands for
# a request that got no answer, and curl exits with response-<n>.exit, or 28, a timeout.
cat >"$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
n=$(( $(cat "$STUB_DIR/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_DIR/count"
printf '%s\n' "$@" >"$STUB_DIR/call-$n.argv"
cat >"$STUB_DIR/call-$n.stdin"
out="" headers="" body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift ;;
    --dump-header) headers="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
  esac
  shift
done
[[ -z "$body" ]] || cp "$body" "$STUB_DIR/call-$n.body"
response="$STUB_DIR/response-$n"
[[ -f "$response.status" ]] || response="$STUB_DIR/response-default"
status="$(cat "$response.status")"
printf '%s' "$status" >"$STUB_DIR/call-$n.status"
[[ ! -f "$response.body" ]] || cp "$response.body" "$STUB_DIR/call-$n.answer"
if [[ "$status" == 000 ]]; then
  printf '000'
  exit "$(cat "$response.exit" 2>/dev/null || echo 28)"
fi
{ printf 'HTTP/2 %s\r\n' "$status"; [[ ! -f "$response.headers" ]] || cat "$response.headers"; printf '\r\n'; } >"$headers"
if [[ -f "$response.body" ]]; then cp "$response.body" "$out"; else : >"$out"; fi
printf '%s' "$status"
[[ "$status" -lt 400 ]] || exit 22
STUB
cat >"$stub_bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$STUB_DIR/sleeps"
STUB
chmod +x "$stub_bin/curl" "$stub_bin/sleep"

token="test-token-for-the-stub-only"
case_number=0

# new_case: a fresh stub directory and the environment of a pull request run.
new_case() {
  case_number=$((case_number + 1))
  export STUB_DIR="$work/case-$case_number"
  mkdir -p "$STUB_DIR"
  printf '201' >"$STUB_DIR/response-default.status"
  printf '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed"}' >"$STUB_DIR/response-default.body"
  # A CI runner sets the GITHUB_ variables, which would send the script's summary to the real job.
  unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_API_URL COSTFLUENT_TERRAFORM_PLAN_JSON \
    COSTFLUENT_TERRAFORM_STATE_JSON COSTFLUENT_BASE_URL COSTFLUENT_COMMENT COSTFLUENT_GITHUB_TOKEN COSTFLUENT_FAIL_ABOVE
  export COSTFLUENT_MODE=estimate
  export COSTFLUENT_API_TOKEN="$token"
  export COSTFLUENT_WORKSPACE_ID=wsp_8f3k2m4n5p6q7r8s9t0v1w
  export COSTFLUENT_REPOSITORY=acme/infra
  export COSTFLUENT_PULL_REQUEST=42
  export COSTFLUENT_COMMIT=9fceb02d0ae598e95dc970b74767f19372d61af8
  export COSTFLUENT_URL=https://github.com/acme/infra/pull/42
  export COSTFLUENT_INFRACOST_VERSION=0.10.41
  export COSTFLUENT_INFRACOST_JSON="$fixtures/infracost-v0.10-diff.json"
}
# respond <call> <status> [body] [headers] [curl exit]: queues one answer.
respond() {
  printf '%s' "$2" >"$STUB_DIR/response-$1.status"
  [[ -z "${3:-}" ]] || printf '%s' "$3" >"$STUB_DIR/response-$1.body"
  [[ -z "${4:-}" ]] || printf '%s\r\n' "$4" >"$STUB_DIR/response-$1.headers"
  [[ -z "${5:-}" ]] || printf '%s' "$5" >"$STUB_DIR/response-$1.exit"
}
calls() { cat "$STUB_DIR/count" 2>/dev/null || echo 0; }
# off_contract: the case answers with a receipt outside the contract on purpose, so the contract
# check below leaves its answers out.
off_contract() { : >"$STUB_DIR/off-contract"; }
# run_script: runs post-estimate.sh with the stubs first on PATH; its output lands in
# $STUB_DIR/output and its exit status in $status.
run_script() {
  status=0
  PATH="$stub_bin:$PATH" bash "$script" >"$STUB_DIR/output" 2>&1 || status=$?
}
convert() { jq -f "$filter" --arg workspaceId wsp_8f3k2m4n5p6q7r8s9t0v1w --arg repository acme/infra --arg pullRequest 42 "$@"; }

# --- conversion: both formats, one document -------------------------------------------------

# The same change, web_app resized and web_app2 removed, as Infracost v0.10 wrote it and as
# Infracost v2's diff writes it.
same_change='{
  "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
  "source": "infracost", "currency": "USD",
  "resources": [
    {"address": "aws_instance.web_app", "type": "aws_instance", "change": "update",
     "monthlyCostBefore": "742.64", "monthlyCostAfter": "1303.28", "resourceIds": []},
    {"address": "aws_instance.web_app2", "type": "aws_instance", "change": "delete",
     "monthlyCostBefore": "1303.28", "monthlyCostAfter": null, "resourceIds": []}
  ]
}'
if convert "$fixtures/infracost-v0.10-diff.json" >"$work/v010.json" 2>"$work/err"; then
  same_json "v0.10 0.2 diff converts to the estimate document" "$work/v010.json" "$same_change"
else
  fail "v0.10 0.2 diff converts to the estimate document" "$(cat "$work/err")"
fi
if convert "$fixtures/infracost-v2-diff.json" >"$work/v2.json" 2>"$work/err"; then
  same_json "v2 diff of the same change converts to the same document" "$work/v2.json" "$same_change"
else
  fail "v2 diff of the same change converts to the same document" "$(cat "$work/err")"
fi

# The amounts are in the currency the document's root names, so the estimate carries that one; a
# document that names none is USD, Infracost's default.
for format in v0.10:infracost-v0.10-diff v2:infracost-v2-diff; do
  name="${format%%:*}" document="$fixtures/${format#*:}.json"
  jq '.currency = "EUR"' "$document" >"$work/$name-eur.json"
  if convert "$work/$name-eur.json" >"$work/$name-eur-out.json" 2>"$work/err"; then
    same_json "a $name diff in EUR converts to the same change in EUR" "$work/$name-eur-out.json" \
      "$(jq '.currency = "EUR"' <<<"$same_change")"
  else
    fail "a $name diff in EUR converts to the same change in EUR" "$(cat "$work/err")"
  fi
  jq 'del(.currency)' "$document" >"$work/$name-no-currency.json"
  if convert "$work/$name-no-currency.json" >"$work/$name-no-currency-out.json" 2>"$work/err"; then
    same_json "a $name diff naming no currency converts in USD" "$work/$name-no-currency-out.json" "$same_change"
  else
    fail "a $name diff naming no currency converts in USD" "$(cat "$work/err")"
  fi
done

# v2: a resized instance, a removed database, a usage-priced bucket and a function whose whole
# cost depends on usage, which v2 writes as "0" beside cost_depends_on_usage: unknown, not free.
if convert "$fixtures/infracost-v2-diff-usage.json" >"$work/v2-usage.json" 2>"$work/err"; then
  same_json "v2 usage-dependent cost stays null, never zero" "$work/v2-usage.json" '{
    "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
    "source": "infracost", "currency": "USD",
    "resources": [
      {"address": "aws_db_instance.old", "type": "aws_db_instance", "change": "delete",
       "monthlyCostBefore": "120", "monthlyCostAfter": null, "resourceIds": []},
      {"address": "aws_instance.web_app", "type": "aws_instance", "change": "update",
       "monthlyCostBefore": "70", "monthlyCostAfter": "566", "resourceIds": []},
      {"address": "aws_lambda_function.hello", "type": "aws_lambda_function", "change": "create",
       "monthlyCostBefore": null, "monthlyCostAfter": null, "resourceIds": []},
      {"address": "aws_s3_bucket.data", "type": "aws_s3_bucket", "change": "update",
       "monthlyCostBefore": "23", "monthlyCostAfter": "46", "resourceIds": []}
    ]
  }'
else
  fail "v2 usage-dependent cost stays null, never zero" "$(cat "$work/err")"
fi

# v0.10 with no baseline: a module's indexed resource whose price Infracost could not find.
if convert "$fixtures/infracost-v0.10-new-module.json" >"$work/module.json" 2>"$work/err"; then
  same_json "v0.10 null cost stays null on a new module resource" "$work/module.json" '{
    "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
    "source": "infracost", "currency": "USD",
    "resources": [
      {"address": "module.ecr.aws_ecr_repository.this[0]", "type": "aws_ecr_repository",
       "change": "create", "monthlyCostBefore": null, "monthlyCostAfter": null, "resourceIds": []}
    ]
  }'
else
  fail "v0.10 null cost stays null on a new module resource" "$(cat "$work/err")"
fi

# A line Infracost wrote without a type takes it from the address, a for_each key with dots
# included.
jq '.projects[0].breakdown.resources[0] |= (.name = "module.ecr.aws_ecr_repository.this[\"a.b\"]" | .resourceType = null)' \
  "$fixtures/infracost-v0.10-new-module.json" >"$work/untyped.json"
convert "$work/untyped.json" >"$work/untyped-out.json"
check "a missing type is read from the address" \
  jq -e '[.resources[] | [.address, .type]] == [["module.ecr.aws_ecr_repository.this[\"a.b\"]", "aws_ecr_repository"]]' "$work/untyped-out.json"

# Unchanged resources, priced or null on both sides, in two projects: no line.
if convert "$fixtures/infracost-v0.10-unchanged.json" >"$work/unchanged.json" 2>"$work/err"; then
  check "unchanged resources give no line" jq -e '.resources == []' "$work/unchanged.json"
else
  fail "unchanged resources give no line" "$(cat "$work/err")"
fi

# A config-file run over a repository of several Terraform roots writes every root as a project; a
# pull request that changes only one root, first or later, posts that root's lines, never another
# root's or none.
one_root_created='{
  "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
  "source": "infracost", "currency": "USD",
  "resources": [
    {"address": "aws_instance.web_app3", "type": "aws_instance", "change": "create",
     "monthlyCostBefore": null, "monthlyCostAfter": "70", "resourceIds": []}
  ]
}'
jq '.projects[1].breakdown.resources += [{"name": "aws_instance.web_app3", "resourceType": "aws_instance", "monthlyCost": "70"}]' \
  "$fixtures/infracost-v0.10-unchanged.json" >"$work/second-root.json"
if convert "$work/second-root.json" >"$work/second-root-out.json" 2>"$work/err"; then
  same_json "v0.10: of two projects, only the second changed, its line is posted" "$work/second-root-out.json" "$one_root_created"
else
  fail "v0.10: of two projects, only the second changed, its line is posted" "$(cat "$work/err")"
fi
cat >"$work/second-root-v2.json" <<'EOF'
{"currency": "USD", "past_total_monthly_cost": "10", "total_monthly_cost": "80", "diff_total_monthly_cost": "70",
 "projects": [
   {"project_name": "dev", "op": "unchanged", "resources": []},
   {"project_name": "prod", "op": "changed", "resources": [
     {"name": "aws_instance.web_app3", "type": "aws_instance", "op": "added", "past_monthly_cost": "0", "monthly_cost": "70"}]}]}
EOF
if convert "$work/second-root-v2.json" >"$work/second-root-v2-out.json" 2>"$work/err"; then
  same_json "v2: of two projects, only the second changed, its line is posted" "$work/second-root-v2-out.json" "$one_root_created"
else
  fail "v2: of two projects, only the second changed, its line is posted" "$(cat "$work/err")"
fi
jq '.projects[0].breakdown.resources += [{"name": "aws_instance.web_app3", "resourceType": "aws_instance", "monthlyCost": "70"}]' \
  "$fixtures/infracost-v0.10-unchanged.json" >"$work/first-root.json"
if convert "$work/first-root.json" >"$work/first-root-out.json" 2>"$work/err"; then
  same_json "v0.10: of two projects, only the first changed, its line is posted" "$work/first-root-out.json" "$one_root_created"
else
  fail "v0.10: of two projects, only the first changed, its line is posted" "$(cat "$work/err")"
fi
cat >"$work/first-root-v2.json" <<'EOF'
{"currency": "USD", "past_total_monthly_cost": "10", "total_monthly_cost": "80", "diff_total_monthly_cost": "70",
 "projects": [
   {"project_name": "prod", "op": "changed", "resources": [
     {"name": "aws_instance.web_app3", "type": "aws_instance", "op": "added", "past_monthly_cost": "0", "monthly_cost": "70"}]},
   {"project_name": "dev", "op": "unchanged", "resources": []}]}
EOF
if convert "$work/first-root-v2.json" >"$work/first-root-v2-out.json" 2>"$work/err"; then
  same_json "v2: of two projects, only the first changed, its line is posted" "$work/first-root-v2-out.json" "$one_root_created"
else
  fail "v2: of two projects, only the first changed, its line is posted" "$(cat "$work/err")"
fi

# Optional fields travel when given and are left out when empty.
convert --arg commit 9fceb02d --arg url https://github.com/acme/infra/pull/42 --arg sourceVersion 0.10.41 \
  "$fixtures/infracost-v0.10-diff.json" >"$work/optional.json"
check "commit, url and source version travel when given" \
  jq -e '.commit == "9fceb02d" and .url == "https://github.com/acme/infra/pull/42" and .sourceVersion == "0.10.41"' "$work/optional.json"
check "empty optional fields are left out" \
  jq -e '(has("commit") or has("url") or has("sourceVersion") or has("plan") or has("tag")) | not' "$work/v010.json"

# Decimal strings are rewritten as text, never through floating point: at most 8 places, rounded
# half away from zero, no exponent, and digits a double cannot hold kept.
jq '.projects[0].breakdown.resources[0].monthlyCost = "12345678901234567.123456785"
  | .projects[0].pastBreakdown.resources[1].monthlyCost = "7.4264E+2"' \
  "$fixtures/infracost-v0.10-diff.json" >"$work/precise.json"
convert "$work/precise.json" >"$work/precise-out.json"
check "decimals keep every digit and round to 8 places" \
  jq -e '(.resources[] | select(.address == "aws_instance.web_app") | [.monthlyCostBefore, .monthlyCostAfter])
    == ["742.64", "12345678901234567.12345679"]' "$work/precise-out.json"
check "every decimal matches the contract's pattern" \
  jq -e '[.resources[] | .monthlyCostBefore, .monthlyCostAfter | select(. != null)]
    | length > 0 and all(test("^-?[0-9]+(\\.[0-9]{1,8})?$"))' "$work/precise-out.json"
jq '.projects[0].breakdown.resources[0].monthlyCost = "999.999999995"
  | .projects[0].pastBreakdown.resources[1].monthlyCost = "-0.000000001"' \
  "$fixtures/infracost-v0.10-diff.json" >"$work/carry.json"
convert "$work/carry.json" >"$work/carry-out.json"
check "rounding carries into the integer part and a vanishing negative is zero" \
  jq -e '(.resources[] | select(.address == "aws_instance.web_app") | [.monthlyCostBefore, .monthlyCostAfter])
    == ["0", "1000"]' "$work/carry-out.json"
jq '.projects[0].breakdown.resources[0].monthlyCost = "12,50"' "$fixtures/infracost-v0.10-diff.json" >"$work/comma.json"
if convert "$work/comma.json" >/dev/null 2>"$work/err"; then
  fail "a cost that is not a decimal is refused"
else
  check "a cost that is not a decimal is refused" grep -q 'aws_instance.web_app' "$work/err"
fi

# Leading zeros go but the one before the point, trailing ones after it go, and zero is never
# negative.
zeros_wrong=""
while read -r cost want; do
  jq --arg cost "$cost" '.projects[0].breakdown.resources[0].monthlyCost = $cost' \
    "$fixtures/infracost-v0.10-diff.json" >"$work/zeros.json"
  got="$(convert "$work/zeros.json" | jq -r '.resources[] | select(.address == "aws_instance.web_app") | .monthlyCostAfter')" \
    || got="a refusal"
  [[ "$got" == "$want" ]] || zeros_wrong+="$cost gave $got, not $want; "
done <<'COSTS'
007 7
0 0
00 0
000.000 0
0.50 0.5
-0.0 0
-0 0
000.1 0.1
0010.0100 10.01
-007.50 -7.5
.5 0.5
0.000000005 0.00000001
0e5 0
COSTS
if [[ -z "$zeros_wrong" ]]; then
  pass "leading and trailing zeros are stripped, keeping one before the point"
else
  fail "leading and trailing zeros are stripped, keeping one before the point" "$zeros_wrong"
fi

# --- refusals, before any request -----------------------------------------------------------

# ended <success|failure> <requests> [text]: how the last run ended, how many requests it made,
# and a text its output holds.
ended() {
  if [[ "$1" == success ]]; then [[ "$status" -eq 0 ]] || return 1; else [[ "$status" -ne 0 ]] || return 1; fi
  [[ "$(calls)" -eq "$2" ]] || return 1
  [[ -z "${3:-}" ]] || grep -qF -- "$3" "$STUB_DIR/output"
}
# argv_has <call> <argument>...: each argument is one of that curl call's arguments.
argv_has() {
  local call="$1" argument
  shift
  for argument in "$@"; do grep -qxF -- "$argument" "$STUB_DIR/call-$call.argv" || return 1; done
}
# lacks <text> <file>...: no file holds the text.
lacks() { ! grep -qF -- "$1" "${@:2}"; }
slept() { [[ "$(tr '\n' ' ' <"$STUB_DIR/sleeps")" == "$1" ]]; }
masked_once() {
  [[ "$(grep -cF -- "$token" "$STUB_DIR/output")" -eq 1 && "$(head -1 "$STUB_DIR/output")" == "::add-mask::$token" ]]
}

refused_before_request() {
  local name="$1" document="$2" expect="$3"
  new_case
  export COSTFLUENT_INFRACOST_JSON="$document"
  run_script
  if ended failure 0 "$expect"; then
    pass "$name"
  else
    fail "$name" "status $status, $(calls) requests: $(head -5 "$STUB_DIR/output")"
  fi
}
refused_before_request "v2 summary JSON is refused, naming the formats read" \
  "$fixtures/infracost-v2-summary.json" 'Infracost v0.10 JSON'
refused_before_request "a Terraform plan given as Infracost JSON is refused" \
  "$fixtures/terraform-plan.json" 'infracost diff --json'
refused_before_request "a v0.10 document with a failed project is refused" \
  "$fixtures/infracost-v0.10-project-error.json" 'failed in Infracost'
refused_before_request "changes in several Terraform roots are refused" \
  "$fixtures/infracost-v0.10-projects.json" 'more than one Infracost project'
printf 'not json' >"$work/not-json"
refused_before_request "a file that is not JSON is refused" "$work/not-json" 'not JSON'
for format in v0.10:infracost-v0.10-diff v2:infracost-v2-diff; do
  for currency in '"eur"' '"EURO"' 123 null false; do
    jq --argjson currency "$currency" '.currency = $currency' "$fixtures/${format#*:}.json" >"$work/currency.json"
    refused_before_request "a ${format%%:*} diff in currency $currency is refused" \
      "$work/currency.json" "the currency $currency is not an ISO 4217 code"
  done
done

new_case
export COSTFLUENT_TERRAFORM_PLAN_JSON="$fixtures/terraform-state.json"
run_script
check "a state given as the plan is refused before any request" ended failure 0 'terraform show -json'

new_case
export COSTFLUENT_BASE_URL=http://api.costfluent.com
run_script
check "a base URL that is not https is refused before any request" ended failure 0 'https URL'

new_case
export COSTFLUENT_PULL_REQUEST=abc
run_script
check "a pull request that is not a number is refused before any request" ended failure 0 'pull request number'

new_case
export COSTFLUENT_INFRACOST_JSON="$fixtures/infracost-v0.10-unchanged.json"
run_script
check "no changed resource posts nothing and succeeds" ended success 0 'nothing to post'

# --- estimate: the post ---------------------------------------------------------------------

new_case
export COSTFLUENT_INFRACOST_JSON="$fixtures/infracost-v2-diff-usage.json"
export COSTFLUENT_TERRAFORM_PLAN_JSON="$fixtures/terraform-plan.json"
export GITHUB_OUTPUT="$STUB_DIR/github-output"
: >"$GITHUB_OUTPUT"
run_script
check "estimate posts once and succeeds" ended success 1
check "estimate posts to /v1/cost-estimates" \
  argv_has 1 --request POST https://api.costfluent.com/v1/cost-estimates
check "estimate is bounded, https only and fails with the body" \
  argv_has 1 --fail-with-body --max-time 60 --proto =https --config -
same_json "the post carries the pull request reference, the plan's changes and the ids before" \
  "$STUB_DIR/call-1.body" '{
    "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
    "source": "infracost", "sourceVersion": "0.10.41",
    "commit": "9fceb02d0ae598e95dc970b74767f19372d61af8",
    "url": "https://github.com/acme/infra/pull/42", "currency": "USD",
    "resources": [
      {"address": "aws_db_instance.old", "type": "aws_db_instance", "change": "delete",
       "monthlyCostBefore": "120", "monthlyCostAfter": null,
       "resourceIds": ["db-7KQ2XWLNB4HFTZJ5O3M6PDRVYE", "arn:aws:rds:us-east-1:111111111111:db:old"]},
      {"address": "aws_instance.web_app", "type": "aws_instance", "change": "replace",
       "monthlyCostBefore": "70", "monthlyCostAfter": "566",
       "resourceIds": ["i-0d1e2f3a4b5c6d7e8", "arn:aws:ec2:us-east-1:111111111111:instance/i-0d1e2f3a4b5c6d7e8"]},
      {"address": "aws_lambda_function.hello", "type": "aws_lambda_function", "change": "create",
       "monthlyCostBefore": null, "monthlyCostAfter": null, "resourceIds": []},
      {"address": "aws_s3_bucket.data", "type": "aws_s3_bucket", "change": "update",
       "monthlyCostBefore": "23", "monthlyCostAfter": "46",
       "resourceIds": ["acme-data", "arn:aws:s3:::acme-data"]}
    ]
  }'
check "the estimate id is a step output" grep -qx 'estimate-id=est_01J9Z3Q4XKWD7VB2MF8N6Y' "$GITHUB_OUTPUT"

# Ids are deduplicated in order and capped at three: an aws_lb's id is its ARN, and a GCP
# resource carries a self_link.
jq '(.resource_changes[] | select(.address == "aws_s3_bucket.data" and .deposed == null) | .change.before)
      |= (.id = .arn | .self_link = "https://www.googleapis.com/storage/v1/b/acme-data")
  | (.resource_changes[] | select(.address == "aws_db_instance.old") | .change.before)
      |= (.self_link = "https://example.test/old")' \
  "$fixtures/terraform-plan.json" >"$work/plan-dedupe.json"
convert --slurpfile terraformPlan "$work/plan-dedupe.json" "$fixtures/infracost-v2-diff-usage.json" >"$work/dedupe.json"
check "ids are deduplicated in order and at most three" \
  jq -e '[.resources[] | select(.address == "aws_s3_bucket.data" or .address == "aws_db_instance.old") | .resourceIds]
    == [["db-7KQ2XWLNB4HFTZJ5O3M6PDRVYE", "arn:aws:rds:us-east-1:111111111111:db:old", "https://example.test/old"],
        ["arn:aws:s3:::acme-data", "https://www.googleapis.com/storage/v1/b/acme-data"]]' "$work/dedupe.json"

# Google Cloud: its billing data names a resource by its global name, which the conversion builds
# from the self_link, so that comes first and the raw self_link, which never matches, last. A
# self_link outside projects/, such as a bucket's above, gives none.
jq '(.projects[0].pastBreakdown.resources[], .projects[0].breakdown.resources[])
      |= (if .name == "aws_instance.web_app" then .name = "google_compute_instance.default" | .resourceType = "google_compute_instance" else . end)' \
  "$fixtures/infracost-v0.10-diff.json" >"$work/gcp-estimate.json"
convert --slurpfile terraformPlan "$fixtures/terraform-gcp-plan.json" "$work/gcp-estimate.json" >"$work/gcp-out.json"
check "a GCP resource's global name is derived from its self_link and comes first" \
  jq -e '(.resources[] | select(.address == "google_compute_instance.default") | [.change, .resourceIds])
    == ["update", ["//compute.googleapis.com/projects/google.com:stschmidt/zones/us-central1-a/instances/test", "test",
                   "https://www.googleapis.com/compute/v1/projects/google.com:stschmidt/zones/us-central1-a/instances/test"]]' \
  "$work/gcp-out.json"
jq '.resource_changes[0].change.before.self_link = "https://container.googleapis.com/v1/projects/acme/locations/europe-west3/clusters/main"' \
  "$fixtures/terraform-gcp-plan.json" >"$work/gke-plan.json"
convert --slurpfile terraformPlan "$work/gke-plan.json" "$work/gcp-estimate.json" >"$work/gke-out.json"
check "a self_link on the service's own host gives its global name too" \
  jq -e '(.resources[] | select(.address == "google_compute_instance.default") | .resourceIds[0])
    == "//container.googleapis.com/projects/acme/locations/europe-west3/clusters/main"' "$work/gke-out.json"

# Without a plan the change comes from presence in the two breakdowns, and no line has ids.
check "without a plan, presence decides the change and no line has ids" \
  jq -e '[.resources[] | [.change, (.resourceIds | length)]] == [["update", 0], ["delete", 0]]' "$work/v010.json"

# A `moved` block renames aws_instance.old to aws_instance.new. Infracost prices the base under the
# old address and the pull request under the new one; the plan names the old one previous_address.
# moved_lines <name> <infracost> <plan, or - for none> <expected resources>
moved_lines() {
  local name="$1" plan_args=()
  [[ "$3" == - ]] || plan_args=(--slurpfile terraformPlan "$3")
  if convert ${plan_args[@]+"${plan_args[@]}"} "$2" >"$work/moved-out.json" 2>"$work/err"; then
    jq .resources "$work/moved-out.json" >"$work/moved-lines.json"
    same_json "$name" "$work/moved-lines.json" "$4"
  else
    fail "$name" "$(cat "$work/err")"
  fi
}
cat >"$work/moved-v010.json" <<'EOF'
{"version": "0.2", "currency": "USD", "projects": [{"name": "main", "metadata": {},
  "pastBreakdown": {"resources": [{"name": "aws_instance.old", "resourceType": "aws_instance", "monthlyCost": "10"}]},
  "breakdown": {"resources": [{"name": "aws_instance.new", "resourceType": "aws_instance", "monthlyCost": "10"}]}}]}
EOF
cat >"$work/moved-v2.json" <<'EOF'
{"currency": "USD", "past_total_monthly_cost": "10", "total_monthly_cost": "10", "diff_total_monthly_cost": "0",
 "projects": [{"project_name": "main", "op": "changed", "resources": [
   {"name": "aws_instance.old", "op": "removed", "past_monthly_cost": "10", "monthly_cost": "0"},
   {"name": "aws_instance.new", "op": "added", "past_monthly_cost": "0", "monthly_cost": "10"}]}]}
EOF
cat >"$work/moved-plan.json" <<'EOF'
{"format_version": "1.2", "resource_changes": [
  {"address": "aws_instance.new", "previous_address": "aws_instance.old", "mode": "managed", "type": "aws_instance",
   "name": "new", "change": {"actions": ["no-op"], "before": {"id": "i-123"}, "after": {"id": "i-123"}}}]}
EOF
jq '.projects[0].breakdown.resources[0].monthlyCost = "20"' "$work/moved-v010.json" >"$work/moved-v010-resized.json"
jq '.projects[0].resources[1].monthly_cost = "20"' "$work/moved-v2.json" >"$work/moved-v2-resized.json"
jq '.resource_changes[0].change.actions = ["update"]' "$work/moved-plan.json" >"$work/moved-plan-update.json"
jq '.resource_changes[0].change.actions = ["delete", "create"]' "$work/moved-plan.json" >"$work/moved-plan-replace.json"
moved_update='[{"address": "aws_instance.new", "type": "aws_instance", "change": "update",
  "monthlyCostBefore": "10", "monthlyCostAfter": "20", "resourceIds": ["i-123"]}]'
moved_replace='[{"address": "aws_instance.new", "type": "aws_instance", "change": "replace",
  "monthlyCostBefore": "10", "monthlyCostAfter": "20", "resourceIds": ["i-123"]}]'
moved_lines "a moved resource with an unchanged cost posts no line" \
  "$work/moved-v010.json" "$work/moved-plan.json" '[]'
moved_lines "a moved and updated resource is one update with its ids" \
  "$work/moved-v010-resized.json" "$work/moved-plan-update.json" "$moved_update"
moved_lines "a moved and replaced resource is one replace" \
  "$work/moved-v010-resized.json" "$work/moved-plan-replace.json" "$moved_replace"
moved_lines "v2: a moved resource with an unchanged cost posts no line" \
  "$work/moved-v2.json" "$work/moved-plan.json" '[]'
moved_lines "v2: a moved and updated resource is one update with its ids" \
  "$work/moved-v2-resized.json" "$work/moved-plan-update.json" "$moved_update"
moved_lines "v2: a moved and replaced resource is one replace" \
  "$work/moved-v2-resized.json" "$work/moved-plan-replace.json" "$moved_replace"

# An update at an unchanged cost has no line without a move (v0.10 drops it, v2 does not list it),
# so it has none with one either, whatever the plan does to the resource.
moved_lines "a moved and updated resource with an unchanged cost posts no line" \
  "$work/moved-v010.json" "$work/moved-plan-update.json" '[]'
moved_lines "a moved and replaced resource with an unchanged cost posts no line" \
  "$work/moved-v010.json" "$work/moved-plan-replace.json" '[]'
moved_lines "v2: a moved and updated resource with an unchanged cost posts no line" \
  "$work/moved-v2.json" "$work/moved-plan-update.json" '[]'
# Infracost could price neither address: both costs are unknown, which counts as unchanged.
jq '.projects[0].pastBreakdown.resources[0].monthlyCost = null | .projects[0].breakdown.resources[0].monthlyCost = null' \
  "$work/moved-v010.json" >"$work/moved-unknown.json"
jq '.projects[0].resources[] |= . + {cost_depends_on_usage: true, past_monthly_cost: "0", monthly_cost: "0"}' \
  "$work/moved-v2.json" >"$work/moved-v2-unknown.json"
moved_lines "a moved and updated resource Infracost could not price posts no line" \
  "$work/moved-unknown.json" "$work/moved-plan-update.json" '[]'
moved_lines "v2: a moved and updated resource Infracost could not price posts no line" \
  "$work/moved-v2-unknown.json" "$work/moved-plan-update.json" '[]'

# Infracost priced the old address but not the new one: the line still belongs to the resource the
# plan moved, so it is at the new address, with the plan's ids and an unknown cost after.
jq '.projects[0].breakdown.resources = []' "$work/moved-v010.json" >"$work/moved-to-unpriced.json"
jq 'del(.projects[0].resources[1])' "$work/moved-v2.json" >"$work/moved-v2-to-unpriced.json"
moved_to_unpriced='[{"address": "aws_instance.new", "type": "aws_instance", "change": "update",
  "monthlyCostBefore": "10", "monthlyCostAfter": null, "resourceIds": ["i-123"]}]'
moved_lines "a move to an address Infracost did not price is one update at the new address" \
  "$work/moved-to-unpriced.json" "$work/moved-plan.json" "$moved_to_unpriced"
moved_lines "v2: a move to an address Infracost did not price is one update at the new address" \
  "$work/moved-v2-to-unpriced.json" "$work/moved-plan.json" "$moved_to_unpriced"
cp "$work/moved-out.json" "$work/moved-to-unpriced-out.json"

# Infracost priced the new address but not the old one: the cost before is unknown, not the "0"
# v2 writes as an added resource's past cost.
jq '.projects[0].pastBreakdown.resources = []' "$work/moved-v010.json" >"$work/moved-unpriced.json"
jq 'del(.projects[0].resources[0])' "$work/moved-v2.json" >"$work/moved-v2-unpriced.json"
moved_from_unpriced='[{"address": "aws_instance.new", "type": "aws_instance", "change": "update",
  "monthlyCostBefore": null, "monthlyCostAfter": "10", "resourceIds": ["i-123"]}]'
moved_lines "an updated move from an address Infracost did not price has an unknown cost before" \
  "$work/moved-unpriced.json" "$work/moved-plan-update.json" "$moved_from_unpriced"
moved_lines "v2: an updated move from an address Infracost did not price has an unknown cost before" \
  "$work/moved-v2-unpriced.json" "$work/moved-plan-update.json" "$moved_from_unpriced"

# Beside the move, a plain create and a plain delete keep their own lines.
jq '.projects[0].pastBreakdown.resources += [{"name": "aws_db_instance.gone", "resourceType": "aws_db_instance", "monthlyCost": "120"}]
  | .projects[0].breakdown.resources += [{"name": "aws_instance.added", "resourceType": "aws_instance", "monthlyCost": "30"}]' \
  "$work/moved-v010.json" >"$work/moved-beside.json"
jq '.resource_changes += [
    {"address": "aws_instance.added", "mode": "managed", "type": "aws_instance", "name": "added",
     "change": {"actions": ["create"], "before": null, "after": {}}},
    {"address": "aws_db_instance.gone", "mode": "managed", "type": "aws_db_instance", "name": "gone",
     "change": {"actions": ["delete"], "before": {"id": "db-1"}, "after": null}}]' \
  "$work/moved-plan.json" >"$work/moved-beside-plan.json"
moved_lines "a create and a delete beside a move keep their lines" \
  "$work/moved-beside.json" "$work/moved-beside-plan.json" '[
    {"address": "aws_db_instance.gone", "type": "aws_db_instance", "change": "delete",
     "monthlyCostBefore": "120", "monthlyCostAfter": null, "resourceIds": ["db-1"]},
    {"address": "aws_instance.added", "type": "aws_instance", "change": "create",
     "monthlyCostBefore": null, "monthlyCostAfter": "30", "resourceIds": []}]'

# A module moved as a whole moves each of its resources; one of them is also resized.
cat >"$work/moved-module.json" <<'EOF'
{"version": "0.2", "currency": "USD", "projects": [{"name": "main", "metadata": {},
  "pastBreakdown": {"resources": [
    {"name": "module.a.aws_instance.x[0]", "resourceType": "aws_instance", "monthlyCost": "5"},
    {"name": "module.a.aws_instance.x[1]", "resourceType": "aws_instance", "monthlyCost": "5"}]},
  "breakdown": {"resources": [
    {"name": "module.b.aws_instance.x[0]", "resourceType": "aws_instance", "monthlyCost": "5"},
    {"name": "module.b.aws_instance.x[1]", "resourceType": "aws_instance", "monthlyCost": "7"}]}}]}
EOF
cat >"$work/moved-module-plan.json" <<'EOF'
{"format_version": "1.2", "resource_changes": [
  {"address": "module.b.aws_instance.x[0]", "previous_address": "module.a.aws_instance.x[0]", "module_address": "module.b",
   "mode": "managed", "type": "aws_instance", "name": "x", "index": 0,
   "change": {"actions": ["no-op"], "before": {"id": "i-0"}, "after": {"id": "i-0"}}},
  {"address": "module.b.aws_instance.x[1]", "previous_address": "module.a.aws_instance.x[1]", "module_address": "module.b",
   "mode": "managed", "type": "aws_instance", "name": "x", "index": 1,
   "change": {"actions": ["update"], "before": {"id": "i-1"}, "after": {"id": "i-1"}}}]}
EOF
moved_lines "a module moved as a whole pairs each of its resources" \
  "$work/moved-module.json" "$work/moved-module-plan.json" '[
    {"address": "module.b.aws_instance.x[1]", "type": "aws_instance", "change": "update",
     "monthlyCostBefore": "5", "monthlyCostAfter": "7", "resourceIds": ["i-1"]}]'
cp "$work/moved-out.json" "$work/moved-module-out.json"

# A move from count to for_each renames aws_instance.x[0] to aws_instance.x["a"].
jq '.projects[0].pastBreakdown.resources[0].name = "aws_instance.x[0]"
  | .projects[0].breakdown.resources[0].name = "aws_instance.x[\"a\"]"' \
  "$work/moved-v010-resized.json" >"$work/moved-for-each.json"
jq '.resource_changes[0] += {address: "aws_instance.x[\"a\"]", previous_address: "aws_instance.x[0]", name: "x", index: "a"}' \
  "$work/moved-plan-update.json" >"$work/moved-for-each-plan.json"
moved_lines "a count instance moved to a for_each key is one update with its ids" \
  "$work/moved-for-each.json" "$work/moved-for-each-plan.json" '[
    {"address": "aws_instance.x[\"a\"]", "type": "aws_instance", "change": "update",
     "monthlyCostBefore": "10", "monthlyCostAfter": "20", "resourceIds": ["i-123"]}]'

# Neighbours that stay as they were: an old address Infracost did not price leaves the line at the
# new one alone, and without a plan nothing says the two addresses are one resource.
moved_lines "a move from an address Infracost did not price is one line at the new address" \
  "$work/moved-unpriced.json" "$work/moved-plan.json" '[
    {"address": "aws_instance.new", "type": "aws_instance", "change": "create",
     "monthlyCostBefore": null, "monthlyCostAfter": "10", "resourceIds": []}]'
moved_lines "without a plan, a move is still a delete and a create" \
  "$work/moved-v010.json" - '[
    {"address": "aws_instance.new", "type": "aws_instance", "change": "create",
     "monthlyCostBefore": null, "monthlyCostAfter": "10", "resourceIds": []},
    {"address": "aws_instance.old", "type": "aws_instance", "change": "delete",
     "monthlyCostBefore": "10", "monthlyCostAfter": null, "resourceIds": []}]'

new_case
export COSTFLUENT_INFRACOST_JSON="$work/moved-v010.json"
export COSTFLUENT_TERRAFORM_PLAN_JSON="$work/moved-plan.json"
run_script
check "a pull request that only moves a resource posts nothing and succeeds" ended success 0 'nothing to post'

# --- the token ------------------------------------------------------------------------------

new_case
run_script
check "the token is never on curl's command line" lacks "$token" "$STUB_DIR"/call-*.argv
check "the token reaches curl only as the header in its config on stdin" \
  grep -qxF "header = \"Authorization: Bearer $token\"" "$STUB_DIR/call-1.stdin"
check "the token is not in the output" lacks "$token" "$STUB_DIR/output"

new_case
export GITHUB_ACTIONS=true
run_script
check "in GitHub Actions the token is masked first and appears nowhere else" masked_once

# A line break would split the mask command and end the curl config line, so a token holding any
# control character is refused before either, and the run prints none of it.
for breaker in $'\n' $'\r' $'\t'; do
  new_case
  export GITHUB_ACTIONS=true
  export COSTFLUENT_API_TOKEN="$token${breaker}url = \"https://attacker.test\""
  run_script
  if ended failure 0 'COSTFLUENT_API_TOKEN holds a control character' && lacks "$token" "$STUB_DIR/output"; then
    pass "a token holding $(printf '%q' "$breaker") is refused before the mask and any request"
  else
    fail "a token holding $(printf '%q' "$breaker") is refused before the mask and any request" \
      "status $status, $(calls) requests: $(head -3 "$STUB_DIR/output")"
  fi
done

# --- retries --------------------------------------------------------------------------------

new_case
respond 1 429 '{"title":"Too Many Requests"}' 'Retry-After: 7'
respond 2 503 '{"title":"Service Unavailable"}'
respond 3 000
respond 4 200 '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed"}'
run_script
check "429, 5xx and no answer are retried and the fourth attempt succeeds" ended success 4
check "Retry-After is honoured, otherwise the wait doubles" slept '7 4 8 '
check "every attempt posts the same body" \
  cmp -s "$STUB_DIR/call-1.body" "$STUB_DIR/call-4.body"

new_case
respond 1 502 '' 'Retry-After: 1'
respond 2 502 '' 'retry-after: 2'
respond 3 500
respond 4 503
run_script
check "after three retries the post fails" ended failure 4 'answered 503 after 4 attempts'
check "a lower-case Retry-After is honoured too" slept '1 2 8 '

new_case
respond 1 429 '' 'Retry-After: 86400'
respond 2 201 '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed"}'
run_script
check "a Retry-After beyond the job's patience is capped" slept '120 '

# A curl failure other than no address, no connection, a timeout or a dropped answer is local,
# so a retry would repeat it; the retried ones are retried whatever the code.
for code in 60 3 26; do
  new_case
  respond 1 000 '' '' "$code"
  run_script
  if ended failure 1 && [[ ! -f "$STUB_DIR/sleeps" ]]; then
    pass "curl exit $code fails at once"
  else
    fail "curl exit $code fails at once" "status $status, $(calls) requests"
  fi
done
for code in 5 6 7 35 52 55 56; do
  new_case
  respond 1 000 '' '' "$code"
  run_script
  check "curl exit $code is retried" ended success 2
done

for code in 400 401 403 404 408 409 413; do
  new_case
  respond 1 "$code" '{"type":"about:blank","title":"Refused","status":'"$code"',"detail":"Detail for '"$code"'"}'
  run_script
  if ended failure 1 "Detail for $code" && [[ ! -f "$STUB_DIR/sleeps" ]]; then
    pass "$code fails at once with the problem's detail"
  else
    fail "$code fails at once with the problem's detail" "status $status, $(calls) requests"
  fi
done

# In GitHub Actions a line that starts with :: is a workflow command, so a value from the pull
# request or the API holding a line break must stay inside the one ::error:: line.
# one_error <text>: exactly one ::error:: line, holding the text, and no ::warning:: line.
one_error() {
  [[ "$(grep -c '^::error::' "$STUB_DIR/output")" -eq 1 ]] \
    && grep '^::error::' "$STUB_DIR/output" | grep -qF -- "$1" \
    && ! grep -q '^::warning::' "$STUB_DIR/output"
}
new_case
export GITHUB_ACTIONS=true
respond 1 400 '{"title":"Refused","detail":"Detail\n::warning::x"}'
run_script
check "a problem detail holding a line break stays in one escaped ::error:: line" one_error 'Detail%0A::warning::x'

jq '.projects[0].breakdown.resources[0] |= (.name = "aws_instance.web_app\n::warning::x" | .monthlyCost = "12,50")' \
  "$fixtures/infracost-v0.10-diff.json" >"$work/address-break.json"
jq '.projects[0].metadata.errors = [{"message": "Failed\n::warning::x", "isError": true}]' \
  "$fixtures/infracost-v0.10-diff.json" >"$work/message-break.json"
new_case
export GITHUB_ACTIONS=true COSTFLUENT_INFRACOST_JSON="$work/address-break.json"
run_script
if ended failure 0 && one_error 'aws_instance.web_app%0A::warning::x'; then
  pass "a refused address holding a line break stays in one escaped ::error:: line"
else
  fail "a refused address holding a line break stays in one escaped ::error:: line" "$(head -5 "$STUB_DIR/output")"
fi
new_case
export GITHUB_ACTIONS=true COSTFLUENT_INFRACOST_JSON="$work/message-break.json"
run_script
if ended failure 0 && one_error 'Failed%0A::warning::x'; then
  pass "an Infracost error holding a line break stays in one escaped ::error:: line"
else
  fail "an Infracost error holding a line break stays in one escaped ::error:: line" "$(head -5 "$STUB_DIR/output")"
fi

# --- apply ----------------------------------------------------------------------------------

# new_apply_case: apply mode with Infracost's own pair, a plan made before a deploy and the state
# the deploy left.
new_apply_case() {
  new_case
  unset COSTFLUENT_INFRACOST_JSON
  export COSTFLUENT_MODE=apply
  export COSTFLUENT_TERRAFORM_PLAN_JSON="$fixtures/terraform-apply-plan.json"
  export COSTFLUENT_TERRAFORM_STATE_JSON="$fixtures/terraform-apply-state.json"
  printf '200' >"$STUB_DIR/response-default.status"
  printf '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"applied","appliedOn":"2026-10-26"}' >"$STUB_DIR/response-default.body"
}

new_apply_case
export GITHUB_OUTPUT="$STUB_DIR/github-output"
: >"$GITHUB_OUTPUT"
run_script
check "apply posts once, without looking the estimate up" ended success 1
check "apply posts to /v1/cost-estimates/apply" \
  argv_has 1 --request POST https://api.costfluent.com/v1/cost-estimates/apply
same_json "apply posts the reference and the created resources' ids from the state" "$STUB_DIR/call-1.body" '{
  "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
  "resources": [
    {"address": "aws_default_subnet.default",
     "resourceIds": ["subnet-d4d0998b", "arn:aws:ec2:us-east-1:111111111111:subnet/subnet-d4d0998b"]},
    {"address": "aws_instance.ec2",
     "resourceIds": ["i-07c5f80a7588ec957", "arn:aws:ec2:us-east-1:111111111111:instance/i-07c5f80a7588ec957"]},
    {"address": "aws_volume_attachment.storage_attachment", "resourceIds": ["vai-1043230385"]}
  ]
}'
check "the applied estimate's id is a step output" grep -qx 'estimate-id=est_01J9Z3Q4XKWD7VB2MF8N6Y' "$GITHUB_OUTPUT"
check "apply keeps the token off curl's command line" lacks "$token" "$STUB_DIR"/call-*.argv
check "apply sends the token in the config" grep -qxF "header = \"Authorization: Bearer $token\"" "$STUB_DIR/call-1.stdin"

# Replaces in either order, a module's keyed address, a deposed object and a create the state does
# not hold: the authored plan, two of its addresses moved to resources the Terraform 0.14 state holds.
jq '(.resource_changes[] | select(.address == "aws_instance.web_app" and .deposed == null))
      |= (.address = "module.instances.aws_instance.module_instance_named[\"test.1\"]" | .change.actions = ["create", "delete"])
  | (.resource_changes[] | select(.address == "aws_s3_bucket.data"))
      |= (.address = "module.db.module.db_1.module.db_instance.aws_db_instance.this[0]" | .change.actions = ["delete", "create"])' \
  "$fixtures/terraform-plan.json" >"$work/apply-modules-plan.json"
new_apply_case
export COSTFLUENT_TERRAFORM_PLAN_JSON="$work/apply-modules-plan.json"
export COSTFLUENT_TERRAFORM_STATE_JSON="$fixtures/terraform-state.json"
run_script
check "apply with replaces and modules succeeds" ended success 1
same_json "apply sends replaced resources and module addresses, not deletes, updates or deposed objects" \
  "$STUB_DIR/call-1.body" '{
  "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
  "resources": [
    {"address": "module.instances.aws_instance.module_instance_named[\"test.1\"]",
     "resourceIds": ["i-0aeeec88544779865", "arn:aws:ec2:us-east-1:123123123123:instance/i-0aeeec88544779865"]},
    {"address": "module.db.module.db_1.module.db_instance.aws_db_instance.this[0]",
     "resourceIds": ["demodb", "arn:aws:rds:us-east-1:123123123123:db:demodb"]}
  ]
}'
check "apply names a created resource the state does not hold" grep -q 'aws_lambda_function.hello' "$STUB_DIR/output"
check "apply names only that one" lacks 'aws_db_instance.old' "$STUB_DIR/output"

# A replaced GCP resource carries the global name its new self_link gives, first.
jq '.resource_changes[0].change.actions = ["create", "delete"]' "$fixtures/terraform-gcp-plan.json" >"$work/gcp-replace-plan.json"
new_apply_case
export COSTFLUENT_TERRAFORM_PLAN_JSON="$work/gcp-replace-plan.json"
export COSTFLUENT_TERRAFORM_STATE_JSON="$fixtures/terraform-gcp-state.json"
run_script
same_json "apply sends a replaced GCP resource with its global name first" "$STUB_DIR/call-1.body" '{
  "workspaceId": "wsp_8f3k2m4n5p6q7r8s9t0v1w", "repository": "acme/infra", "pullRequest": 42,
  "resources": [
    {"address": "google_compute_instance.default",
     "resourceIds": ["//compute.googleapis.com/projects/google.com:stschmidt/zones/us-central1-a/instances/test", "test",
                     "https://www.googleapis.com/compute/v1/projects/google.com:stschmidt/zones/us-central1-a/instances/test"]}
  ]
}'

new_apply_case
respond 1 404 '{"title":"Not Found","detail":"No cost estimate for this reference."}'
run_script
check "apply without an estimate posts once and succeeds" ended success 1 'No cost estimate'

new_apply_case
respond 1 404 '{"title":"Not Found","detail":"workspace '"'"'wsp_typo'"'"' not found"}'
run_script
check "apply names the API's reason for a 404, so a wrong workspace shows" ended success 1 "workspace 'wsp_typo' not found"

new_apply_case
respond 1 503 '' 'Retry-After: 3'
respond 2 409 '{"title":"Conflict","detail":"The estimate was applied with other ids."}'
run_script
check "apply retries a 5xx and fails at once on a conflict" ended failure 2 'applied with other ids'
check "apply waited as Retry-After asked" slept '3 '

new_apply_case
export COSTFLUENT_TERRAFORM_STATE_JSON="$fixtures/terraform-plan.json"
run_script
check "a plan given as the state is refused before any request" ended failure 0 'of the state'

new_apply_case
export COSTFLUENT_TERRAFORM_PLAN_JSON="$fixtures/terraform-apply-state.json"
run_script
check "a state given as the plan is refused before any request" ended failure 0 'of a saved plan'

new_apply_case
unset COSTFLUENT_TERRAFORM_PLAN_JSON
run_script
check "apply without the plan is refused before any request" ended failure 0 'COSTFLUENT_TERRAFORM_PLAN_JSON is required'

jq -n '{format_version: "1.2", planned_values: {}, resource_changes: [range(2001)
  | {address: "aws_instance.i\(.)", mode: "managed", type: "aws_instance", change: {actions: ["create"], before: null}}]}' \
  >"$work/large-plan.json"
jq -n '{format_version: "1.0", values: {root_module: {resources: [range(2001)
  | {address: "aws_instance.i\(.)", mode: "managed", type: "aws_instance", values: {id: "i-\(.)"}}]}}}' \
  >"$work/large-state.json"
new_apply_case
export COSTFLUENT_TERRAFORM_PLAN_JSON="$work/large-plan.json"
export COSTFLUENT_TERRAFORM_STATE_JSON="$work/large-state.json"
run_script
check "more created resources than one apply takes are refused before any request" ended failure 0 '2,000'

new_case
export COSTFLUENT_MODE=plan
run_script
check "an unknown mode is refused before any request" ended failure 0 'estimate or apply'

# --- estimate: the summary, the comment and fail-above ------------------------------------------

github_token="ghs_test-github-token-for-the-stub-only"
github=https://api.github.com/repos/acme/infra
marker='<!-- costfluent-cost-estimate workspace=wsp_8f3k2m4n5p6q7r8s9t0v1w -->'
receipt='{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed","planned":{"monthlyCostBefore":"742.64","monthlyCostAfter":"1303.28","monthlyChange":"560.64","unpricedResources":1}}'
# receipt_with <monthly change>: the receipt with that planned change.
receipt_with() { jq -c --arg change "$1" '.planned.monthlyChange = $change' <<<"$receipt"; }
# comment_page <count> [id body]: a page of count comments people wrote, then, with an id, the
# estimate's comment a bot wrote with that body.
comment_page() {
  jq -cn --argjson count "$1" --arg id "${2:-}" --arg body "${3:-}" '
    [range($count) | {id: (1000 + .), user: {login: "octocat", type: "User"}, body: "Looks fine"}]
    + if $id == "" then [] else [{id: ($id | tonumber), user: {login: "github-actions[bot]", type: "Bot"}, body: $body}] end'
}
# new_comment_case: an estimate run with comment on, a step summary and outputs, and the receipt
# carrying planned totals.
new_comment_case() {
  new_case
  export COSTFLUENT_COMMENT=true COSTFLUENT_GITHUB_TOKEN="$github_token" GITHUB_API_URL=https://api.github.com
  export GITHUB_STEP_SUMMARY="$STUB_DIR/summary" GITHUB_OUTPUT="$STUB_DIR/github-output"
  : >"$GITHUB_STEP_SUMMARY"
  : >"$GITHUB_OUTPUT"
  printf '%s' "$receipt" >"$STUB_DIR/response-default.body"
}
# comment_of <call>: the comment body that call sent.
comment_of() { jq -j .body "$STUB_DIR/call-$1.body"; }
# comments_created: how many calls created a comment.
comments_created() { grep -lx -- "$github/issues/42/comments" "$STUB_DIR"/call-*.argv 2>/dev/null | wc -l; }

expected_comment="$marker
### Costfluent cost estimate

| Planned monthly cost | |
|---|---|
| Before | \`742.64 USD\` |
| After | \`1303.28 USD\` |
| Change | \`+560.64 USD\` |
| Resources without a price | \`1\` |

Estimate \`est_01J9Z3Q4XKWD7VB2MF8N6Y\`, commit \`9fceb02d0ae598e95dc970b74767f19372d61af8\`, workspace \`wsp_8f3k2m4n5p6q7r8s9t0v1w\`."

new_comment_case
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
first_status=$status
respond 5 200 "$(comment_page 2 9001 "$(comment_of 3)")"
respond 6 200 '{"id":9001}'
run_script
created_then_updated() {
  [[ "$first_status" -eq 0 && "$status" -eq 0 && "$(calls)" -eq 6 && "$(comments_created)" -eq 1 ]] \
    && argv_has 2 --request GET "$github/issues/42/comments?per_page=100&page=1" \
    && argv_has 3 --request POST "$github/issues/42/comments" \
    && argv_has 5 --request GET "$github/issues/42/comments?per_page=100&page=1" \
    && argv_has 6 --request PATCH "$github/issues/comments/9001" \
    && [[ "$(comment_of 3)" == "$expected_comment" && "$(comment_of 6)" == "$expected_comment" ]]
}
if created_then_updated; then
  pass "the comment is created once and then updated in place"
else
  fail "the comment is created once and then updated in place" "statuses $first_status $status, $(calls) requests: $(comment_of 3 2>&1 | head -12)"
fi
check "the job summary holds the comment's body on every run" \
  [ "$(cat "$GITHUB_STEP_SUMMARY")" == "$expected_comment"$'\n'"$expected_comment" ]
check "the planned monthly change is a step output" grep -qx 'monthly-change=560.64' "$GITHUB_OUTPUT"

new_comment_case
export COSTFLUENT_FAIL_ABOVE=500
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
failed_after_commenting() {
  [[ "$status" -eq 4 && "$(calls)" -eq 3 ]] \
    && argv_has 3 --request POST "$github/issues/42/comments" \
    && [[ "$(comment_of 3)" == "$expected_comment" ]] \
    && grep -qF "\`+560.64 USD\`" "$GITHUB_STEP_SUMMARY" \
    && grep -qx 'monthly-change=560.64' "$GITHUB_OUTPUT" \
    && grep -qF 'the planned monthly change, 560.64 USD, is above fail-above, 500 USD' "$STUB_DIR/output"
}
if failed_after_commenting; then
  pass "a planned change above fail-above fails the job after commenting"
else
  fail "a planned change above fail-above fails the job after commenting" "status $status, $(calls) requests: $(tail -3 "$STUB_DIR/output")"
fi

new_comment_case
export COSTFLUENT_INFRACOST_JSON="$work/v0.10-eur.json" COSTFLUENT_FAIL_ABOVE=500
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
judged_in_eur() {
  [[ "$status" -eq 4 && "$(calls)" -eq 3 ]] \
    && jq -e '.currency == "EUR"' "$STUB_DIR/call-1.body" >/dev/null \
    && [[ "$(comment_of 3)" == "${expected_comment//USD/EUR}" ]] \
    && grep -qF "\`+560.64 EUR\`" "$GITHUB_STEP_SUMMARY" \
    && grep -qF 'the planned monthly change, 560.64 EUR, is above fail-above, 500 EUR' "$STUB_DIR/output"
}
if judged_in_eur; then
  pass "an EUR estimate is posted, commented and judged against fail-above in EUR"
else
  fail "an EUR estimate is posted, commented and judged against fail-above in EUR" "status $status, $(calls) requests: $(tail -3 "$STUB_DIR/output")"
fi

new_comment_case
respond 2 200 "$(jq -c --arg body "$marker"$'\nI copied this from the bot.' \
  '. + [{id: 5, user: {login: "octocat", type: "User"}, body: $body}]' <<<"$(comment_page 1)")"
respond 3 201 '{"id":9001}'
run_script
person_untouched() {
  ended success 3 && argv_has 3 --request POST "$github/issues/42/comments" \
    && lacks /issues/comments/ "$STUB_DIR"/call-*.argv
}
check "a person's comment carrying the marker is never edited; the bot's own is created" person_untouched

new_comment_case
respond 2 200 "$(comment_page 100)"
respond 3 200 "$(comment_page 3 77 "$marker"$'\nOld body')"
respond 4 200 '{"id":77}'
run_script
paged_to_the_second() {
  ended success 4 \
    && argv_has 2 --request GET "$github/issues/42/comments?per_page=100&page=1" \
    && argv_has 3 --request GET "$github/issues/42/comments?per_page=100&page=2" \
    && argv_has 4 --request PATCH "$github/issues/comments/77" \
    && [[ "$(comments_created)" -eq 0 ]]
}
check "comments are listed 100 a page, and the estimate's on the second page is edited" paged_to_the_second

new_comment_case
for page in $(seq 2 21); do respond "$page" 200 "$(comment_page 100)"; done
respond 22 201 '{"id":9001}'
run_script
check "listing stops after 20 pages of comments, then creates one" ended success 22 'first 2000 comments'
check "the last page listed is the twentieth" argv_has 21 --request GET "$github/issues/42/comments?per_page=100&page=20"

new_comment_case
export COSTFLUENT_INFRACOST_JSON="$fixtures/infracost-v0.10-unchanged.json"
respond 1 200 "$(comment_page 1 7 "$marker"$'\nOld body')"
respond 2 200 '{"id":7}'
run_script
check "a push with no priced change edits the stale comment to say so" ended success 2 'nothing to post'
check "a push with no priced change: the edit goes to the bot's comment" argv_has 2 --request PATCH "$github/issues/comments/7"
check "a push with no priced change: the comment says nothing was posted" \
  [ "$(comment_of 2 | sed -n 4p)" == "This push changes no priced resource, so nothing was posted to Costfluent, which keeps the estimate posted before." ]
check "a push with no priced change sets no monthly-change output" lacks monthly-change "$GITHUB_OUTPUT"

new_comment_case
export COSTFLUENT_INFRACOST_JSON="$fixtures/infracost-v0.10-unchanged.json"
respond 1 200 '[]'
run_script
check "a push with no priced change creates no comment" ended success 1
check "a push with no priced change still writes the summary" grep -qF 'changes no priced resource' "$GITHUB_STEP_SUMMARY"

new_case
export GITHUB_STEP_SUMMARY="$STUB_DIR/summary"
: >"$GITHUB_STEP_SUMMARY"
printf '%s' "$receipt" >"$STUB_DIR/response-default.body"
run_script
check "without comment, nothing calls GitHub" ended success 1
check "without comment, the summary still shows the planned change, without the marker" \
  [ "$(cat "$GITHUB_STEP_SUMMARY")" == "${expected_comment#"$marker"$'\n'}" ]

new_apply_case
export COSTFLUENT_COMMENT=true COSTFLUENT_FAIL_ABOVE=0
run_script
check "apply mode neither comments nor judges fail-above" ended success 1

# fail-above against the change, as exact decimals: equal passes, above fails with status 4.
# Pairs marked float are equal as doubles, so a floating-point comparison would pass them.
while read -r change limit expected kind; do
  new_case
  export COSTFLUENT_FAIL_ABOVE="$limit"
  respond 1 201 "$(receipt_with "$change")"
  run_script
  name="a planned change of $change against fail-above $limit exits $expected"
  [[ "$kind" != float ]] || name="$name, though floating point would round them equal"
  if [[ "$status" -eq "$expected" && "$(calls)" -eq 1 ]]; then pass "$name"; else fail "$name" "status $status: $(tail -1 "$STUB_DIR/output")"; fi
done <<'PAIRS'
560.64 560.640 0 equal
560.64 560.64 0 equal
1000000000000000.00000001 1000000000000000 4 float
0.3 0.29999999999999999 4 float
100000000000000000000.00000001 100000000000000000000 4 float
500.00000001 0500 4 -
12 9.99999999 4 -
9.5 10 0 -
0.00000001 0 4 -
0 0 0 -
-900.5 0 0 -
-0 0 0 -
PAIRS

for limit in -1 1e3 1,000 abc ' 5' 5. .5 0x10 $'5\n6'; do
  new_case
  export COSTFLUENT_FAIL_ABOVE="$limit"
  run_script
  if ended failure 0 'COSTFLUENT_FAIL_ABOVE must be a non-negative amount' && [[ "$status" -eq 1 ]]; then
    pass "a malformed fail-above $(printf '%q' "$limit") is refused before any request"
  else
    fail "a malformed fail-above $(printf '%q' "$limit") is refused before any request" "status $status, $(calls) requests"
  fi
done

# A server older than the planned totals answers without them; totals that are not the contract's
# decimals are treated the same way. fail-above cannot judge either, so it warns and passes.
for answer in '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed"}' \
  '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y","state":"proposed","planned":null}' \
  "$(receipt_with 1e3)"; do
  new_comment_case
  [[ "$answer" != *1e3* ]] || off_contract
  export COSTFLUENT_FAIL_ABOVE=1
  respond 1 201 "$answer"
  respond 2 200 '[]'
  respond 3 201 '{"id":9001}'
  run_script
  name="a receipt without planned totals ($(jq -c .planned <<<"$answer")) comments that they are unavailable, sets no output and warns that fail-above is not applied"
  if ended success 3 'warning: fail-above is not applied' \
    && [[ "$(comment_of 3 | sed -n 4p)" == "The planned totals are unavailable: Costfluent answered without them." ]] \
    && lacks monthly-change "$GITHUB_OUTPUT" && grep -qx 'estimate-id=est_01J9Z3Q4XKWD7VB2MF8N6Y' "$GITHUB_OUTPUT"; then
    pass "$name"
  else
    fail "$name" "status $status, $(calls) requests: $(tail -2 "$STUB_DIR/output")"
  fi
done

new_comment_case
respond 2 403 '{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest"}'
run_script
check "a GitHub 403 fails at once, naming pull-requests: write and GitHub's reason" \
  ended failure 2 'Resource not accessible by integration): commenting needs the job'"'"'s token to hold the pull-requests: write permission'
check "a GitHub 403 is not retried" [ ! -f "$STUB_DIR/sleeps" ]
check "a GitHub 403 prints neither token" lacks "$github_token" "$STUB_DIR/output"
check "a GitHub 403 still leaves the summary written" grep -qF "\`+560.64 USD\`" "$GITHUB_STEP_SUMMARY"

new_comment_case
for call in 2 3 4 5; do respond "$call" 502 '{"message":"Server Error"}'; done
run_script
check "a GitHub 5xx is retried, then fails naming the status" ended failure 5 'answered 502 after 4 attempts: Server Error'
check "a GitHub 5xx prints neither token" lacks "$github_token" "$STUB_DIR/output"

new_comment_case
respond 2 200 '[]'
respond 3 503 '{"message":"Service Unavailable"}'
run_script
check "a comment GitHub fails to create is not sent again, since it may have landed" \
  ended failure 3 "POST $github/issues/42/comments answered 503: Service Unavailable"

# The commit comes from the pull request: Markdown, HTML, a mention and a line break in it stay
# inside one code span, and a long one is cut inside it.
new_comment_case
export COSTFLUENT_COMMIT=$'`@acme/admins` [x](https://evil.example) <img src=x>\n@acme/owners'
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
check "a value from the pull request lands in one code span, so no Markdown, HTML or mention works" \
  [ "$(comment_of 3 | tail -1)" == "Estimate \`est_01J9Z3Q4XKWD7VB2MF8N6Y\`, commit \`\` \`@acme/admins\` [x](https://evil.example) <img src=x> @acme/owners \`\`, workspace \`wsp_8f3k2m4n5p6q7r8s9t0v1w\`." ]

new_comment_case
COSTFLUENT_COMMIT="$(printf '@acme/admins %.0s' $(seq 6000))"
export COSTFLUENT_COMMIT
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
long_value_cut() {
  local last
  last="$(comment_of 3 | tail -1)"
  [[ "$last" == "Estimate \`est_01J9Z3Q4XKWD7VB2MF8N6Y\`, commit \`$(printf '%s' "$COSTFLUENT_COMMIT" | head -c 253)...\`, workspace \`wsp_8f3k2m4n5p6q7r8s9t0v1w\`." ]] \
    && [[ "$(comment_of 3 | wc -c)" -lt 1000 ]]
}
check "a 72,000-character value is cut inside its code span, keeping the comment short" long_value_cut

# The GitHub token: masked, on curl's stdin only, and only in requests to GitHub; the API token only
# in requests to Costfluent.
new_comment_case
export GITHUB_ACTIONS=true
respond 2 200 '[]'
respond 3 201 '{"id":9001}'
run_script
check "the GitHub token is never on curl's command line" lacks "$github_token" "$STUB_DIR"/call-*.argv
check "the GitHub token reaches curl only in its config on stdin, for GitHub alone" \
  grep -qxF "header = \"Authorization: Bearer $github_token\"" "$STUB_DIR/call-2.stdin" "$STUB_DIR/call-3.stdin"
check "the GitHub token never goes to Costfluent" lacks "$github_token" "$STUB_DIR/call-1.stdin"
check "the API token never goes to GitHub" lacks "$token" "$STUB_DIR/call-2.stdin" "$STUB_DIR/call-3.stdin"
check "in GitHub Actions the GitHub token is masked and appears nowhere else" \
  [ "$(grep -cF -- "$github_token" "$STUB_DIR/output")" -eq 1 -a "$(sed -n 2p "$STUB_DIR/output")" == "::add-mask::$github_token" ]
check "neither token reaches the summary or the outputs" lacks "$github_token" "$GITHUB_STEP_SUMMARY" "$GITHUB_OUTPUT"

# refused_to_comment <name> <text> <variable=value>...: with comment on, the run stops before any
# request.
refused_to_comment() {
  local name="$1" text="$2"
  shift 2
  new_comment_case
  declare -gx "$@"
  run_script
  if ended failure 0 "$text" && lacks "$github_token" "$STUB_DIR/output"; then pass "$name"; else fail "$name" "status $status, $(calls) requests: $(head -2 "$STUB_DIR/output")"; fi
}
refused_to_comment "comment other than true or false is refused before any request" 'true or false' COSTFLUENT_COMMENT=yes
refused_to_comment "comment without a GitHub token is refused before any request" 'COSTFLUENT_GITHUB_TOKEN is required' COSTFLUENT_GITHUB_TOKEN=
refused_to_comment "a GitHub token holding a line break is refused before any request" 'holds a control character' \
  COSTFLUENT_GITHUB_TOKEN="$github_token"$'\nurl = "https://attacker.test"'
refused_to_comment "comment without GITHUB_API_URL is refused before any request" 'GITHUB_API_URL' GITHUB_API_URL=
refused_to_comment "a GITHUB_API_URL that is not https is refused before any request" 'GITHUB_API_URL' GITHUB_API_URL=http://api.github.com
refused_to_comment "a repository that is not owner/name is refused before any request" 'owner/name' COSTFLUENT_REPOSITORY=acme/infra/../x
refused_to_comment "a workspace id that would end the marker is refused before any request" 'workspace id' COSTFLUENT_WORKSPACE_ID='wsp_x -->'

# --- both modes: required inputs and step outputs ----------------------------------------------

for mode in estimate apply; do
  for variable in COSTFLUENT_API_TOKEN COSTFLUENT_WORKSPACE_ID COSTFLUENT_REPOSITORY; do
    if [[ "$mode" == apply ]]; then new_apply_case; else new_case; fi
    export "$variable="
    run_script
    check "$mode: an empty $variable is refused before any request" ended failure 0 "$variable is required"
  done
done

# An id holding a line break would write a second step output of the API's choosing.
for mode in estimate apply; do
  if [[ "$mode" == apply ]]; then new_apply_case; else new_case; fi
  export GITHUB_OUTPUT="$STUB_DIR/github-output"
  : >"$GITHUB_OUTPUT"
  respond 1 200 '{"id":"est_01J9Z3Q4XKWD7VB2MF8N6Y\nforged=yes"}'
  off_contract
  run_script
  if ended success 1 && [[ ! -s "$GITHUB_OUTPUT" ]]; then
    pass "$mode: an estimate id holding a line break is no step output"
  else
    fail "$mode: an estimate id holding a line break is no step output" "status $status, outputs: $(head -3 "$GITHUB_OUTPUT")"
  fi
done

# --- expected outputs: both programs on every fixture -------------------------------------------

# fixtures/expected/<input>.json is each program's output on that fixture, pretty-printed with
# sorted keys: an estimate document per Infracost fixture, one with its Terraform plan, and the
# apply output per plan with its state. The CLI runs the same programs under gojq against these
# files, so the Action and the CLI cannot drift apart. A refused input pins its message as
# {"error": ...}. WRITE_EXPECTED=1 rewrites them.
expected="$fixtures/expected"
expected_args=(--arg workspaceId wsp_8f3k2m4n5p6q7r8s9t0v1w --arg repository acme/infra --arg pullRequest 42
  --arg commit 9fceb02d0ae598e95dc970b74767f19372d61af8 --arg url https://github.com/acme/infra/pull/42
  --arg sourceVersion 0.10.41)
expected_names=()
# matches_expected <name>: $work/output.json against fixtures/expected/<name>.
matches_expected() {
  local file="$expected/$1"
  expected_names+=("$1")
  if [[ "${WRITE_EXPECTED:-}" == 1 ]]; then
    mkdir -p "$expected"
    jq -S . "$work/output.json" >"$file"
  fi
  if [[ ! -f "$file" ]]; then
    fail "$1 matches its expected output" "no $file; WRITE_EXPECTED=1 writes it"
  elif diff -u "$file" <(jq -S . "$work/output.json") >"$work/diff" 2>&1; then
    pass "$1 matches its expected output"
  else
    fail "$1 matches its expected output" "$(head -40 "$work/diff")"
  fi
}
# expect_estimate <name> <Infracost fixture> [Terraform plan fixture]
expect_estimate() {
  local plan_args=()
  [[ -z "${3:-}" ]] || plan_args=(--slurpfile terraformPlan "$fixtures/$3")
  if ! jq -f "$filter" "${expected_args[@]}" ${plan_args[@]+"${plan_args[@]}"} "$fixtures/$2" \
    >"$work/output.json" 2>"$work/err"; then
    sed 's/^jq: error (at [^)]*): //' "$work/err" | jq -Rs '{error: rtrimstr("\n")}' >"$work/output.json"
  fi
  matches_expected "$1"
}
for input in "$fixtures"/infracost-*.json; do
  expect_estimate "${input##*/}" "${input##*/}"
done
expect_estimate infracost-v2-diff-usage+terraform-plan.json infracost-v2-diff-usage.json terraform-plan.json
for plan in "$fixtures"/terraform*-plan.json; do
  jq -n -f "$apply_program" --slurpfile plan "$plan" --slurpfile state "${plan%-plan.json}-state.json" \
    --arg workspaceId wsp_8f3k2m4n5p6q7r8s9t0v1w --arg repository acme/infra --argjson pullRequest 42 \
    >"$work/output.json"
  matches_expected "${plan##*/}"
done
stale=""
for file in "$expected"/*.json; do
  [[ " ${expected_names[*]} " == *" ${file##*/} "* ]] || stale+="${file##*/} "
done
if [[ -z "$stale" ]]; then pass "every expected output has its input"; else fail "every expected output has its input" "$stale"; fi

# --- the Public API contract ------------------------------------------------------------------

# Each side's tests write their own bodies, so only this holds the action's two bodies to the
# schemas the API deserializes them with, and the receipts the stub answers with to the schema the
# API answers with: a rename on either side would otherwise pass both.
shape="$here/openapi-shape.py"
# holds_contract <name> <schema> <body>...: every body is a valid <schema>, and there is one.
holds_contract() {
  local name="$1" schema="$2" body broken=""
  shift 2
  [[ $# -gt 0 ]] || { fail "$name" "no body to check"; return; }
  for body in "$@"; do
    python3 "$shape" "$contract" "$schema" "$body" 2>>"$work/shape" || broken=yes
  done
  if [[ -z "$broken" ]]; then pass "$name"; else fail "$name" "$(head -10 "$work/shape")"; fi
  : >"$work/shape"
}
estimate_bodies=() apply_bodies=()
for body in "$work"/case-*/call-*.body; do
  if grep -qx 'https://api.costfluent.com/v1/cost-estimates/apply' "${body%.body}.argv"; then
    apply_bodies+=("$body")
  elif grep -qx 'https://api.costfluent.com/v1/cost-estimates' "${body%.body}.argv"; then
    estimate_bodies+=("$body")
  fi
done
holds_contract "every estimate posted is a SubmitCostEstimateRequest" SubmitCostEstimateRequest "${estimate_bodies[@]}"
holds_contract "every apply posted is an ApplyCostEstimateRequest" ApplyCostEstimateRequest "${apply_bodies[@]}"
# A stubbed receipt outside the contract would let the script read a field the API never sends.
receipts=()
for answer in "$work"/case-*/call-*.answer; do
  [[ ! -f "$(dirname "$answer")/off-contract" && "$(cat "${answer%.answer}.status")" == 2?? ]] || continue
  grep -qx 'https://api.costfluent.com/v1/cost-estimates\(/apply\)\{0,1\}' "${answer%.answer}.argv" || continue
  receipts+=("$answer")
done
holds_contract "every receipt the stub answers with is a CostEstimateReceiptResponse" CostEstimateReceiptResponse "${receipts[@]}"
check "the receipts checked include planned totals and an apply date" \
  bash -c 'grep -lq "\"planned\":{" "$@" && grep -lq "\"appliedOn\":\"" "$@"' _ "${receipts[@]}"
check "the applies posted include the AWS fixtures" grep -lq 'arn:aws:' "${apply_bodies[@]}"
check "the applies posted include the GCP fixture" grep -lq '//compute.googleapis.com/' "${apply_bodies[@]}"
holds_contract "every conversion, v0.10 and v2, with and without a plan, is a SubmitCostEstimateRequest" \
  SubmitCostEstimateRequest "$work/v010.json" "$work/v2.json" "$work/v2-usage.json" "$work/module.json" \
  "$work/optional.json" "$work/dedupe.json" "$work/gcp-out.json" "$work/precise-out.json" "$work/moved-module-out.json" \
  "$work/moved-to-unpriced-out.json"

# The check itself: the contract changing under an unchanged body fails it, naming the field
# (exit 1), and a schema it cannot read fully fails it too (exit 2), whatever the body carries.
# refuses_on <name> <jq edit of the contract> <exit> <text> [body, the v0.10 conversion by default]
refuses_on() {
  jq "$2" "$contract" >"$work/contract-edited.json"
  local code=0
  python3 "$shape" "$work/contract-edited.json" SubmitCostEstimateRequest "${5:-$work/v010.json}" 2>"$work/shape" || code=$?
  if [[ "$code" -eq "$3" ]] && grep -qF -- "$4" "$work/shape"; then pass "$1"; else fail "$1" "exit $code: $(head -3 "$work/shape")"; fi
}
jq '.tag = {key: "team", value: "web"}' "$work/v010.json" >"$work/tagged.json"
jq '.resources[0].change = "updated"' "$work/v010.json" >"$work/updated.json"
schemas=.components.schemas
refuses_on "a property the contract newly requires fails the check" \
  "$schemas.SubmitCostEstimateRequest.required += [\"costCenter\"]" 1 'lacks required costCenter'
refuses_on "a property the contract renames fails the check" \
  "$schemas.SubmitCostEstimateRequest.properties |= with_entries(if .key == \"pullRequest\" then .key = \"pullRequestNumber\" else . end)" \
  1 'pullRequest is sent but not in the contract'
refuses_on "a change value the contract renames fails the check" \
  "$schemas.CostEstimateChange[\"x-extensible-enum\"] |= map(if . == \"update\" then \"modify\" else . end)" \
  1 '"update" is not one of'
refuses_on "a change value outside the contract's list fails the check" . 1 '"updated" is not one of' "$work/updated.json"
refuses_on "a pattern beside a \$ref is checked" \
  "$schemas.SubmitCostEstimateRequest.properties.workspaceId.pattern = \"^nope\$\"" 1 'workspaceId "wsp_8f3k2m4n5p6q7r8s9t0v1w" does not match ^nope$'
refuses_on "a length beside a \$ref is checked" \
  "$schemas.SubmitCostEstimateRequest.properties.workspaceId.maxLength = 3" 1 'workspaceId is longer than 3'
refuses_on "an enum on an integer is checked" \
  "$schemas.SubmitCostEstimateRequest.properties.pullRequest.enum = [1]" 1 'pullRequest 42 is not one of [1]'
refuses_on "object keywords on a schema with no object type are not read past" \
  "$schemas.SubmitCostEstimateRequest.properties.tag.required = [\"x\"]" 2 'tag: required' "$work/tagged.json"
refuses_on "a format the check does not read is not read past" \
  "$schemas.SubmitCostEstimateRequest.properties.commit.format = \"date-time\"" 2 'format date-time' "$work/optional.json"
refuses_on "a decimal with no pattern beside it is not read past" \
  "$schemas.CostEstimateResourceRequest.properties.monthlyCostAfter |= del(.pattern)" 2 'format decimal'

if [[ "$failures" -gt 0 ]]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
