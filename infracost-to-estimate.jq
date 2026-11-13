# Converts Infracost's JSON into a Costfluent cost estimate document, the body of
# POST /v1/cost-estimates.
#
# Reads either of the two formats Infracost writes:
#   - Infracost v0.10 JSON, "version": "0.2" (`infracost diff --format json`);
#   - Infracost v2 diff JSON, which carries no version field (`infracost diff --json`).
# Anything else is refused, so a format Infracost adds later fails here instead of posting a wrong
# estimate.
#
#   jq -f infracost-to-estimate.jq \
#     --arg workspaceId wsp_... --arg repository acme/infra --arg pullRequest 42 \
#     [--arg commit <sha>] [--arg url https://...] [--arg sourceVersion 0.10.41] \
#     [--slurpfile terraformPlan plan.json] \
#     infracost.json
#
# terraformPlan is `terraform show -json` of the saved plan. With it, each line's change is the
# plan's action, and an updated, replaced or deleted line carries the resource's ids before the
# change (`id`, `arn`, `self_link`), which is what Costfluent measures the line's actual cost by.
# A resource the plan moved (`previous_address`) is one line at its new address, its cost before
# priced at the old one. Without the plan, the change is read from the two sides Infracost priced,
# a move is a delete and a create, and no line carries ids.

def fail($message): error("infracost-to-estimate: " + $message);

def formats:
  "Infracost v0.10 JSON (\"version\": \"0.2\", from `infracost diff --format json`) and Infracost v2 diff JSON (`infracost diff --json`)";

