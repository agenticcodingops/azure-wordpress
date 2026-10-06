#!/usr/bin/env python3
"""
Automated Pull Request Reviewer using Gemini API.

Evaluates git diffs against repository guidelines (.gemini/styleguide.md,
.gemini/config.yaml, .github/gemini-review.md) and posts or updates
a structured review comment on pull requests.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

COMMENT_MARKER = "<!-- automated-gemini-code-review -->"
DEFAULT_MODEL = "gemini-2.5-flash"
FALLBACK_MODELS = ["gemini-1.5-flash", "gemini-2.5-pro"]
MAX_DIFF_CHARS = 80000


def get_env_var(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def run_git_command(args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git"] + args,
            capture_output=True,
            text=True,
            check=True,
            cwd=os.getcwd(),
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"::warning::git command failed: {' '.join(args)}: {e.stderr.strip()}", file=sys.stderr)
        return ""


def get_diff(base_ref: str) -> str:
    if not base_ref:
        base_ref = "main"

    # Ensure base ref is fetched
    run_git_command(["fetch", "origin", base_ref, "--depth=100"])

    # Try three-dot diff first
    diff = run_git_command(["diff", f"origin/{base_ref}...HEAD"])
    if not diff:
        # Fall back to two-dot diff
        diff = run_git_command(["diff", f"origin/{base_ref}"])
    return diff


def load_file(path: str) -> str:
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception as e:
            print(f"::warning::Failed to read {path}: {e}", file=sys.stderr)
    return ""


def call_gemini_api(api_key: str, model: str, system_prompt: str, user_prompt: str) -> str:
    models_to_try = [model] + [m for m in FALLBACK_MODELS if m != model]

    for current_model in models_to_try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{current_model}:generateContent"
        payload = {
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": user_prompt}],
                }
            ],
            "systemInstruction": {
                "parts": [{"text": system_prompt}],
            },
            "generationConfig": {
                "temperature": 0.2,
                "maxOutputTokens": 4096,
            },
        }

        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Content-Type": "application/json",
                "x-goog-api-key": api_key,
            },
            method="POST",
        )

        try:
            print(f"Calling Gemini API with model: {current_model}...")
            with urllib.request.urlopen(req, timeout=60) as resp:
                resp_data = json.loads(resp.read().decode("utf-8"))
                candidates = resp_data.get("candidates", [])
                if candidates:
                    parts = candidates[0].get("content", {}).get("parts", [])
                    if parts and "text" in parts[0]:
                        return parts[0]["text"]
                print(f"::warning::No text in candidate response from {current_model}")
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            print(f"::warning::Gemini API error ({current_model}): HTTP {e.code} - {err_body}", file=sys.stderr)
            if e.code in (404, 400) and current_model != models_to_try[-1]:
                print(f"Retrying with next fallback model...")
                continue
            raise
        except Exception as e:
            print(f"::warning::Unexpected error calling Gemini API ({current_model}): {e}", file=sys.stderr)
            if current_model != models_to_try[-1]:
                continue
            raise

    return ""


def github_api_request(method: str, path: str, token: str, data: dict = None) -> dict | list | None:
    url = f"https://api.github.com{path}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read().decode("utf-8")
            if content:
                return json.loads(content)
            return None
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        print(f"::warning::GitHub API {method} {path} failed: HTTP {e.code}: {err_msg}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"::warning::GitHub API error: {e}", file=sys.stderr)
        return None


def post_or_update_comment(repo: str, pr_number: str, token: str, body_text: str):
    comments_path = f"/repos/{repo}/issues/{pr_number}/comments"
    existing_comments = github_api_request("GET", comments_path, token)

    comment_id = None
    if isinstance(existing_comments, list):
        for c in existing_comments:
            if COMMENT_MARKER in c.get("body", ""):
                comment_id = c.get("id")
                break

    full_body = f"{COMMENT_MARKER}\n{body_text}"

    if comment_id:
        print(f"Updating existing review comment ID: {comment_id}")
        patch_path = f"/repos/{repo}/issues/comments/{comment_id}"
        github_api_request("PATCH", patch_path, token, {"body": full_body})
    else:
        print(f"Creating new review comment on PR #{pr_number}")
        github_api_request("POST", comments_path, token, {"body": full_body})


def main():
    api_key = get_env_var("GEMINI_API_KEY")
    if not api_key:
        print("::warning::GEMINI_API_KEY secret is not configured or empty. Skipping automated review.")
        sys.exit(0)

    pr_number = get_env_var("PR_NUMBER")
    base_ref = get_env_var("BASE_REF", "main")
    repo = get_env_var("REPO_NAME")
    token = get_env_var("GITHUB_TOKEN")
    pr_title = get_env_var("PR_TITLE", "Pull Request")
    pr_body = get_env_var("PR_BODY", "")
    model = get_env_var("GEMINI_MODEL", DEFAULT_MODEL)

    if not pr_number or not repo or not token:
        print("::error::Missing required PR context (PR_NUMBER, REPO_NAME, GITHUB_TOKEN).")
        sys.exit(1)

    print(f"Extracting git diff against origin/{base_ref}...")
    diff = get_diff(base_ref)

    if not diff:
        print("No diff found between branches. Exiting.")
        sys.exit(0)

    if len(diff) > MAX_DIFF_CHARS:
        print(f"Diff size ({len(diff)} chars) exceeds limit; truncating to {MAX_DIFF_CHARS} chars.")
        diff = diff[:MAX_DIFF_CHARS] + "\n\n... [Diff truncated due to size limit] ..."

    styleguide = load_file(".gemini/styleguide.md")
    guidelines = load_file(".github/gemini-review.md")

    system_prompt = (
        "You are an expert automated code reviewer for the `azure-wordpress` repository.\n\n"
        "Your review must strictly enforce the repository architecture and styleguide rules:\n"
        f"--- REPOSITORY STYLEGUIDE ---\n{styleguide}\n\n"
        f"--- DOMAIN GUIDELINES ---\n{guidelines}\n\n"
        "Instructions for your review:\n"
        "1. Focus on architectural integrity, AzureRM ~> 5.6 compatibility, security best practices, and code cleanliness.\n"
        "2. Structure your review into clear sections:\n"
        "   - **Summary of Changes**: 1-2 sentence overview of what the PR modifies.\n"
        "   - **Key Findings**:\n"
        "     - 🚨 **Critical / High Severity**: Breaking changes, security risks (e.g. unencrypted transport, exposed credentials, missing TLS minimums).\n"
        "     - ⚠️ **Medium Severity**: Deviations from repository conventions, deprecated attributes, non-standard naming.\n"
        "     - 💡 **Low / Suggestions**: Minor improvements, clarity, or style suggestions.\n"
        "   - **Recommendation**: Explicitly state 'LGTM / Approved' if no medium/high issues exist, or list specific required changes.\n"
        "3. If everything conforms to the standards and no issues are found, state clearly that the PR meets repository standards.\n"
        "4. Be constructive, concise, and reference specific file paths and line numbers wherever relevant."
    )

    user_prompt = (
        f"Please perform a code review on Pull Request #{pr_number}.\n\n"
        f"**PR Title**: {pr_title}\n"
        f"**PR Description**:\n{pr_body or 'No description provided.'}\n\n"
        f"**Diff**:\n```diff\n{diff}\n```"
    )

    try:
        review_markdown = call_gemini_api(api_key, model, system_prompt, user_prompt)
    except Exception as e:
        print(f"::error::Failed to generate review from Gemini API: {e}")
        sys.exit(1)

    if not review_markdown:
        print("::warning::No review generated. Exiting.")
        sys.exit(0)

    review_footer = (
        "\n\n---\n"
        "*Automated review powered by Gemini model evaluation against repository guidelines.*"
    )
    final_review = review_markdown.strip() + review_footer

    post_or_update_comment(repo, pr_number, token, final_review)
    print("Automated review completed and posted successfully.")


if __name__ == "__main__":
    main()
