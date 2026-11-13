#!/usr/bin/env python3
"""Holds action.yml to the contract customers copy: its inputs, the variables post-estimate.sh reads,
the estimate-id and monthly-change outputs, the `with:` blocks the README documents, and the job
around a documented step that comments. post-estimate.test.sh sets the
variables itself, so a renamed, dropped or miswired input passes it. Offline, stdlib plus PyYAML.

    python3 tests/action-contract.test.py [page ...]

Each page named is checked the way the README is: every `with:` block under a
`uses: costfluent/cost-estimate-action@` line names only declared inputs, and every required one,
and a step with `comment: true` sits in a job that may write pull requests, reads contents only,
and skips the forks and Dependabot whose tokens cannot write.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ACTION = Path(__file__).resolve().parent.parent
MANIFEST = ACTION / "action.yml"
SCRIPT = ACTION / "post-estimate.sh"
README = ACTION / "README.md"
PAGES: list[Path] = []

# name: (required, default, variable). Moving an input, its default or its variable is a change to
# every customer's workflow, so it moves this table too, in the same diff.
PINNED_INPUTS: dict[str, tuple[bool, str | None, str]] = {
    "mode": (True, "estimate", "COSTFLUENT_MODE"),
    "api-token": (True, None, "COSTFLUENT_API_TOKEN"),
    "workspace-id": (True, None, "COSTFLUENT_WORKSPACE_ID"),
    "infracost-json": (False, None, "COSTFLUENT_INFRACOST_JSON"),
    "terraform-plan-json": (False, None, "COSTFLUENT_TERRAFORM_PLAN_JSON"),
    "terraform-state-json": (False, None, "COSTFLUENT_TERRAFORM_STATE_JSON"),
    "repository": (False, "${{ github.repository }}", "COSTFLUENT_REPOSITORY"),
    "pull-request": (False, "${{ github.event.pull_request.number }}", "COSTFLUENT_PULL_REQUEST"),
    "commit": (False, "${{ github.event.pull_request.head.sha || github.sha }}", "COSTFLUENT_COMMIT"),
    "url": (False, "${{ github.event.pull_request.html_url }}", "COSTFLUENT_URL"),
    "infracost-version": (False, None, "COSTFLUENT_INFRACOST_VERSION"),
    "api-url": (False, "https://api.costfluent.com", "COSTFLUENT_BASE_URL"),
    "comment": (False, "false", "COSTFLUENT_COMMENT"),
    "github-token": (False, "${{ github.token }}", "COSTFLUENT_GITHUB_TOKEN"),
    "fail-above": (False, None, "COSTFLUENT_FAIL_ABOVE"),
}
# name: the functions of post-estimate.sh that write it.
PINNED_OUTPUTS: dict[str, tuple[str, ...]] = {
    "estimate-id": ("estimate", "apply"),
    "monthly-change": ("estimate",),
}
# The job permissions a documented step with comment: true runs under, exactly.
COMMENT_PERMISSIONS = {"contents": "read", "pull-requests": "write"}
# What the job's if: must hold, so a fork's or Dependabot's read-only token never runs the step.
COMMENT_GUARD = "github.event.pull_request.head.repo.fork == false && github.event.pull_request.user.login != 'dependabot[bot]'"
USES = "costfluent/cost-estimate-action@"
VARIABLE = re.compile(r"COSTFLUENT_[A-Z_]+")


def manifest() -> dict:
    with MANIFEST.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def post_step(action: dict) -> dict:
    steps = [step for step in action["runs"]["steps"] if step.get("id") == "post"]
    if len(steps) != 1:
        raise AssertionError(f"expected one step with id: post, found {len(steps)}")
    return steps[0]


def script() -> str:
    return SCRIPT.read_text(encoding="utf-8")


def function_body(text: str, name: str) -> str:
    match = re.search(rf"^{name}\(\) \{{\n(.*?)^\}}", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"post-estimate.sh defines no {name}()")
    return match.group(1)


def action_steps(node: object) -> list[dict]:
    """Every mapping under node whose `uses` is this action, however deep the snippet nests it."""
    if isinstance(node, dict):
        found = [node] if str(node.get("uses", "")).startswith(USES) else []
        return found + [step for value in node.values() for step in action_steps(value)]
    if isinstance(node, list):
        return [step for item in node for step in action_steps(item)]
    return []


def yaml_blocks(text: str) -> list[tuple[int, object, int]]:
    """(line of the fence, the parsed document) for each fenced YAML block that uses the action."""
    blocks = []
    for fence in re.finditer(r"^([ \t]*)```ya?ml[^\n]*\n(.*?)^[ \t]*```", text, re.MULTILINE | re.DOTALL):
        body = fence.group(2)
        if USES not in body:
            continue
        prefix = len(fence.group(1))
        document = yaml.safe_load("\n".join(row[prefix:] for row in body.splitlines()))
        blocks.append((text.count("\n", 0, fence.start()) + 1, document, body.count(USES)))
    return blocks


def with_blocks(text: str) -> list[tuple[int, object]]:
    """(line of the fence, the step's `with`) for each step of the action in a fenced YAML block,
    parsed as YAML so a comment, quoting or a flow mapping cannot hide a key, and a step with no
    `with:` comes back as None rather than being passed over."""
    blocks = []
    for line, document, mentions in yaml_blocks(text):
        steps = action_steps(document)
        if len(steps) != mentions:
            raise AssertionError(f"line {line}: {mentions} mentions of the action, {len(steps)} steps parsed")
        blocks.extend((line, step.get("with")) for step in steps)
    return blocks


class ActionContract(unittest.TestCase):
    def test_every_input_maps_to_one_variable_the_script_reads(self) -> None:
        env = post_step(manifest())["env"]
        wired = {variable: f"${{{{ inputs.{name} }}}}" for name, (_, _, variable) in PINNED_INPUTS.items()}
        self.assertEqual(env, wired, "the post step's env must give each input to its own variable")
        self.assertEqual(set(VARIABLE.findall(script())), set(env), "post-estimate.sh must read exactly the variables the env sets")

    def test_inputs_are_pinned(self) -> None:
        inputs = manifest()["inputs"]
        self.assertEqual(list(inputs), list(PINNED_INPUTS))
        for name, (required, default, _) in PINNED_INPUTS.items():
            with self.subTest(input=name):
                self.assertIs(inputs[name].get("required"), required)
                self.assertEqual(inputs[name].get("default"), default)
                self.assertTrue(str(inputs[name].get("description", "")).strip(), "an input carries a description")

    def test_outputs_read_the_step_the_script_writes(self) -> None:
        action = manifest()
        self.assertEqual(list(action.get("outputs") or {}), list(PINNED_OUTPUTS))
        self.assertEqual(action["runs"]["using"], "composite")
        self.assertEqual(post_step(action)["run"].strip(), 'bash "$GITHUB_ACTION_PATH/post-estimate.sh"')
        text = script()
        for name, functions in PINNED_OUTPUTS.items():
            self.assertEqual(action["outputs"][name]["value"], f"${{{{ steps.post.outputs.{name} }}}}")
            self.assertTrue(str(action["outputs"][name].get("description", "")).strip(), "an output carries a description")
            for function in functions:
                with self.subTest(output=name, function=function):
                    self.assertIn(f"write_output {name} ", function_body(text, function))

    def test_documented_with_keys_are_inputs(self) -> None:
        inputs = manifest()["inputs"]
        needed = {name for name, spec in inputs.items() if spec.get("required") and "default" not in spec}
        for page in (README, *PAGES):
            blocks = with_blocks(page.read_text(encoding="utf-8"))
            self.assertTrue(blocks, f"{page.name}: no fenced YAML step uses {USES}")
            for line, given in blocks:
                with self.subTest(page=str(page), line=line):
                    self.assertIsInstance(given, dict, "a step of the action without a with: mapping")
                    keys = set(given) if isinstance(given, dict) else set()
                    self.assertEqual(sorted(keys - set(inputs)), [], "keys the action does not declare")
                    self.assertEqual(sorted(needed - keys), [], "required inputs the block leaves out")

    def test_documented_comment_runs_where_its_token_may_write(self) -> None:
        commenting = 0
        for page in (README, *PAGES):
            for line, document, _ in yaml_blocks(page.read_text(encoding="utf-8")):
                jobs = document.get("jobs", {}) if isinstance(document, dict) else {}
                for name, job in jobs.items():
                    steps = [step for step in action_steps(job) if str((step.get("with") or {}).get("comment")).lower() == "true"]
                    if not steps:
                        continue
                    commenting += 1
                    with self.subTest(page=str(page), line=line, job=name):
                        self.assertNotIn("pull_request_target", str(document.get("on", document.get(True))))
                        self.assertEqual(job.get("permissions"), COMMENT_PERMISSIONS, "the job grants exactly these permissions")
                        self.assertEqual(job.get("if"), COMMENT_GUARD, "the job skips forks and Dependabot")
                        for step in steps:
                            self.assertIn("fail-above", step["with"], "the documented comment shows the threshold too")
        self.assertGreaterEqual(commenting, 1 + len(PAGES), "the README and each page document a job that comments")

    def test_readme_reference_matches_the_manifest(self) -> None:
        text = README.read_text(encoding="utf-8")
        table = re.findall(r"^\| `([a-z-]+)` \|", text, re.MULTILINE)
        self.assertEqual(table, list(manifest()["inputs"]), "the README's Inputs table lists every input, in order")
        for name in PINNED_OUTPUTS:
            self.assertIn(f"`{name}`", text.split("## Inputs", 1)[1].split("\n## ", 1)[0], "the README names every output")
        other_ci = text.split("## Other CI systems", 1)[1].split("\n## ", 1)[0]
        documented = set(VARIABLE.findall(other_ci.split("```", 1)[0]))
        self.assertEqual(documented, set(VARIABLE.findall(script())), "the README names every variable the script reads")


if __name__ == "__main__":
    PAGES.extend(Path(arg) for arg in sys.argv[1:])
    unittest.main(argv=sys.argv[:1])