def named($name): ($ARGS.named[$name] // null) | if . == "" then null else . end;

def zeros($count): [range(0; $count) | "0"] | join("");

# A string of digits plus one, as text.
def increment:
  capture("^(?<head>[0-9]*?)(?<last>[0-8]?)(?<nines>9*)$")
  | .head
    + (if (.last // "") == "" then "1" else ((.last | tonumber) + 1 | tostring) end)
    + ((.nines // "") | gsub("9"; "0"));

# A cost as Infracost wrote it (a decimal string, or a number) to the contract's decimal string:
# at most 8 places, rounded half away from zero, no exponent. It is rewritten as text, never
# parsed into a floating-point number, so no digit is lost. null stays null: Infracost could not
# price it, which is not zero.
def decimal($where):
  if . == null then null
  elif type == "number" then tostring | decimal($where)
  elif type != "string" then fail("\($where): a cost is a decimal string or null, not \(type)")
  else
    . as $text
    | (capture("^(?<sign>[-+]?)(?<int>[0-9]*)(?:\\.(?<frac>[0-9]*))?(?:[eE](?<exp>[-+]?[0-9]{1,3}))?$")
       // fail("\($where): \($text | tojson) is not a decimal number"))
    | (.int // "") as $int
    | (.frac // "") as $frac
    | if ($int + $frac) == "" then fail("\($where): \($text | tojson) is not a decimal number") else . end
    | ((.exp // "0") | ltrimstr("+") | tonumber) as $exp
    | ($int + $frac) as $digits
    | (($int | length) + $exp) as $point
    | (if $point <= 0 then ["0", zeros(0 - $point) + $digits]
       elif $point >= ($digits | length) then [$digits + zeros($point - ($digits | length)), ""]
       else [$digits[0:$point], $digits[$point:]]
       end) as [$whole, $fraction]
    | (if ($fraction | length) <= 8 then [$whole, $fraction]
       else
         ($whole + $fraction[0:8]) as $kept
         | (if $fraction[8:9] >= "5" then $kept | increment else $kept end) as $rounded
         | [$rounded[0:(($rounded | length) - 8)], $rounded[-8:]]
       end) as [$whole, $fraction]
    # No look-ahead: the CLI runs this program under gojq, whose RE2 regexes have no look-around.
    | ($whole | sub("^0+(?<digit>[0-9])"; "\(.digit)")) as $whole
    | ($fraction | sub("0+$"; "")) as $fraction
    | (if $whole == "" then "0" else $whole end) as $whole
    | (if ($whole + $fraction | test("[1-9]")) and .sign == "-" then "-" else "" end)
      + $whole
      + (if $fraction == "" then "" else "." + $fraction end)
  end;

# The resource type from a Terraform address, for a line Infracost wrote without one:
# `module.db.aws_db_instance.this[0]` is an `aws_db_instance`.
def address_type:
  (capture("^(?:.*\\.)?(?<type>[A-Za-z_][A-Za-z0-9_-]*)\\.[A-Za-z_][A-Za-z0-9_-]*(?:\\[.*\\])?$") | .type)
  // null;

# A Google Cloud resource's global name, which its billing data names it by, from its self_link:
# https://www.googleapis.com/compute/v1/projects/p/zones/z/instances/vm and
# https://compute.googleapis.com/compute/v1/projects/... are
# //compute.googleapis.com/projects/p/zones/z/instances/vm. A self_link outside projects/, such as a
# bucket's, gives none. terraform-apply.jq holds a copy for the apply.
def global_name:
  capture("^https://(?:www\\.|(?<host>[a-z0-9-]+)\\.)googleapis\\.com/(?:(?<service>[a-z0-9-]+)/)?[a-z0-9]+/(?<path>projects/[^?#]+)$")
  | ([.service, .host] | map(select(. != null and . != "")) | first) as $service
  | select($service != null)
  | "//\($service).googleapis.com/\(.path)";

# A resource's ids as Terraform recorded them, the global name its self_link gives first, since the
# raw self_link never matches billing data; without repeats and at most three. The API refuses an
# id over 512 characters, so one is left out rather than failing the post.
def resource_ids:
  [((.self_link | strings | global_name), .id, .arn, .self_link)
   | select(type == "string" and . != "" and length <= 512)]
  | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)
  | .[0:3];

# Infracost v0.10, "version": "0.2": every project's past and current breakdown, compared by
# address. A resource on one side only is created or deleted; one on both whose cost differs is
# updated. A project Infracost could not price has an empty side, which would read as every
# resource deleted or created, so it is refused.
def v010_projects:
  [ .projects // [] | .[]
    | [(.metadata.errors // [])[] | select(.isError != false)] as $errors
    | if ($errors | length) > 0 then
        fail("project \(.name | tojson) failed in Infracost: \($errors[0].message // "no message"); fix it and run Infracost again")
      else . end
    | ((.pastBreakdown // {}).resources // []) as $past
    | ((.breakdown // {}).resources // []) as $current
    | (reduce $past[] as $r ({}; .[$r.name] = $r)) as $before
    | (reduce $current[] as $r ({}; .[$r.name] = $r)) as $after
    | { project: .name,
        lines: [ ($past + $current | map(.name) | unique)[] as $address
          | $before[$address] as $was
          | $after[$address] as $is
          | { address: $address,
              type: ($is.resourceType // $was.resourceType),
              presence: (if $was == null then "create" elif $is == null then "delete" else "update" end),
              before: ($was.monthlyCost | decimal($address)),
              after: ($is.monthlyCost | decimal($address)) }
          | select(.presence != "update" or .before != .after) ] } ];

# Infracost v2's diff lists only the resources that changed. A resource whose cost depends on usage
# Infracost was not given carries a cost of "0" beside cost_depends_on_usage; it is unknown, not
# free, and v2 does not say which side it is unknown on, so both are null.
def v2_projects:
  [ .projects // [] | .[]
    | { project: .project_name,
        lines: [ .resources // [] | .[]
          | .name as $address
          | (.cost_depends_on_usage == true) as $unknown
          | { address: $address,
              type: .type,
              presence: ({added: "create", removed: "delete", changed: "update"}[.op]
                         // fail("resource \($address | tojson) has an op Infracost v2 does not write: \(.op | tojson)")),
              before: (if $unknown then null else .past_monthly_cost | decimal($address) end),
              after: (if $unknown then null else .monthly_cost | decimal($address) end) } ] } ];

def plan_change:
  if . == ["create"] then "create"
  elif . == ["update"] then "update"
  elif . == ["delete"] then "delete"
  elif . == ["delete", "create"] or . == ["create", "delete"] then "replace"
  else null
  end;

(named("terraformPlan") | if type == "array" then .[0] else . end) as $plan
| if $plan != null and (($plan | type) != "object" or ($plan | has("resource_changes") or has("planned_values") | not)) then
    fail("terraformPlan is not `terraform show -json` of a saved plan")
  else . end
| (reduce (($plan // {}).resource_changes // [] | .[] | select((.mode // "managed") == "managed" and .deposed == null)) as $change
     ({}; .[$change.address] = $change)) as $changes

# Only an absent currency is Infracost's default USD: `//` would also default an explicit null or
# false, which the ISO 4217 check below must refuse instead.
| if type != "object" then fail("the input is not Infracost JSON; this reads \(formats)")
  elif .version == "0.2" and (.projects | type) == "array" then {currency: (if has("currency") then .currency else "USD" end), projects: v010_projects}
  elif (has("version") | not) and has("diff_total_monthly_cost") and ((.projects // []) | type) == "array"
       and all(.projects // [] | .[]; type == "object" and has("project_name") and has("op")) then
    {currency: (if has("currency") then .currency else "USD" end), projects: v2_projects}
  else fail("the input is not Infracost JSON this reads, which is \(formats)")
  end
| .currency as $currency
| if ($currency | type) != "string" or ($currency | test("^[A-Z]{3}$") | not) then
    fail("the currency \($currency | tojson) is not an ISO 4217 code")
  else . end
| [.projects[] | select(.lines | length > 0)] as $changed
| if ($changed | length) > 1 then
    fail("changes are in more than one Infracost project (\($changed | map(.project | tojson) | join(", "))); an estimate holds one Terraform root, so run Infracost on the root this pull request changes")
  else . end
| ($changed[0].lines // []) as $lines

# Infracost compares the base and the pull request by address, so a resource a `moved` block
# renames reads as a delete at its old address and a create at its new one. The plan's
# previous_address says it is one resource that keeps its ids; left as two lines, neither could
# ever be measured, the create having no ids and the old address no change to take them from.
| (reduce ($changes[] | select(.previous_address != null and .previous_address != .address)) as $change
     ({}; .[$change.previous_address] = $change.address)) as $movedTo
| (reduce $lines[] as $line ({}; .[$line.address] = $line)) as $priced
| [ $lines[]
    | $movedTo[.address] as $to
    | ($changes[.address].previous_address // null) as $from
    | if $to != null then
        # v2 writes a removed resource's cost after as 0. That is the old address's; Infracost did
        # not price the new one, so the cost after is unknown.
        select($priced[$to] == null)
        | .address = $to | .after = null | .presence = "update" | select(.before != .after)
      elif $from != null and $from != .address and $priced[$from] != null then
        .before = $priced[$from].before | .type = (.type // $priced[$from].type) | .presence = "update"
        | select(.before != .after)
      elif $from != null and $from != .address then
        # v2 writes an added resource's cost before as 0. Infracost did not price the old address,
        # so the cost before is unknown.
        .before = null
      else . end ]
  as $lines

| (named("pullRequest")) as $pullRequest
| { workspaceId: (named("workspaceId") // fail("workspaceId is required")),
    repository: (named("repository") // fail("repository is required")),
    pullRequest: (if ($pullRequest | type) == "number" and $pullRequest >= 1 and ($pullRequest | floor) == $pullRequest then $pullRequest
                  elif ($pullRequest | type) == "string" and ($pullRequest | test("^[1-9][0-9]{0,9}$")) then $pullRequest | tonumber
                  else fail("pullRequest must be a pull request number, not \($pullRequest | tojson)")
                  end),
    source: "infracost",
    sourceVersion: named("sourceVersion"),
    commit: named("commit"),
    url: (named("url") | if . == null or test("^https://") then . else fail("url must start with https://") end),
    currency: $currency,
    resources: ([ $lines[]
      | $changes[.address] as $change
      | ((($change.change.actions // null) | plan_change) // .presence) as $kind
      | { address,
          type: (.type // $change.type // (.address | address_type)
                 // fail("cannot tell the resource type of \(.address | tojson)")),
          change: $kind,
          monthlyCostBefore: (if $kind == "create" then null else .before end),
          monthlyCostAfter: (if $kind == "delete" then null else .after end),
          resourceIds: (if $kind == "create" or $change == null then [] else ($change.change.before // {}) | resource_ids end) } ]
      | sort_by(.address)) }
| with_entries(select(.value != null))
