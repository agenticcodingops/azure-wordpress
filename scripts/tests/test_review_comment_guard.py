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
        cls.guard = os.path.join(cls.tmp, "review-comment-guard.js")
        with open(cls.guard, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(extract_guard(TEXT))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_guard(self, tool, tool_input):
        event = json.dumps({"tool_name": tool, "tool_input": tool_input})
        done = subprocess.run(
            ["node", self.guard, PR, REPO, WS], input=event, capture_output=True, text=True, timeout=30, check=False
        )
        return done.returncode, done.stderr

    def verdict(self, tool, tool_input):
        code, _ = self.run_guard(tool, tool_input)
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

    def test_the_hook_sees_every_tool(self):
        # Shell tools other than Bash (Monitor, PowerShell) reach a hook under a name that depends on the CLI
        # version, and a tool added later would not be on any list. The guard blocks what it does not know.
        match = re.search(r'"matcher":\s*"([^"]+)"', TEXT)
        self.assertIsNotNone(match, "no PreToolUse matcher found")
        self.assertEqual(match.group(1), "*")

    def test_settings_from_the_checkout_cannot_turn_the_hook_off(self):
        # A pull request can add .claude/settings.json with {"disableAllHooks": true}; measured on CLI 2.1.316, a
        # project setting like that stopped a loaded hook. The action loads user, project and local settings
        # unless told otherwise, and the hook is installed in the user settings.
        self.assertRegex(TEXT, r"--setting-sources user\s*\n")

    def test_the_hook_fails_closed(self):
        command = re.search(r'"command":\s*"(node [^"]*review-comment-guard\.js[^"]*)"', TEXT)
        self.assertIsNotNone(command, "the hook command was not found")
        self.assertTrue(command.group(1).rstrip().endswith("|| exit 2"), "a crash or a missing node must block")
        timeout = re.search(r'"timeout":\s*(\d+)', TEXT)
        self.assertIsNotNone(timeout)
        watchdog = re.search(r"setTimeout\([^;]*?,\s*(\d+)\)", extract_guard(TEXT))
        self.assertIsNotNone(watchdog, "the guard has no watchdog")
        self.assertLess(int(watchdog.group(1)), int(timeout.group(1)) * 1000, "the watchdog must fire before the hook times out")

    def test_the_guard_step_comes_before_the_review_step(self):
        self.assertLess(TEXT.index("Write the review comment guard"), TEXT.index("id: claude-review"))

    def test_the_review_cannot_write_anywhere_but_the_summary(self):
        # A bare Write allows every use of the tool, and a Write(path) rule is never matched.
        self.assertNotRegex(TEXT, r'--allowedTools "[^"]*(?<![A-Za-z(])Write[,"]')
        self.assertNotIn("Write(", TEXT.split("claude_args:")[-1])
        self.assertRegex(TEXT, r"--disallowedTools[^\n]*Edit\(/\$\{\{ runner\.temp \}\}/\*\*\)")
        self.assertRegex(TEXT, r"--disallowedTools[^\n]*Edit\(~/\.claude/\*\*\)")

    def test_the_summary_path_is_cleared_before_the_review(self):
        self.assertIn('rm -rf -- "$GITHUB_WORKSPACE/.review-summary.md"', TEXT)
        self.assertLess(TEXT.index("Clear the review summary path"), TEXT.index("Write the review comment guard"))

    def test_the_action_is_pinned_to_a_commit(self):
        match = re.search(r"uses:\s*anthropics/claude-code-action@(\S+)", TEXT)
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1), r"^[0-9a-f]{40}$", "a tag can be moved; pin the action to a commit")


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
    # tools the guard does not manage go on to the normal permission check
    ["allow", "Read", {"file_path": "x"}],
    ["allow", "Grep", {"pattern": "x"}],
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
    # tools that run nothing and write nothing go on to the normal permission check
    + [["allow", tool, {}] for tool in ("Read", "Grep", "Glob", "LS", "Agent", "Task", "TaskCreate", "TaskGet", "TaskList",
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
