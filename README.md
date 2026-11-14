# Costfluent Cost Estimate

A GitHub Action that posts each Terraform pull request's cost estimate from
[Infracost](https://github.com/infracost/infracost) to [Costfluent](https://costfluent.com), and
records when the change is applied, so Costfluent can show the estimated monthly change beside the
cost your cloud then bills for those resources, per pull request and per resource.

It runs at two points of your workflows:

- **`estimate`**, on the pull request: converts Infracost's JSON into Costfluent's estimate document
  and posts it. A later run on the same pull request replaces it, until the change is applied.
- **`apply`**, after `terraform apply`: posts the ids Terraform gave the resources the plan created
  or replaced, addressed to the pull request's estimate.

The Action is a shell script over `curl` and `jq`, both on GitHub-hosted runners, with no container
and no runtime to install: `action.yml`, `post-estimate.sh`, `infracost-to-estimate.jq` and
`terraform-apply.jq` are all it runs.

## Before you start

- A Costfluent API token that may submit cost estimates, and nothing else, kept in a repository or
  organization secret. The [guide](https://docs.costfluent.com/developers/cost-estimate-action) says
  how to create one.
- The id of the Costfluent workspace the estimates belong to, such as `wsp_8f3k2m`.
- Infracost running in the workflow and writing its diff as JSON (**Infracost's JSON** below).

## On the pull request

```yaml
name: cost estimate
on: pull_request

permissions:
  contents: read

jobs:
  estimate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
      # Run Infracost here, writing its diff JSON to /tmp/infracost.json.
      - name: Plan
        run: |
          terraform init -input=false
          terraform plan -input=false -out=tfplan
          terraform show -json tfplan > /tmp/plan.json
      - uses: costfluent/cost-estimate-action@<full commit SHA> # vX.Y.Z
        with:
          api-token: ${{ secrets.COSTFLUENT_API_TOKEN }}
          workspace-id: wsp_8f3k2m
          infracost-json: /tmp/infracost.json
          terraform-plan-json: /tmp/plan.json
```

The plan is optional, and it is what lets Costfluent measure each resource: from it the Action takes
each resource's change and, for those updated, replaced or deleted, the ids they have before the
change. Without it every line is posted without ids, and Costfluent cannot tell which billed costs
belong to it.

## Comment on the pull request

With `comment: true`, the Action keeps one comment on the pull request with the planned monthly
change Costfluent computed: the monthly cost before and after, the change, and how many resources
Infracost could not price, in the estimate's currency. Each push edits that comment rather than
adding one. With `fail-above`, the job fails when the planned monthly change is above that amount:

```yaml
name: cost estimate
on: pull_request

permissions:
  contents: read

jobs:
  estimate:
    # A fork's or Dependabot's pull request gets a token that cannot comment, and no secrets.
    if: github.event.pull_request.head.repo.fork == false && github.event.pull_request.user.login != 'dependabot[bot]'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
      # Run Infracost here, writing its diff JSON to /tmp/infracost.json.
      - name: Plan
        run: |
          terraform init -input=false
          terraform plan -input=false -out=tfplan
          terraform show -json tfplan > /tmp/plan.json
      - uses: costfluent/cost-estimate-action@<full commit SHA> # vX.Y.Z
        id: cost
        with:
          api-token: ${{ secrets.COSTFLUENT_API_TOKEN }}
          workspace-id: wsp_8f3k2m
          infracost-json: /tmp/infracost.json
          terraform-plan-json: /tmp/plan.json
          comment: true
          fail-above: 500
```

- The comment is written with the job's `GITHUB_TOKEN`, which needs `pull-requests: write`; give it
  to this job alone, keeping `contents: read`. The `if:` skips pull requests from forks and from
  Dependabot, whose tokens are read-only. Never use `pull_request_target` to get a writing token: it
  would run the pull request's Terraform with your secrets.
- Everyone who can read the pull request can read the comment, which in a public repository is
  everyone. It shows the planned costs and the estimate's, commit's and workspace's ids.
- The comment the Action keeps is the one a bot wrote that starts with a hidden marker naming the
  workspace, so two workspaces keep two comments, and a person's comment quoting the marker is
  never edited. It is looked for among the pull request's first 2,000 comments.
- A push that changes no priced resource posts nothing; it edits an existing comment to say so and
  creates none.
- The same Markdown is written to the job summary on every run, `comment` or not.
- `fail-above` is judged after the summary and the comment are written, so the failed job still
  shows them. It compares the exact decimals: a change equal to the amount passes, one above it fails
  the step with exit status 4. A negative change never fails it.
- A Costfluent API that answers without planned totals, as one older than them does, gives a
  comment saying they are unavailable, no `monthly-change` output, and a warning that `fail-above` is
  not applied: the step passes rather than failing every pull request on a change it cannot read.
- GitHub answering 403 fails the step with a message naming `pull-requests: write`; a 5xx is
  retried like the API's, and a comment GitHub fails to create is not sent again, because it may
  have been created.

The output `monthly-change` is the planned monthly change, such as `560.64` or `-120`, for a later
step to read as `steps.cost.outputs.monthly-change`.

## After the apply

On the push that applies the merged change, apply a saved plan and keep it and the state as JSON.
The pull request number is not in a push event, so look it up from the commit:

```yaml
name: apply
on:
  push:
    branches: [main]

permissions:
  contents: read
  pull-requests: read

jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
      - name: Apply
        run: |
          terraform init -input=false
          terraform plan -input=false -out=tfplan
          terraform show -json tfplan > /tmp/plan.json
          terraform apply -input=false tfplan
          terraform show -json > /tmp/state.json
      - name: Find pull request
        id: pull-request
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          number="$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq '.[0].number // empty')"
          echo "number=$number" >> "$GITHUB_OUTPUT"
      - if: steps.pull-request.outputs.number != ''
        uses: costfluent/cost-estimate-action@<full commit SHA> # vX.Y.Z
        with:
          mode: apply
          api-token: ${{ secrets.COSTFLUENT_API_TOKEN }}
          workspace-id: wsp_8f3k2m
          terraform-plan-json: /tmp/plan.json
          terraform-state-json: /tmp/state.json
          pull-request: ${{ steps.pull-request.outputs.number }}
```

Costfluent records the day of this call, in the workspace's time zone, as the apply date, which is
where it starts comparing the estimate with billed cost.

## Inputs

| Input | Mode | Default | What it is |
|---|---|---|---|
| `mode` | both | `estimate` | `estimate` or `apply` |
| `api-token` | both | | Costfluent API token that may submit cost estimates |
| `workspace-id` | both | | The workspace the estimate belongs to |
| `infracost-json` | estimate | | Path to Infracost's JSON |
| `terraform-plan-json` | both | | Path to `terraform show -json` of the saved plan; optional for `estimate`, required for `apply` |
| `terraform-state-json` | apply | | Path to `terraform show -json` after the apply |
| `repository` | both | `github.repository` | The pull request's repository |
| `pull-request` | both | the event's pull request | The pull request number |
| `commit` | estimate | the pull request's head commit | Kept with the estimate |
| `url` | estimate | the pull request's page | Kept with the estimate as a link; https only |
| `infracost-version` | estimate | | The Infracost version that wrote the JSON, kept with the estimate |
| `api-url` | both | `https://api.costfluent.com` | https only |
| `comment` | estimate | `false` | `true` keeps one comment on the pull request with the planned change |
| `github-token` | estimate | `github.token` | The GitHub token that writes the comment, with `pull-requests: write` |
| `fail-above` | estimate | | Fails the step with exit status 4 when the planned monthly change is above this amount, such as `500` |

The output `estimate-id` is the id of the estimate posted or applied, and `monthly-change` the
planned monthly change, empty when nothing was posted or the API answered without it.

## Infracost's JSON

The Action reads the two formats Infracost writes, and refuses any other document before it sends
anything, naming these two:

- **Infracost v0.10**, whose JSON carries `"version": "0.2"`: run
  `infracost breakdown --path . --format json --out-file /tmp/infracost-base.json` on the base
  branch, then `infracost diff --path . --compare-to /tmp/infracost-base.json --format json --out-file /tmp/infracost.json`
  on the pull request.
- **Infracost v2**, whose diff JSON carries no version: run `infracost scan --json > /tmp/infracost-base.json`
  on the base branch, then `infracost diff --compare-to /tmp/infracost-base.json --json > /tmp/infracost.json`
  on the pull request.

## How it behaves

- Each resource whose monthly cost changes is one line: its Terraform address, its type, its change
  (`create`, `update`, `replace` or `delete`) and its monthly cost before and after. With a plan, the
  change is the plan's action; without one, or where the plan changes nothing, it is read from
  where Infracost priced the resource: only before is a delete, only after a create, both an update.
  With a plan, a resource a `moved` block renames is one line at its new address, its cost before
  priced at the old address and its cost after at the new one, and has no line when that cost does
  not change; without one, a move is a delete and a create.
- Costs are posted as decimal strings with at most 8 decimal places, rounded half away from zero.
  They are rewritten as text, never through floating point, so no digit is lost.
- A cost Infracost could not price is posted as unknown (`null`), never as zero. Infracost v2
  writes a resource whose whole cost depends on usage it was not given as `"0"`; the Action posts
  both of its costs as unknown, because v2 does not say which side is unknown.
- An estimate holds one Terraform root. A document with changes in more than one Infracost project,
  or with a project Infracost failed to price, is refused, because the one plan and state given
  could match the wrong root's resources, and an unpriced project would read as all its resources
  deleted.
- The ids are a resource's `id`, `arn` and `self_link`, without repeats, at most three. Costfluent
  compares them with the resource ids in your billing data, ignoring case; a resource whose billed id
  is none of them shows as unmatched.
- Google's billing export names a resource by its global name, which the Action derives from the
  `self_link` and sends first, ahead of the raw `self_link`, which never matches:
  `https://www.googleapis.com/compute/v1/projects/p/zones/z/instances/vm` gives
  `//compute.googleapis.com/projects/p/zones/z/instances/vm`. A Google Cloud resource matches where
  the export's global name is that name. One the export names by number rather than by name, or
  whose `self_link` is outside `projects/`, such as a Cloud Storage bucket's, shows as unmatched.
- After the apply, every resource the plan created or replaced is sent with the ids the state gives
  it, addressed by workspace, repository and pull request. Costfluent keeps those its estimate holds
  and ignores the rest, such as the free and unsupported ones Infracost leaves out. A resource the
  state holds no id for, such as one a targeted apply skipped, is named in a warning and left out,
  and a plan creating or replacing more than 2,000 resources is refused, the most one apply takes.
- When no resource's cost changes, nothing is posted. An estimate posted earlier on the same pull
  request stays as it was.
- Once the estimate is applied, posting it again is refused, and the run fails. Applying it again
  with the same resources changes nothing; with other resources it is refused. When the workspace
  holds no estimate for the pull request, the apply step does nothing.
- A request answered 429 or 5xx, or not answered at all, is retried three times, waiting as long as
  `Retry-After` asks, up to 120 seconds, and otherwise 2, 4 and 8 seconds. Both posts are safe to
  repeat. Any other failure stops the run at once with the API's reason.
- The token is masked in the log and handed to `curl` on its standard input, so it is never on a
  command line, and only over https. The GitHub token is handled the same way and sent only to
  GitHub's API, `GITHUB_API_URL`; neither token goes to the other's host. From the plan and the state only addresses, types and ids
  leave the runner, beside Infracost's costs and the pull request's repository, number, commit and
  link.

## Other CI systems

`post-estimate.sh` runs anywhere with Bash, `curl` and `jq`, reading `COSTFLUENT_MODE`,
`COSTFLUENT_API_TOKEN`, `COSTFLUENT_WORKSPACE_ID`, `COSTFLUENT_REPOSITORY`,
`COSTFLUENT_PULL_REQUEST`, `COSTFLUENT_INFRACOST_JSON`, `COSTFLUENT_TERRAFORM_PLAN_JSON`,
`COSTFLUENT_TERRAFORM_STATE_JSON`, `COSTFLUENT_COMMIT`, `COSTFLUENT_URL`,
`COSTFLUENT_INFRACOST_VERSION`, `COSTFLUENT_BASE_URL`, `COSTFLUENT_COMMENT`,
`COSTFLUENT_GITHUB_TOKEN` and `COSTFLUENT_FAIL_ABOVE`, which match the inputs above. Commenting
needs `GITHUB_API_URL` too, which GitHub Actions sets. It exits 4 when the planned monthly change is
above `COSTFLUENT_FAIL_ABOVE`, and 1 on any other failure.

The conversion alone is one `jq` filter, which writes the body of `POST /v1/cost-estimates`:

```bash
jq -f infracost-to-estimate.jq \
  --arg workspaceId wsp_8f3k2m --arg repository acme/infra --arg pullRequest 42 \
  --slurpfile terraformPlan /tmp/plan.json \
  /tmp/infracost.json > /tmp/estimate.json
```

Post it only when `jq -e '.resources | length > 0' /tmp/estimate.json` succeeds. The
[API reference](https://docs.costfluent.com/api) describes the document and both calls.

## Versions

Releases are tagged `vX.Y.Z`, with no moving major tag. Reference a release by its full commit SHA,
with the tag in a comment as above, so the code your workflow runs cannot change under it.

## License

Apache License 2.0; see `LICENSE`. The test fixtures from Infracost are Apache-2.0 too, as
`tests/fixtures/NOTICE.md` records.
