# Test fixtures

Where each file in this folder comes from, and under which licence. The files from Infracost are
Infracost's own test data or Infracost's own code's output, so the tests read the JSON Infracost
really writes rather than JSON written to match the converter.

Both Infracost repositories are licensed under the Apache License 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>): `infracost/infracost` is Copyright 2021 Infracost
Inc., `infracost/cli` Copyright 2026 Infracost Inc. Neither carries a NOTICE file.
`googleinterns/terraform-cost-estimation`, an archived Google project whose test plans were made
with `terraform plan -out=tfplan` and `terraform show -json tfplan`, as its `testdata/README.md`
says, is licensed under the Apache License 2.0 too, and carries no NOTICE file.

| File | Source | Changes |
|---|---|---|
| `infracost-v0.10-diff.json` | [`infracost/infracost`](https://github.com/infracost/infracost) at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/diff_with_compare_to_format_json/diff_with_compare_to_format_json.golden` | The golden file's trailing `Err:` section, the test's captured standard error, removed so the file is JSON |
| `infracost-v0.10-new-module.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `internal/output/testdata/ToMarkdown_NoPreviousBreakdown.json` | None |
| `infracost-v0.10-unchanged.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/changes.json` | None |
| `infracost-v0.10-projects.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/comment_backoff_retry/infracost.json` | None |
| `infracost-v0.10-project-error.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/diff_with_compare_to_with_current_project_error/diff_with_compare_to_with_current_project_error.golden` | The trailing `Err:` section removed, as above |
| `infracost-v2-diff.json` | Written by [`infracost/cli`](https://github.com/infracost/cli) at `4534c809e0ef62bd8a3c2f67546e3573b7974e0c`: `format.Diff(past, current).ToJSON` in `internal/format/diff.go`, with `github.com/infracost/go-proto` v1.30.0 | Generated, not copied: `infracost/cli` keeps no diff JSON file. `past` and `current` are the two sides of `infracost-v0.10-diff.json` (`pastBreakdown` and `breakdown`), each resource with its name, its `resourceType`, its subresources and its cost components' name, unit, price, `monthlyQuantity` and `monthlyCost`, so the two fixtures hold the same change in each format |
| `infracost-v2-diff-usage.json` | Written by `infracost/cli` at `4534c809e0ef62bd8a3c2f67546e3573b7974e0c` as above | Generated from the inputs of `TestWriteDiff` in `internal/inspect/diff_test.go`, copied verbatim, whose text output is that test's golden file `internal/inspect/testdata/TestWriteDiff.golden` |
| `infracost-v2-summary.json` | `infracost/cli` at `4534c809e0ef62bd8a3c2f67546e3573b7974e0c`, `internal/inspect/testdata/TestSummaryJSON.golden` | None |
| `terraform-state.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/terraform_v0.14_state.json`, `terraform show -json` of a Terraform 0.14.11 state | None |
| `terraform-apply-plan.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/instance_with_attachment_before_deploy.json`, `terraform show -json` of a Terraform 1.0.11 plan | None |
| `terraform-apply-state.json` | `infracost/infracost` at `98c9711f3af183df31da951177076b37ee0552d2`, `cmd/infracost/testdata/instance_with_attachment_after_deploy.json`, the `prior_state` of that plan: the state the deploy of `terraform-apply-plan.json` left, in the shape `terraform show -json` gives a state | Extracted with `jq '.prior_state'`, which reindents it; no value changed |
| `terraform-gcp-plan.json` | [`googleinterns/terraform-cost-estimation`](https://github.com/googleinterns/terraform-cost-estimation) at `7bdeeebb39233511a4bdebaec0c0d6a34047609e`, `testdata/modified-compute-instance/tfplan.json`, `terraform show -json` of a Terraform 0.12.25 plan updating a `google_compute_instance` | None |
| `terraform-gcp-state.json` | The same file's `prior_state`: the instance's state before the update, in the shape `terraform show -json` gives a state | Extracted with `jq '.prior_state'`, which reindents it; no value changed |
| `terraform-plan.json` | Written for these tests, in the shape `terraform show -json` gives a saved plan (format 1.2) | Authored: no public plan file found carries a replace, a delete and a deposed object with cloud ids. Its addresses are those of `infracost-v2-diff-usage.json`; its ids follow AWS's formats, with the placeholder account `111111111111` Infracost's fixtures use |

`expected/` holds derived output, not source data: what `infracost-to-estimate.jq` and
`terraform-apply.jq` write for the fixtures above, which `tests/post-estimate.test.sh` regenerates
and compares, and rewrites under `WRITE_EXPECTED=1`. It carries the licence of the fixture it is
derived from.
