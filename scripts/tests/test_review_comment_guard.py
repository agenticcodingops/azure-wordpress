"""The review comment guard embedded in .github/workflows/claude-code-review.yml.

The review plugin's own frontmatter approves `gh pr comment` with any arguments, and the CLI honours that
grant in a non-interactive run, so the allow rules in the workflow do not bound that command. A PreToolUse
hook does. The hook script is written into the workflow as a heredoc, because the checkout the job runs in is
the pull request's head and must not supply code that gates the review.

These tests extract that heredoc, so the guard that ships is the guard that is tested. They run it the way the
CLI does (JSON on stdin, exit status 0 or 2) and, on Linux, check the property that matters against real bash:
every command the guard accepts must run as exactly one `gh` call with the arguments a POSIX shell parser
predicts. Two earlier versions failed that property (a backslash inside double quotes, and an unquoted `#`
that hid an opening quote), and a regex over shell text is easy to get wrong the same way again.

Standard library only, so it runs under pytest and under `python -m unittest discover`.
"""
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


def _find_workflow():
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / ".github" / "workflows" / "claude-code-review.yml"
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("claude-code-review.yml not found above " + str(here))


WORKFLOW = _find_workflow()
TEXT = WORKFLOW.read_text(encoding="utf-8").replace("\r\n", "\n")
IS_LINUX = sys.platform.startswith("linux")

PR, REPO, WS = "48", "o/r", "/ws"
SUMMARY = WS + "/.review-summary.md"
BS = chr(92)  # a backslash, built here so no editor or shell layer can halve it


def extract_guard(text):
    match = re.search(r"<<'GUARD'\n(.*?)\n( +)GUARD\n", text, re.S)
    if not match:
        raise AssertionError("the GUARD heredoc was not found in the workflow")
    indent = match.group(2)
    lines = match.group(1).split("\n")
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in lines) + "\n"


def indent_of(line):
    return len(line) - len(line.lstrip())


def review_block(key):
    """The text of a multi-line input (`key: |`) in the `with:` mapping of the review step, de-indented.

    This is what the action actually receives. The key must be a direct child of that step's `with:`: the same key
    under `env:`, in another step, or in a comment is not an input of the action and does not count."""
    step = step_text("Run Claude Code Review").split("\n")
    with_line = next(i for i, line in enumerate(step) if re.match(r"\s+with:\s*$", line))
    mapping = []
    for line in step[with_line + 1:]:
        if line.strip() and indent_of(line) <= indent_of(step[with_line]):
            break
        mapping.append(line)
    key_indent = min(indent_of(line) for line in mapping if line.strip() and not line.strip().startswith("#"))
    start = next(i for i, line in enumerate(mapping)
                 if indent_of(line) == key_indent and re.match(r"\s+" + re.escape(key) + r":\s*[|>][-+]?\s*$", line))
    body = []
    for line in mapping[start + 1:]:
        if line.strip() and indent_of(line) <= key_indent:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


def review_settings():
    """The review step's `settings` input, parsed: the JSON the action writes into the user settings."""
    # The workflow expressions are left as written: inside the JSON strings they are plain text, and the tests
    # compare them exactly so the guard cannot be wired to the wrong pull request, repository or path.
    return json.loads(review_block("settings"))


def review_arguments():
    """The review step's `claude_args`, one argument per line, as the action splits them. A comment is not an argument."""
    return [line.strip() for line in review_block("claude_args").split("\n") if line.strip() and not line.strip().startswith("#")]


def step_text(name):
    """The text of one workflow step, from its `- name:` line to the next step."""
    start = TEXT.index("- name: " + name)
    end = TEXT.find("\n      - name:", start + 1)
    return TEXT[start:end if end != -1 else len(TEXT)]


def step_env(name):
    """The `env:` mapping of one workflow step, as {name: value}. Comments are not entries."""
    lines = step_text(name).split("\n")
    start = next(i for i, line in enumerate(lines) if re.match(r"\s+env:\s*$", line))
    indent = len(lines[start]) - len(lines[start].lstrip())
    env = {}
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        if line.strip() and not line.strip().startswith("#"):
            key, value = line.strip().split(":", 1)
            env[key.strip()] = value.strip()
    return env


def step_run_block(name):
    """The shell script of a `run: |` step, de-indented the way the runner does."""
    lines = step_text(name).split("\n")
    start = next(i for i, line in enumerate(lines) if re.match(r"\s+run:\s*\|\s*$", line))
    indent = len(lines[start]) - len(lines[start].lstrip())
    body = []
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body)) + "\n"


# What the hook runs. The pull request number, repository and workspace are the ones of the run being reviewed.
EXPECTED_HOOK_COMMAND = (
    "node '${{ runner.temp }}/review-comment-guard.js' ${{ github.event.pull_request.number }} "
    "${{ github.repository }} '${{ github.workspace }}' || exit 2"
)


class GuardTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The guard runs on the Linux runner with node, and the differential needs a POSIX shell. On Linux a
        # missing tool is a failure, so CI cannot go green by skipping; elsewhere these tests skip.
        cls.bash = shutil.which("bash")  # the full path: on Windows a bare "bash" can resolve to WSL's
        if shutil.which("node") is None or cls.bash is None:
            if IS_LINUX:
                raise AssertionError("node and bash are required (the workflow runs the guard with node)")
            raise unittest.SkipTest("needs node and a POSIX bash")
        cls.tmp = tempfile.mkdtemp(prefix="review-guard-")
        # Run the workflow's own guard-writing step, as the runner does, with a temporary RUNNER_TEMP, and test the
        # file it produces at the path the hook invokes. Writing the extracted script to a name of the test's
        # choosing would not notice a step that installs it somewhere the hook does not look, which blocks every
        # tool call and leaves the review unable to do any work.
        runner_temp = os.path.join(cls.tmp, "runner-temp")
        os.makedirs(runner_temp)
        script = os.path.join(cls.tmp, "write-guard.sh")
        with open(script, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(step_run_block("Write the review comment guard"))
        done = subprocess.run(
            # -e as the runner runs a step with no shell set (bash -e {0}): a failing command stops the step, so a
            # setup command that breaks before the final syntax check cannot pass here and fail there.
            [cls.bash, "-e", script], env={**os.environ, "RUNNER_TEMP": Path(runner_temp).as_posix()},
            capture_output=True, text=True, timeout=60, check=False,
        )
        if done.returncode != 0:
            raise AssertionError("the guard-writing step failed: " + done.stderr[-400:])
        # The hook command names the script as <runner temp>/<name>; that is the file that must now exist.
        name = re.search(r"\{\{ runner\.temp \}\}/([\w.-]+)'", EXPECTED_HOOK_COMMAND).group(1)
        cls.guard = os.path.join(runner_temp, name)
        if not os.path.isfile(cls.guard):
            raise AssertionError("the guard-writing step did not create the file the hook invokes: " + name)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_guard(self, tool, tool_input, context=(PR, REPO, WS)):
        event = json.dumps({"tool_name": tool, "tool_input": tool_input})
        done = subprocess.run(
            ["node", self.guard, *context], input=event, capture_output=True, text=True, timeout=30, check=False
        )
        return done.returncode, done.stderr

    def verdict(self, tool, tool_input, context=(PR, REPO, WS)):
        code, _ = self.run_guard(tool, tool_input, context)
        self.assertIn(code, (0, 2), "the guard must exit 0 (allow) or 2 (block)")
        return "allow" if code == 0 else "block"


class WorkflowWiringTests(unittest.TestCase):
    def test_the_guard_is_valid_javascript(self):
        if shutil.which("node") is None:
            self.skipTest("node not installed")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "guard.js")
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(extract_guard(TEXT))
            done = subprocess.run(["node", "--check", path], capture_output=True, text=True, check=False)
            self.assertEqual(done.returncode, 0, done.stderr)

    def hook_entry(self):
        settings = review_settings()
        # PreToolUse runs before the call. A PostToolUse hook would run the guard after the command had run.
        self.assertEqual(set(settings.get("hooks", {})), {"PreToolUse"}, "the guard must be a PreToolUse hook")
        entries = settings["hooks"]["PreToolUse"]
        self.assertEqual(len(entries), 1, "expected exactly one PreToolUse entry")
        return entries[0]

    def test_the_hook_sees_every_tool(self):
        # Shell tools other than Bash (Monitor, PowerShell) reach a hook under a name that depends on the CLI
        # version, and a tool added later would not be on any list. The guard blocks what it does not know.
        self.assertEqual(self.hook_entry()["matcher"], "*")

    def test_the_matcher_and_the_guard_command_are_on_the_same_entry(self):
        entry = self.hook_entry()
        self.assertEqual(set(entry), {"matcher", "hooks"})
        hooks = entry["hooks"]
        self.assertEqual(len(hooks), 1)
        # Only these fields. A hook that runs in the background ("async", "asyncRewake") cannot block a tool call,
        # so the guard would stop enforcing anything; any field not named here is refused.
        self.assertEqual(set(hooks[0]), {"type", "command", "timeout"})
        self.assertEqual(hooks[0]["type"], "command")
        self.assertEqual(hooks[0]["command"], EXPECTED_HOOK_COMMAND)

    def test_settings_from_the_checkout_cannot_turn_the_hook_off(self):
        # A pull request can add a project settings file with {"disableAllHooks": true}; measured on CLI 2.1.316, a
        # project setting like that stopped a loaded hook. The action loads user, project and local settings
        # unless told otherwise, and the hook is installed in the user settings. The argument must be one of the
        # arguments the action receives (claude_args), not a line of text somewhere else in the file.
        self.assertIn("--setting-sources user", review_arguments())
        self.assertEqual([a for a in review_arguments() if a.startswith("--setting-sources")], ["--setting-sources user"])

    def test_nothing_in_the_settings_can_switch_hooks_off(self):
        # The settings the workflow itself writes are the user settings, so --setting-sources user does not protect
        # against a switch placed in them. Only these two keys are allowed at the root, and the environment may
        # carry only the one variable the workflow documents.
        settings = review_settings()
        self.assertLessEqual(set(settings), {"env", "hooks"}, "an unexpected settings key (for example disableAllHooks)")
        self.assertLessEqual(set(settings.get("env", {})), {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"})

    def test_the_hook_fails_closed(self):
        hook = self.hook_entry()["hooks"][0]
        self.assertTrue(hook["command"].endswith("|| exit 2"), "a crash or a missing node must block")
        watchdog = re.search(r"setTimeout\([^;]*?,\s*(\d+)\)", extract_guard(TEXT))
        self.assertIsNotNone(watchdog, "the guard has no watchdog")
        self.assertLess(int(watchdog.group(1)), int(hook["timeout"]) * 1000, "the watchdog must fire before the hook times out")

    def test_the_guard_step_comes_before_the_review_step(self):
        self.assertLess(TEXT.index("Write the review comment guard"), TEXT.index("id: claude-review"))

    def test_the_steps_run_in_the_order_that_protects_the_review(self):
        # The checkout can bring in a link at the summary path, so the cleanup must come after it; the guard must be
        # in place, and the cleanup done, before the review starts.
        order = [TEXT.index("- name: Checkout repository"), TEXT.index("- name: Clear the review summary path"),
                 TEXT.index("- name: Write the review comment guard"), TEXT.index("id: claude-review")]
        self.assertEqual(order, sorted(order), "expected checkout, cleanup, guard, then review")

    def test_the_review_cannot_write_anywhere_but_the_summary(self):
        # A bare Write allows every use of the tool, and a Write(path) rule is never matched.
        arguments = review_arguments()
        allowed = [a for a in arguments if a.startswith("--allowedTools")]
        denied = [a for a in arguments if a.startswith("--disallowedTools")]
        self.assertTrue(all(not re.search(r'(?<![A-Za-z(])Write[,"]', a) for a in allowed), "a bare Write allow")
        self.assertTrue(all("Write(" not in a for a in arguments), "a Write(path) rule is never matched; use Edit(path)")
        self.assertEqual(len(denied), 1)
        self.assertIn("Edit(/${{ runner.temp }}/**)", denied[0])
        self.assertIn("Edit(~/.claude/**)", denied[0])
        # Reads inside the working directory need no approval, and the action's token sits in .git/config, so this
        # deny is what keeps the review from copying it into the summary it is allowed to post.
        self.assertIn("Read(./.git/**)", denied[0])

    def test_search_tools_are_disallowed_as_whole_entries(self):
        denied = [a for a in review_arguments() if a.startswith("--disallowedTools")]
        self.assertEqual(len(denied), 1)
        entries = denied[0].removeprefix('--disallowedTools "').removesuffix('"').split(",")
        self.assertIn("Grep", entries)
        self.assertIn("Glob", entries)

    def test_the_protecting_steps_cannot_be_skipped(self):
        # A step with a condition or continue-on-error can be skipped or fail without stopping the job.
        for name in ("Clear the review summary path", "Write the review comment guard"):
            self.assertIsNone(re.search(r"(?m)^\s+(if|continue-on-error):", step_text(name)), name + " must always run")

    def test_the_summary_path_is_cleared_before_the_review(self):
        self.assertIn('rm -rf -- "$GITHUB_WORKSPACE/.review-summary.md"', step_text("Clear the review summary path"))
        self.assertLess(TEXT.index("Clear the review summary path"), TEXT.index("Write the review comment guard"))

    def test_the_action_token_cannot_push_or_write_issues(self):
        # The action merges these lines over contents, pull_requests and issues, all write, so a scope left out
        # stays write. The review only posts to the pull request, so the other two are read (#188).
        lines = [line.strip() for line in review_block("additional_permissions").split("\n") if line.strip()]
        scopes = dict(line.split(":", 1) for line in lines if not line.startswith("#"))
        scopes = {key.strip(): value.strip() for key, value in scopes.items()}
        self.assertEqual(scopes, {"contents": "read", "pull_requests": "write", "issues": "read"})

    def test_each_head_is_reviewed_once(self):
        # The plugin's step 1 stops once Claude has commented at all, so every head after the first went unreviewed.
        # A step outside the model reads the live head and skips the review when the app has already posted a summary
        # naming it; the prompt reviews that commit, anchors inline comments to it, re-checks the head before posting
        # and always posts the summary, so a re-run on the same commit posts nothing (#188).
        step = step_text("Find the head to review")
        self.assertIsNone(re.search(r"(?m)^\s+(if|continue-on-error):", step), "the head step must always run")
        self.assertRegex(step, r"(?m)^\s+id:\s*head\s*$")
        # Every step output the workflow reads must come from that id, or a renamed id would leave the review
        # step's condition unset and skip every review while the job stays green.
        self.assertEqual(set(re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs", TEXT)), {"head"})
        self.assertEqual(step_env("Find the head to review"), {
            "GH_TOKEN": "${{ github.token }}", "PR": "${{ github.event.pull_request.number }}", "REPO": "${{ github.repository }}"})
        # The head step runs first, and the checkout is the commit it chose, not the event's merge commit.
        self.assertLess(TEXT.index("- name: Find the head to review"), TEXT.index("- name: Checkout repository"))
        checkout = step_text("Checkout repository")
        self.assertEqual(re.findall(r"(?m)^\s+ref:\s*(.+?)\s*$", checkout), ["${{ steps.head.outputs.sha }}"])
        script = step_run_block("Find the head to review")
        self.assertTrue(script.startswith("set -euo pipefail\n"), "a failed read must fail the job")
        self.assertIn('select(.user.type == "Bot" and .user.login == "claude[bot]")', script)
        self.assertIn('(.body | split("\\n")[0] | rtrimstr("\\r")) == "Reviewed head: " + env.SHA', script)
        review_if = re.search(r"(?m)^\s+if:\s*(.+)$", step_text("Run Claude Code Review"))
        self.assertIsNotNone(review_if, "the review step must be skipped for a head that has a review")
        self.assertEqual(review_if.group(1).strip(), "steps.head.outputs.reviewed == 'false'")
        prompt = " ".join(review_block("prompt").split())
        head = "${{ steps.head.outputs.sha }}"
        self.assertIn("this run reviews commit " + head, prompt)
        self.assertNotIn("github.event.pull_request.head.sha", prompt, "the event SHA can be older than the head reviewed")
        self.assertIn('drop step 1\'s condition "Claude has already commented on this PR", and tell the step 1 agent so', prompt)
        self.assertIn("The diff of the reviewed commit is in ${{ runner.temp }}/review.diff", prompt)
        self.assertIn("Read the diff from that file with the Read tool, never with gh pr diff", prompt)
        # The diff is outside the checkout, so reading it needs an allow rule: one exact file, nothing wider.
        allowed = [a for a in review_arguments() if a.startswith("--allowedTools")]
        self.assertEqual(len(allowed), 1)
        entries = allowed[0].removeprefix('--allowedTools "').removesuffix('"').split(",")
        self.assertEqual([e for e in entries if e.startswith("Read")], ["Read(/${{ runner.temp }}/review.diff)"])
        self.assertIn('> "$RUNNER_TEMP/review.diff"', script)
        self.assertIn("Pass commit_id set to the reviewed SHA on every inline comment", prompt)
        self.assertIn("Always post exactly one summary comment", prompt)
        self.assertIn("Its first line is exactly `Reviewed head: " + head + "`", prompt)
        self.assertLess(prompt.index("REVIEWED HEAD"), prompt.index("POSTING RULES"))
        self.assertNotIn("get the full head commit SHA with", prompt, "a SHA read at an unspecified time can differ from the reviewed one")

    def test_the_action_is_pinned_to_a_commit(self):
        match = re.search(r"uses:\s*anthropics/claude-code-action@(\S+)", TEXT)
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1), r"^[0-9a-f]{40}$", "a tag can be moved; pin the action to a commit")

    def test_the_review_plugin_is_pinned_to_a_commit(self):
        # A marketplace URL resolves the plugin at a branch, so the command the guard and the POSTING RULES were
        # measured against could change under the action pin. The plugin comes from a commit the fetch step
        # checks, through a local marketplace that step writes, and that marketplace is the one the review uses.
        fetch = step_text("Fetch the pinned review plugin")
        pin = re.search(r"(?m)^\s+PLUGIN_COMMIT:\s*(\S+)\s*$", fetch)
        self.assertIsNotNone(pin, "the fetch step must name the plugin commit")
        self.assertRegex(pin.group(1), r"^[0-9a-f]{40}$", "pin the plugin to a full commit SHA")
        script = step_run_block("Fetch the pinned review plugin")
        self.assertIn('test "$(git -C "$market/source" rev-parse HEAD)" = "$PLUGIN_COMMIT"', script)
        self.assertIn('market="$RUNNER_TEMP/review-plugin"', script)
        manifest = re.search(r"<<'MARKET'\n(.*?)\nMARKET\n", script, re.S)
        self.assertIsNotNone(manifest, "the fetch step must write the marketplace manifest itself")
        market = json.loads(manifest.group(1))
        self.assertEqual([p["name"] for p in market["plugins"]], ["code-review"])
        self.assertEqual(market["plugins"][0]["source"], "./source/plugins/code-review")
        review = step_text("Run Claude Code Review")
        sources = re.findall(r"(?m)^\s+plugin_marketplaces:\s*(.*?)\s*$", review)
        self.assertEqual(sources, ["${{ runner.temp }}/review-plugin"], "the review must install from the pinned copy")
        plugins = re.findall(r"(?m)^\s+plugins:\s*'?(.*?)'?\s*$", review)
        self.assertEqual(plugins, ["code-review@" + market["name"]])
        # The command the guard lets the Skill tool run is named after the plugin, so the name must not change.
        self.assertIn('const PLUGIN_COMMANDS = ["code-review:code-review", "code-review"];', extract_guard(TEXT))
        self.assertIsNone(re.search(r"(?m)^\s+(if|continue-on-error):", fetch), "the fetch step must always run")
        self.assertLess(TEXT.index("- name: Fetch the pinned review plugin"), TEXT.index("id: claude-review"))


# [expected, tool, argument]  expected: "allow" or "block"
BASH = "Bash"
CASES = [
    # the three exact comment forms
    ["allow", BASH, "gh pr comment 48 --repo o/r --body-file " + SUMMARY],
    ["allow", BASH, "gh pr comment 48 --body-file " + SUMMARY],
    ["allow", BASH, "gh pr comment https://github.com/o/r/pull/48 --body-file " + SUMMARY],
    # other comment commands, in every spelling
    ["block", BASH, "gh pr comment 999 --repo o/r --body-file " + SUMMARY],
    ["block", BASH, "gh pr comment 48 --repo o/r --body-file .git/config"],
    ["block", BASH, "gh pr comment 48 --body hi"],
    ["block", BASH, "gh pr comm''ent 999 --body-file x"],
    ["block", BASH, "gh pr comm" + BS + "ent 999 --body-file x"],
    ["block", BASH, "g''h pr comment 999 --body-file x"],
    ["block", BASH, "gh  pr   comment 999 -F x"],
    ["block", BASH, "gh -R o/r pr comment 48 -F x"],
    ["block", BASH, "gh pr view 48 && gh pr comment 999 -F x"],
    # a backslash inside double quotes escapes the closing quote
    ["block", BASH, 'gh pr view 48 "' + BS + '" " ; gh pr comment 999 --body-file .git/config #"'],
    ["block", BASH, 'gh pr view 48 "a' + BS + '" ; id ; echo ' + BS + '""'],
    ["block", BASH, 'gh pr view 48 "' + BS + BS + '" ; id #"'],
    ["block", BASH, 'gh pr view 48 "a' + BS + 'b"'],
    # an unquoted # starts a comment and hides an opening quote
    ["block", BASH, "gh pr view 48 # '\ngh pr comment 999 --body-file .git/config\n#'"],
    ["block", BASH, "gh pr view 48 # '\r\ngh pr comment 999 --body-file .git/config\r\n#'"],
    ["block", BASH, "gh pr view 48 #x"],
    ["block", BASH, "gh pr view 48 x#y"],
    # line breaks and control characters, in and out of quotes
    ["block", BASH, "gh pr view 48 'a\nb'"],
    ["block", BASH, 'gh pr view 48 "a\nb"'],
    ["block", BASH, "gh pr view 48\ngh pr comment 999"],
    ["block", BASH, "gh pr view 48 'a\tb'"],
    ["block", BASH, "gh pr view 48 x\ry"],
    ["block", BASH, "gh pr view 48 x\x0by"],
    ["block", BASH, "gh pr view 48 x\x7fy"],
    # expansions, operators, redirects, globs, braces, unbalanced quotes
    ["block", BASH, "gh pr view 48; id"],
    ["block", BASH, "gh pr view 48 | head"],
    ["block", BASH, "gh pr diff 48 > out.txt"],
    ["block", BASH, "gh pr view 48 < in.txt"],
    ["block", BASH, "gh pr view 48 &"],
    ["block", BASH, "gh pr view $(id)"],
    ["block", BASH, "gh pr view `id`"],
    ["block", BASH, 'gh pr view "a$(id)"'],
    ["block", BASH, 'gh pr view "a`id`"'],
    ["block", BASH, 'gh pr view "a$HOME"'],
    ["block", BASH, 'gh pr view "a!b"'],
    ["block", BASH, "gh pr view $HOME"],
    ["block", BASH, "gh pr view ~"],
    ["block", BASH, "gh pr view *"],
    ["block", BASH, "gh pr view {1,2}"],
    ["block", BASH, "gh pr view [1]"],
    ["block", BASH, "gh pr view (1)"],
    ["block", BASH, "gh pr view 48 --json it's"],
    ["block", BASH, 'gh pr view 48 "unterminated'],
    ["block", BASH, 'gh pr view 48 --x="a b"'],
    ["block", BASH, 'gh pr view 48 a"b"c'],
    # flags that can read environment variables, in every spelling
    ["block", BASH, "gh pr view 48 --jq .x"],
    ["block", BASH, "gh pr view 48 --jq=.x"],
    ["block", BASH, 'gh pr view 48 "--jq" .x'],
    ["block", BASH, "gh pr view 48 '--jq' .x"],
    ["block", BASH, "gh pr view 48 -q .x"],
    ["block", BASH, "gh pr view 48 -qfoo"],
    ["block", BASH, "gh pr view 48 -t x"],
    ["block", BASH, "gh pr view 48 --template x"],
    ["block", BASH, "gh pr view 48 --template=x"],
    # other programs and other gh subcommands
    ["block", BASH, "gh api repos/o/r/issues -f body=x"],
    ["block", BASH, "gh issue comment 1 --body x"],
    ["block", BASH, "gh pr review 48 --approve"],
    ["block", BASH, "cat .git/config"],
    ["block", BASH, "git log"],
    ["block", BASH, "echo hi"],
    ["block", BASH, ""],
    # plain reads that must keep working
    ["allow", BASH, "gh pr view 48 --json headRefOid"],
    ["allow", BASH, "gh pr view 48 --json comments"],
    ["block", BASH, "gh pr view 48 --json comments --jq .comments"],
    ["allow", BASH, "gh pr view 48 --repo o/r --json state,isDraft,title,author,headRefOid,baseRefName,files,comments,reviews"],
    ["allow", BASH, "gh pr diff 48"],
    ["allow", BASH, "gh pr diff 48 --name-only"],
    ["allow", BASH, "gh pr view https://github.com/o/r/pull/48 --comments"],
    ["allow", BASH, "gh issue view 12"],
    ["allow", BASH, "gh issue list --state all --limit 20 --json number,title"],
    ["allow", BASH, "gh pr list --state all --limit 20 --json number,title"],
    ["allow", BASH, 'gh search code "review summary" --repo o/r'],
    ["allow", BASH, "gh search prs 'is:open #12 author:x' --limit 5"],
    ["allow", BASH, 'gh pr list --search "it' + "'" + 's a phrase"'],
    ["allow", BASH, "gh pr view 48 --comments"],
]

FILE_CASES = [
    ["allow", "Write", {"file_path": SUMMARY}],
    ["allow", "Edit", {"file_path": WS + "/./.review-summary.md"}],
    ["block", "Write", {"file_path": WS + "/other.md"}],
    ["block", "Write", {"file_path": WS + "/.git/config"}],
    ["block", "Edit", {"file_path": "/tmp/review-comment-guard.js"}],
    ["block", "MultiEdit", {"file_path": "/home/runner/.claude/settings.json"}],
    ["block", "NotebookEdit", {"notebook_path": WS + "/n.ipynb"}],
    ["block", "Write", {}],
    ["block", "Write", {"file_path": None}],
    ["block", "Write", {"file_path": 5}],
    # every path field that is present must be the summary file
    ["block", "NotebookEdit", {"file_path": SUMMARY, "notebook_path": WS + "/other.ipynb"}],
    ["block", "NotebookEdit", {"file_path": WS + "/other.ipynb", "notebook_path": SUMMARY}],
    ["block", "Write", {"file_path": SUMMARY, "notebook_path": "/tmp/x"}],
    ["allow", "NotebookEdit", {"notebook_path": SUMMARY}],
    ["allow", "NotebookEdit", {"file_path": SUMMARY, "notebook_path": SUMMARY}],
    # read-only tools are allowed only when the guard names them explicitly
    ["allow", "Read", {"file_path": "x"}],
    ["block", "Grep", {"pattern": "x", "path": WS + "/.git"}],
    ["block", "Grep", {"pattern": "x"}],
    ["block", "Glob", {"pattern": "**/.git/config"}],
    ["block", "Glob", {"pattern": "*", "path": "/runner/temp"}],
    ["allow", "mcp__github_inline_comment__create_inline_comment", {}],
]


PLAIN = "gh pr view 48 --json headRefOid"
OTHER_PR = "gh pr comment 999 --repo o/r --body-file " + SUMMARY
UNKNOWN_TOOLS = [
    "WebFetch", "WebSearch", "Skill", "SlashCommand", "CronCreate", "CronDelete", "EnterWorktree", "ExitWorktree",
    "RemoteTrigger", "SendMessage", "PushNotification", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
    "ListMcpResourcesTool", "ReadMcpResourceTool", "mcp__other__tool", "mcp__github_comment_server__update_claude_comment",
    "SomeToolAddedLater", "",
]
TOOL_CASES = (
    # shell tools other than Bash get the same grammar, whatever name the CLI reports for them
    [["allow", tool, {"command": PLAIN}] for tool in ("Monitor", "PowerShell")]
    + [["allow", tool, {"command": "gh pr comment 48 --body-file " + SUMMARY}] for tool in ("Monitor", "PowerShell")]
    + [["block", tool, {"command": OTHER_PR}] for tool in ("Monitor", "PowerShell")]
    + [["block", tool, {"command": "gh pr view 48; id"}] for tool in ("Monitor", "PowerShell")]
    + [["block", tool, {"command": "gh pr view 48 # '\ngh pr comment 999 --body-file x\n#'"}] for tool in ("Monitor", "PowerShell")]
    + [["block", tool, {}] for tool in ("Monitor", "PowerShell")]
    # a tool the guard has never heard of is blocked, even if it carries a command that looks harmless
    + [["block", tool, {"command": PLAIN}] for tool in UNKNOWN_TOOLS]
    + [["block", tool, {"command": OTHER_PR}] for tool in UNKNOWN_TOOLS]
    + [["block", None, {}]]
    # the review starts from the plugin's command, which some CLI versions run through the Skill tool; only that
    # command is allowed, by exact name, because a skill's body can carry its own allowed-tools
    + [["allow", "Skill", {"skill": "code-review:code-review", "args": "o/r/pull/48"}],
       ["allow", "Skill", {"skill": "code-review"}],
       ["block", "Skill", {"skill": "other:thing"}],
       ["block", "Skill", {"skill": "code-review:code-review-evil"}],
       ["block", "Skill", {"skill": "Code-Review:code-review"}],
       ["block", "Skill", {"skill": "../code-review"}],
       ["block", "Skill", {"skill": ["code-review"]}],
       ["block", "Skill", {"skill": None}],
       ["block", "Skill", {}]]
    # tools that run nothing and write nothing go on to the normal permission check
    + [["allow", tool, {}] for tool in ("Read", "LS", "Agent", "Task", "TaskCreate", "TaskGet", "TaskList",
                                       "TaskUpdate", "TaskOutput", "TaskStop", "BashOutput", "KillShell", "TodoWrite",
                                       "ToolSearch", "mcp__github_inline_comment__create_inline_comment")]
)


class GuardDecisionTests(GuardTestCase):
    def test_other_shell_tools_and_unknown_tools(self):
        failures = []
        for expected, tool, tool_input in TOOL_CASES:
            if self.verdict(tool, tool_input) != expected:
                failures.append((expected, tool, tool_input))
        self.assertEqual(failures, [])

    def test_formatting_flags_are_refused_on_every_allowed_read_command(self):
        # --jq and --template can read environment variables, and -q and -t are their short forms. The table above
        # tests them on one command; a filter applied to only some commands would pass it.
        heads = ["gh pr view 48", "gh pr diff 48", "gh pr list", "gh issue view 12", "gh issue list", "gh search code foo"]
        flags = ["--jq .x", "--jq=.x", "-q .x", "-qx", "-t x", "--template x", "--template=x", '"--jq" .x', "'-q' .x"]
        failures = []
        for head in heads:
            for flag in flags:
                command = head + " --json number " + flag
                if self.verdict(BASH, {"command": command}) != "block":
                    failures.append(command)
            if self.verdict(BASH, {"command": head + " --json number"}) != "allow":
                failures.append(head + " (plain form refused)")
        self.assertEqual(failures, [])

    def test_bash_commands(self):
        failures = []
        for expected, tool, command in CASES:
            if self.verdict(tool, {"command": command}) != expected:
                failures.append((expected, command))
        self.assertEqual(failures, [], "the guard decided differently from the table")

    def test_file_tools(self):
        failures = []
        for expected, tool, tool_input in FILE_CASES:
            if self.verdict(tool, tool_input) != expected:
                failures.append((expected, tool, tool_input))
        self.assertEqual(failures, [])

    def test_each_review_context_accepts_only_its_own_comments(self):
        # The cases above all use one pull request, repository and workspace, which cannot show that the guard
        # really uses the arguments it is started with (a guard with them written in would pass). Two contexts
        # that must each refuse the other's comment commands and summary file can.
        first = ("48", "o/r", "/ws")
        second = ("49", "other/repo", "/other/ws")

        def comments(pr, repo, ws):
            body = ws + "/.review-summary.md"
            return [
                "gh pr comment " + pr + " --repo " + repo + " --body-file " + body,
                "gh pr comment " + pr + " --body-file " + body,
                "gh pr comment https://github.com/" + repo + "/pull/" + pr + " --body-file " + body,
            ]

        failures = []
        for own, other in ((first, second), (second, first)):
            for command in comments(*own):
                if self.verdict(BASH, {"command": command}, own) != "allow":
                    failures.append(("own comment refused", own, command))
            for command in comments(*other):
                if self.verdict(BASH, {"command": command}, own) != "block":
                    failures.append(("other context's comment accepted", own, command))
            # right pull request with the other workspace's file, and right file with the other pull request
            mixed = ["gh pr comment " + own[0] + " --body-file " + other[2] + "/.review-summary.md",
                     "gh pr comment " + other[0] + " --body-file " + own[2] + "/.review-summary.md"]
            # the repository on its own: the right pull request and file, with only the repository swapped, in
            # both forms that name one (the contexts above change all three values together)
            body = own[2] + "/.review-summary.md"
            mixed += ["gh pr comment " + own[0] + " --repo " + other[1] + " --body-file " + body,
                      "gh pr comment https://github.com/" + other[1] + "/pull/" + own[0] + " --body-file " + body]
            for command in mixed:
                if self.verdict(BASH, {"command": command}, own) != "block":
                    failures.append(("mixed comment accepted", own, command))
            if self.verdict("Write", {"file_path": own[2] + "/.review-summary.md"}, own) != "allow":
                failures.append(("own summary write refused", own, None))
            if self.verdict("Write", {"file_path": other[2] + "/.review-summary.md"}, own) != "block":
                failures.append(("other context's summary write accepted", own, None))
        self.assertEqual(failures, [])

    def test_a_bash_call_without_a_command_is_blocked(self):
        self.assertEqual(self.verdict(BASH, {}), "block")

    def test_unreadable_input_is_blocked(self):
        done = subprocess.run(["node", self.guard, PR, REPO, WS], input="not json", capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 2)

    def test_missing_arguments_are_blocked(self):
        done = subprocess.run(["node", self.guard], input="{}", capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 2)

    def test_a_stalled_input_is_blocked_by_the_watchdog(self):
        # stdin is held open and never written to, so only the watchdog can end the process (at 10 seconds).
        # communicate() would close stdin and the guard would stop on the empty input instead.
        process = subprocess.Popen(["node", self.guard, PR, REPO, WS], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.wait(timeout=25)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            self.fail("the watchdog did not fire")
        err = process.stderr.read()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()
        self.assertEqual(process.returncode, 2)
        self.assertIn("timed out", err)


STUB = r"""set +H
gh() { printf 'GH'; for a in "$@"; do printf '\0%s' "$a"; done; printf '\n'; }
command_not_found_handle() { echo "NOTFOUND:$1"; return 127; }
"""

DRIVER = r"""
const { decide } = require(process.argv[2]);
const commands = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const ctx = { pr: '48', repo: 'o/r', ws: '/ws' };
process.stdout.write(JSON.stringify(commands.map((c) => decide('Bash', { command: c }, ctx) === null)));
"""

META = ["'", '"', BS, "#", ";", "&", "|", "<", ">", "$", "`", "(", ")", "{", "}", "*", "?", "[", "]", "~", "!",
        "\n", "\t", "\r", " ", "=", "%", "+", "@", ",", ":", ".", "/", "-"]
WORDS = ["a", "b", "x", "48", "--json", "headRefOid", "--repo", "o/r", "-L", "5", "--state", "all", "is:open",
         "--comments", "-R", "--name-only", "x=y", "a,b"]
SUBST = ["$(id)", "${x}", "$((1))", "`id`", "$x", "$'x'", '$"x"', "~/x", "*", "?", "[a]", "{a,b}", "a{b,c}",
         "<(x)", ">(x)", "!!", "&&", "||", ";;"]
HEADS = ["gh pr view ", "gh pr diff ", "gh pr list ", "gh issue view ", "gh issue list ", "gh search code "]


def generate(rng):
    def raw(n):
        return "".join(rng.choice(META) if rng.random() < 0.5 else rng.choice(["a", "b", "x", "1"]) for _ in range(n))

    def quoted():
        q = rng.choice(["'", '"'])
        inner = "".join(
            rng.choice(META) if rng.random() < 0.55 else rng.choice(["a", "b", "x", " "]) for _ in range(rng.randrange(8))
        )
        if rng.random() < 0.3:
            inner += rng.choice(SUBST)
        return q + inner + q

    def piece():
        r = rng.random()
        if r < 0.3:
            return rng.choice(WORDS)
        if r < 0.6:
            return quoted()
        if r < 0.75:
            return raw(1 + rng.randrange(4))
        if r < 0.85:
            return rng.choice(SUBST)
        return rng.choice(WORDS) + quoted()

    body = ""
    for _ in range(1 + rng.randrange(7)):
        body += piece() + (" " if rng.random() < 0.85 else "")
    return rng.choice(HEADS) + (body.rstrip() if rng.random() < 0.5 else body)


class BashDifferentialTests(GuardTestCase):
    """Whatever the guard accepts must be exactly one gh call in a real shell, with the predicted arguments."""

    def run_in_bash(self, command):
        script = os.path.join(self.tmp, "case.sh")
        with open(script, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(STUB + command + "\n")
        done = subprocess.run([self.bash, "--noprofile", "--norc", script], cwd=self.tmp, capture_output=True, text=True, timeout=20, check=False)
        return done.stdout, done.stderr

    def gh_calls(self, command):
        out, err = self.run_in_bash(command)
        lines = [line for line in out.split("\n") if line]
        return lines, err

    def test_the_cleanup_step_removes_a_link_planted_by_the_pull_request(self):
        # The exact comment command reads --body-file, so a summary path that is a link to .git/config would post
        # the job token's config. The step that runs before the review must remove it, link and all.
        match = re.search(r"(?m)^\s+run:\s*(.+)$", step_text("Clear the review summary path"))
        self.assertIsNotNone(match, "the cleanup step has no run line")
        workspace = os.path.join(self.tmp, "workspace")
        os.makedirs(os.path.join(workspace, ".git"))
        secret = os.path.join(workspace, ".git", "config")
        with open(secret, "w", encoding="utf-8") as handle:
            handle.write("[http]\n\textraheader = not-a-real-credential\n")
        planted = os.path.join(workspace, ".review-summary.md")
        try:
            os.symlink(secret, planted)
        except (OSError, NotImplementedError):
            self.skipTest("this machine cannot create symbolic links")
        done = subprocess.run(
            [self.bash, "-e", "-c", match.group(1)], env={**os.environ, "GITHUB_WORKSPACE": workspace},
            capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(os.path.lexists(planted), "the planted link survived the cleanup step")
        self.assertTrue(os.path.exists(secret), "the cleanup must remove the link, not what it points at")

    HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"
    BASE_SHA = "89abcdef0123456789abcdef0123456789abcdef"

    def run_head_step(self, head, comments, base=BASE_SHA, fail=""):
        """Run the workflow's "Find the head to review" script with a stub gh that answers from these values.

        The stub hands the step's own --jq filters to the real jq, so the filters that ship are the ones tested.
        `fail` names one gh call (pull, comments or compare) that exits non-zero. Returns the exit status, the
        step outputs, stderr, and the saved diff (None when the file was not written)."""
        if shutil.which("jq") is None:
            if IS_LINUX:
                raise AssertionError("jq is required to test the head step's filters")
            self.skipTest("needs jq")
        case = tempfile.mkdtemp(dir=self.tmp)
        bin_dir = os.path.join(case, "bin")
        temp = os.path.join(case, "runner-temp")
        os.makedirs(bin_dir)
        os.makedirs(temp)
        stub = os.path.join(bin_dir, "gh")
        with open(stub, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(
                "#!/usr/bin/env bash\n"
                'if [ "$#" = 4 ] && [ "$1 $2 $3" = "api repos/o/r/pulls/48 --jq" ]; then\n'
                '  [ "$STUB_FAIL" = pull ] && exit 1; exec jq -r "$4" "$STUB_PULL"; fi\n'
                'if [ "$#" = 5 ] && [ "$1 $2 $3 $4" = "api --paginate repos/o/r/issues/48/comments --jq" ]; then\n'
                '  [ "$STUB_FAIL" = comments ] && exit 1; exec jq -r "$5" "$STUB_COMMENTS"; fi\n'
                'if [ "$#" = 4 ] && [ "$1" = api ] && [ "$2" = -H ] && [ "$3" = "Accept: application/vnd.github.diff" ]; then\n'
                '  [ "$STUB_FAIL" = compare ] && exit 1; printf "diff of %s\\n" "$4"; exit 0; fi\n'
                'echo "unexpected gh call: $*" >&2; exit 99\n')
        os.chmod(stub, 0o700)  # owner only; it must be executable to be found on PATH
        pull_file = os.path.join(case, "pull.json")
        with open(pull_file, "w", encoding="utf-8", newline="\n") as handle:
            json.dump({"head": {"sha": head}, "base": {"sha": base}}, handle)
        comments_file = os.path.join(case, "comments.json")
        with open(comments_file, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(comments, handle)
        script = os.path.join(case, "step.sh")
        with open(script, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(step_run_block("Find the head to review"))
        output = os.path.join(case, "output")
        open(output, "w", encoding="utf-8").close()
        env = {**os.environ, "PATH": bin_dir + os.pathsep + os.environ.get("PATH", ""), "GITHUB_OUTPUT": output,
               "RUNNER_TEMP": temp, "PR": "48", "REPO": "o/r", "STUB_PULL": pull_file, "STUB_COMMENTS": comments_file,
               "STUB_FAIL": fail}
        done = subprocess.run([self.bash, "--noprofile", "--norc", script], env=env, capture_output=True, text=True, timeout=30, check=False)
        with open(output, encoding="utf-8") as handle:
            values = dict(line.split("=", 1) for line in handle.read().split("\n") if "=" in line)
        diff_path = os.path.join(temp, "review.diff")
        diff = Path(diff_path).read_text(encoding="utf-8") if os.path.exists(diff_path) else None
        return done.returncode, values, done.stderr, diff

    def test_the_head_step_skips_only_a_head_the_app_has_reviewed(self):
        sha = self.HEAD_SHA
        other = "fedcba9876543210fedcba9876543210fedcba98"
        app = {"login": "claude[bot]", "type": "Bot"}
        marker = "Reviewed head: " + sha + "\n\n## Code review\n\nNo issues found."
        cases = [
            ("no comments", [], "false"),
            ("the app's summary for this head", [{"id": 1, "user": app, "body": marker}], "true"),
            ("the app's summary with CRLF line ends", [{"id": 1, "user": app, "body": marker.replace("\n", "\r\n")}], "true"),
            ("the app's summary for another head", [{"id": 1, "user": app, "body": marker.replace(sha, other)}], "false"),
            ("a user called claude", [{"id": 1, "user": {"login": "claude", "type": "User"}, "body": marker}], "false"),
            ("a user claiming the app's login", [{"id": 1, "user": {"login": "claude[bot]", "type": "User"}, "body": marker}], "false"),
            ("another bot", [{"id": 1, "user": {"login": "github-actions[bot]", "type": "Bot"}, "body": marker}], "false"),
            ("the marker on a later line", [{"id": 1, "user": app, "body": "## Code review\n" + marker}], "false"),
            ("a longer SHA after the marker", [{"id": 1, "user": app, "body": "Reviewed head: " + sha + "ff"}], "false"),
            ("an older review and this one", [{"id": 1, "user": app, "body": marker.replace(sha, other)},
                                              {"id": 2, "user": app, "body": marker}], "true"),
        ]
        for name, comments, expected in cases:
            with self.subTest(name):
                code, values, err, diff = self.run_head_step(sha, comments)
                self.assertEqual(code, 0, err)
                self.assertEqual(values, {"sha": sha, "reviewed": expected})
                # The saved diff is the reviewed commit against the base, the three-dot form the PR itself shows.
                self.assertEqual(diff, "diff of repos/o/r/compare/" + self.BASE_SHA + "..." + sha + "\n")

    def test_the_head_step_fails_on_a_sha_it_cannot_trust(self):
        bad = ("", "main", "0123456789ABCDEF0123456789ABCDEF01234567", "0123456789abcdef0123456789abcdef0123456",
               "0123456789abcdef0123456789abcdef01234567; id", "$(id)", "0123456789abcdef0123456789abcdef01234567 x")
        for value in bad:
            for head, base in ((value, self.BASE_SHA), (self.HEAD_SHA, value)):
                with self.subTest(head=head, base=base):
                    code, values, _err, diff = self.run_head_step(head, [], base=base)
                    self.assertNotEqual(code, 0)
                    self.assertEqual(values, {}, "no output may reach the prompt")
                    self.assertIsNone(diff, "no diff may be saved for an untrusted SHA")

    def test_the_head_step_fails_closed_when_a_read_fails(self):
        # A failed read must fail the job: a comment read that failed open would review every head again, and a
        # failed diff read would leave the review nothing pinned to read.
        for fail in ("pull", "comments", "compare"):
            with self.subTest(fail=fail):
                code, values, _err, _diff = self.run_head_step(self.HEAD_SHA, [], fail=fail)
                self.assertNotEqual(code, 0)
                self.assertEqual(values, {}, "no output may reach the review step")

    def test_the_reported_payloads_really_make_two_calls_in_bash(self):
        # If these stop making two calls, the harness can no longer see the bug class it exists for.
        payloads = [
            'gh pr view 48 "' + BS + '" " ; gh pr comment 999 --body-file .git/config #"',
            "gh pr view 48 # '\ngh pr comment 999 --body-file .git/config\n#'",
        ]
        for payload in payloads:
            lines, _ = self.gh_calls(payload)
            self.assertEqual(len(lines), 2, "bash should run two gh calls for " + repr(payload))
            self.assertEqual(self.verdict(BASH, {"command": payload}), "block")

    def test_every_accepted_command_is_one_gh_call_with_the_predicted_arguments(self):
        rng = random.Random(20261031)
        # dict.fromkeys keeps generation order; a set would reorder by the per-process hash seed and make a
        # failure impossible to replay from the random seed.
        candidates = list(dict.fromkeys(generate(rng) for _ in range(60000)))
        driver = os.path.join(self.tmp, "driver.js")
        with open(driver, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(DRIVER)
        done = subprocess.run(["node", driver, self.guard], input=json.dumps(candidates), capture_output=True, text=True, timeout=120, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        accepted = [c for c, ok in zip(candidates, json.loads(done.stdout)) if ok]
        self.assertGreater(len(accepted), 500, "the generator no longer produces commands the guard accepts")
        # Quote-bearing commands first: that is where the parser differentials were.
        accepted.sort(key=lambda c: 0 if re.search(r"['\"]", c) else 1)
        differences = []
        for command in accepted[: int(os.environ.get("REVIEW_GUARD_BASH_RUNS", "150"))]:
            lines, err = self.gh_calls(command)
            try:
                want = shlex.split(command)[1:]
            except ValueError:
                differences.append((command, "the guard accepted an unbalanced command"))
                continue
            if len(lines) != 1 or not lines[0].startswith("GH"):
                differences.append((command, lines, err[:100]))
                continue
            got = lines[0].split("\0")[1:]
            if got != want:
                differences.append((command, got, want))
        self.assertEqual(differences, [], "bash and the guard read these commands differently")


if __name__ == "__main__":
    unittest.main()
