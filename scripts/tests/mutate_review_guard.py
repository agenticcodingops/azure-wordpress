#!/usr/bin/env python3
"""Put each known bug back into a copy of the review workflow and require a named guard test to catch it.

test_review_comment_guard.py fails if the guard regresses. This shows the test can still see each regression. Every
row edits a temporary copy of the workflow, with the test copied beside it the way the test expects to find it, and
nothing in the repository is written. It exits non-zero unless every row goes red.

Four things would otherwise read as coverage without being any:

- A row whose anchor no longer appears the expected number of times changes nothing, so it reports NO-OP.
- A test that already fails on the unmutated workflow proves nothing, so it reports BAD-BASELINE.
- A run that crashes has not reached the assertion, so it reports MALFORMED. Two errors are not crashes: an
  AssertionError from the test's class setup, which is how the test reports a guard-writing step that fails, and a
  StopIteration from its review_block helper, which is how it reports a review step with no `with:` mapping.
- A run that skips the test reports SKIPPED, and that fails the harness on Linux, where CI runs it.

Standard library only.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "claude-code-review.yml"
TEST_FILE = "test_review_comment_guard.py"
BS = chr(92)  # a backslash, built here so no editor or shell layer can halve it

WIRING = "test_review_comment_guard.WorkflowWiringTests."
DECIDE = "test_review_comment_guard.GuardDecisionTests."
FUZZ = "test_review_comment_guard.BashDifferentialTests."
HOOK_ARGS = "' ${{ github.event.pull_request.number }} ${{ github.repository }} '"
SUMMARY_STEP = '      - name: Clear the review summary path\n        run: rm -rf -- "$GITHUB_WORKSPACE/.review-summary.md"\n'


def replace_all(pattern, replacement):
    return lambda text: re.sub(pattern, lambda _match: replacement, text)


def fixed_context(text):
    return re.sub(r"ctx\.repo\b", '"o/r"', re.sub(r"ctx\.pr\b", '"48"', text))


def cleanup_before_checkout(text):
    if SUMMARY_STEP not in text:
        return text
    return text.replace(SUMMARY_STEP, "").replace("      - name: Checkout repository\n", SUMMARY_STEP + "\n      - name: Checkout repository\n")


# (id, anchor, replacement, test). An anchor must appear exactly once. A row with no anchor gives a function of the text.
ROWS = [
    # The two parser differentials review found, and the check that stops a string hiding a second line.
    ("backslash-in-quotes", "$`" + BS + "x5c!", "$`!", FUZZ + "test_the_reported_payloads_really_make_two_calls_in_bash"),
    ("hash-in-a-word", "[A-Za-z0-9_." + BS + "/:=,@%+-]+", "[A-Za-z0-9_." + BS + "/:=,@%+#-]+", DECIDE + "test_bash_commands"),
    ("line-breaks-allowed", "!/[" + BS + "x00-" + BS + "x1f" + BS + "x7f]/.test(command) && ", "", DECIDE + "test_bash_commands"),
    # The decision.
    ("filter-on-one-command", "if (FILTER.test(", 'if (command.startsWith("gh pr view ") && FILTER.test(', DECIDE + "test_formatting_flags_are_refused_on_every_allowed_read_command"),
    ("repo-written-in", None, replace_all(r"ctx\.repo\b", '"o/r"'), DECIDE + "test_each_review_context_accepts_only_its_own_comments"),
    ("context-written-in", None, fixed_context, DECIDE + "test_each_review_context_accepts_only_its_own_comments"),
    ("any-skill", "PLUGIN_COMMANDS.includes(input.skill) ? null :", "true ? null :", DECIDE + "test_other_shell_tools_and_unknown_tools"),
    ("default-allow", 'if (!SHELL_TOOLS.includes(tool)) return "the review may not use the " + tool + " tool.";', "if (!SHELL_TOOLS.includes(tool)) return null;", DECIDE + "test_other_shell_tools_and_unknown_tools"),
    ("shell-tools-narrowed", 'const SHELL_TOOLS = ["Bash", "Monitor", "PowerShell"];', 'const SHELL_TOOLS = ["Bash"];', DECIDE + "test_other_shell_tools_and_unknown_tools"),
    ("first-path-only", "targets.length > 0 && targets.every(", "targets.length > 0 && targets.some(", DECIDE + "test_file_tools"),
    ("write-with-no-path", "targets.length > 0 && targets.every(", "targets.every(", DECIDE + "test_file_tools"),
    # The hook's wiring.
    ("fail-open", "review-comment-guard.js" + HOOK_ARGS + "${{ github.workspace }}' || exit 2", "review-comment-guard.js" + HOOK_ARGS + "${{ github.workspace }}' || true", WIRING + "test_the_hook_fails_closed"),
    ("watchdog-too-long", '"the guard timed out."), 10000)', '"the guard timed out."), 100000)', WIRING + "test_the_hook_fails_closed"),
    ("background-hook", '"timeout": 30,', '"timeout": 30, "async": true,', WIRING + "test_the_matcher_and_the_guard_command_are_on_the_same_entry"),
    ("fixed-pull-request", HOOK_ARGS, "' 999 ${{ github.repository }} '", WIRING + "test_the_matcher_and_the_guard_command_are_on_the_same_entry"),
    ("fixed-repository", HOOK_ARGS, "' ${{ github.event.pull_request.number }} other/repo '", WIRING + "test_the_matcher_and_the_guard_command_are_on_the_same_entry"),
    ("after-the-tool", '"PreToolUse": [', '"PostToolUse": [', WIRING + "test_the_matcher_and_the_guard_command_are_on_the_same_entry"),
    ("matcher-on-another-entry", '"matcher": "*",', '"matcher": "*" },{ "hooks": [{ "type": "command", "timeout": 30, "command": "true" }] }, { "matcher": "*",', WIRING + "test_the_matcher_and_the_guard_command_are_on_the_same_entry"),
    ("narrow-matcher", '"matcher": "*"', '"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit"', WIRING + "test_the_hook_sees_every_tool"),
    ("kill-switch", '"hooks": {\n                "PreToolUse"', '"disableAllHooks": true,\n              "hooks": {\n                "PreToolUse"', WIRING + "test_nothing_in_the_settings_can_switch_hooks_off"),
    # Settings from the checkout.
    ("sources-removed", "            --setting-sources user\n", "", WIRING + "test_settings_from_the_checkout_cannot_turn_the_hook_off"),
    ("sources-widened", "            --setting-sources user\n", "            --setting-sources user,project,local\n", WIRING + "test_settings_from_the_checkout_cannot_turn_the_hook_off"),
    ("sources-in-a-comment", "            --setting-sources user\n", "          # --setting-sources user\n", WIRING + "test_settings_from_the_checkout_cannot_turn_the_hook_off"),
    ("settings-under-env", "        with:\n          claude_code_oauth_token", "        env:\n          claude_code_oauth_token", WIRING + "test_settings_from_the_checkout_cannot_turn_the_hook_off"),
    # Rules and steps around the review.
    ("bare-write", '--allowedTools "Edit(', '--allowedTools "Write,Edit(', WIRING + "test_the_review_cannot_write_anywhere_but_the_summary"),
    ("git-readable", '--disallowedTools "Read(./.git/**),', '--disallowedTools "', WIRING + "test_the_review_cannot_write_anywhere_but_the_summary"),
    ("cleanup-skipped", "      - name: Clear the review summary path\n", "      - name: Clear the review summary path\n        if: false\n", WIRING + "test_the_protecting_steps_cannot_be_skipped"),
    ("cleanup-before-checkout", None, cleanup_before_checkout, WIRING + "test_the_steps_run_in_the_order_that_protects_the_review"),
    ("guard-step-fails-early", 'cat > "$RUNNER_TEMP/review-comment-guard.js"', 'false\n          cat > "$RUNNER_TEMP/review-comment-guard.js"', DECIDE + "test_bash_commands"),
    ("guard-at-another-path", None, replace_all(r"\$RUNNER_TEMP/review-comment-guard\.js", "$RUNNER_TEMP/review-comment-guard-typo.js"), DECIDE + "test_bash_commands"),
    ("floating-pin", None, replace_all(r"anthropics/claude-code-action@[0-9a-f]{40}", "anthropics/claude-code-action@v1"), WIRING + "test_the_action_is_pinned_to_a_commit"),
]


def run_test(test_id, workflow_text, tmp):
    """Run one test against this workflow text, laid out the way the test looks for it."""
    root = Path(tmp, "tree")
    shutil.rmtree(root, ignore_errors=True)
    tests = root / "scripts" / "tests"
    tests.mkdir(parents=True)
    workflows = root / ".github" / "workflows"
    workflows.mkdir(parents=True)
    (workflows / WORKFLOW.name).write_text(workflow_text, encoding="utf-8", newline="\n")
    shutil.copyfile(HERE / TEST_FILE, tests / TEST_FILE)
    done = subprocess.run([sys.executable, "-B", "-m", "unittest", test_id], cwd=tests, capture_output=True, text=True, timeout=300, check=False)
    return done.returncode, done.stderr


def classify(code, output):
    last = output.strip().split("\n")[-1] if output.strip() else ""
    if code == 0:
        return "SKIPPED" if "skipped=" in last else "GREEN"
    if "failures=" in last:
        return "RED"
    if "errors=" in last and ("AssertionError:" in output or ("review_block" in output and "StopIteration" in output)):
        return "RED"
    return "MALFORMED"


def mutated(pristine, anchor, replacement):
    if anchor is None:
        return replacement(pristine)
    if pristine.count(anchor) != 1:
        return pristine
    return pristine.replace(anchor, replacement)


def main():
    pristine = WORKFLOW.read_text(encoding="utf-8").replace("\r\n", "\n")
    linux = sys.platform.startswith("linux")
    results = []
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for test_id in dict.fromkeys(row[3] for row in ROWS):
            outcome = classify(*run_test(test_id, pristine, tmp))
            if outcome != "GREEN" and (linux or outcome != "SKIPPED"):
                bad.append("BAD-BASELINE " + test_id + " is " + outcome)
        for name, anchor, replacement, test_id in ROWS:
            text = mutated(pristine, anchor, replacement)
            results.append((name, "NO-OP" if text == pristine else classify(*run_test(test_id, text, tmp))))
    for name, outcome in results:
        print(f"{outcome:10} {name}")
    for line in bad:
        print(line)
    red = sum(outcome == "RED" for _, outcome in results)
    skipped = sum(outcome == "SKIPPED" for _, outcome in results)
    wrong = [name for name, outcome in results if outcome not in ("RED", "SKIPPED")]
    print(f"VERDICT: {red}/{len(results)} red, {skipped} skipped, {len(wrong)} not red, {len(bad)} bad baselines")
    return 1 if wrong or bad or (linux and skipped) else 0


if __name__ == "__main__":
    sys.exit(main())
