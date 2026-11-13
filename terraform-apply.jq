# Every address the plan creates or replaces, with the ids the state now gives it: the body of
# POST /v1/cost-estimates/apply, and the addresses the state holds no id for.
#
#   jq -n -f terraform-apply.jq \
#     --slurpfile plan plan.json --slurpfile state state.json \
#     --arg workspaceId wsp_... --arg repository acme/infra --argjson pullRequest 42
#
# plan is `terraform show -json` of the saved plan that was applied, state `terraform show -json`
# of the state after the apply. The API ignores an address its estimate does not hold as created
# or replaced, and Infracost leaves free and unsupported resources out of the estimate, so the
# plan's whole set is sent rather than guessed down. One the state holds no id for, such as a
# create a targeted apply skipped, is listed in missing and left out of the body.

# Copied from infracost-to-estimate.jq, which says why; the tests hold both to one behaviour.
def global_name:
  capture("^https://(?:www\\.|(?<host>[a-z0-9-]+)\\.)googleapis\\.com/(?:(?<service>[a-z0-9-]+)/)?[a-z0-9]+/(?<path>projects/[^?#]+)$")
  | ([.service, .host] | map(select(. != null and . != "")) | first) as $service
  | select($service != null)
  | "//\($service).googleapis.com/\(.path)";
def resource_ids:
  [((.self_link | strings | global_name), .id, .arn, .self_link)
   | select(type == "string" and . != "" and length <= 512)]
  | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)
  | .[0:3];

(reduce ($state[0].values.root_module // {} | recurse(.child_modules[]?) | .resources[]?
         | select(.mode == "managed")) as $resource
   ({}; .[$resource.address] = $resource)) as $resources
| [$plan[0].resource_changes // [] | .[]
   | select((.mode // "managed") == "managed" and .deposed == null)
   | select(.change.actions as $actions
            | $actions == ["create"] or $actions == ["delete", "create"] or $actions == ["create", "delete"])
   | {address, resourceIds: (($resources[.address].values // {}) | resource_ids)}]
| {body: {workspaceId: $workspaceId, repository: $repository, pullRequest: $pullRequest,
          resources: map(select(.resourceIds | length > 0))},
   missing: map(select(.resourceIds == []) | .address)}
