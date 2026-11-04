#!/usr/bin/env bash
# Keeps the published app (the "app" release install.sh downloads) up to date with main.
# GitHub's macOS runners sometimes run out of capacity; a job that never gets a runner fails
# after ~15 minutes with no steps run, and nothing retries it. When the published version is
# behind main and the latest CI run for main failed only that way, this reruns its failed jobs.
# Real failures (a step ran and failed) are left alone. Run by .github/workflows/watchdog.yml.
# Needs GH_REPO and GH_TOKEN (actions: write). DRY_RUN=1 only reports.
set -euo pipefail
: "${GH_REPO:?}"
MAX_ATTEMPTS=${MAX_ATTEMPTS:-6}

head=$(gh api "repos/$GH_REPO/commits/main" --jq .sha)
published=$(curl -fsSL "https://github.com/$GH_REPO/releases/download/app/version.txt" 2>/dev/null | tr -d '[:space:]' || true)
echo "main: ${head:0:12}  published: ${published:-none}"
if [[ "$published" == "${head:0:12}" ]]; then echo "Published app is current."; exit 0; fi

run=$(gh api "repos/$GH_REPO/actions/workflows/ci.yml/runs?head_sha=$head&event=push&per_page=1" \
  --jq '.workflow_runs[0] // empty | "\(.id) \(.status) \(.conclusion) \(.run_attempt)"')
if [[ -z "$run" ]]; then echo "No CI run for ${head:0:12} yet."; exit 0; fi
read -r id status conclusion attempt <<<"$run"
echo "CI run $id: $status ${conclusion} (attempt $attempt)"
if [[ "$status" != "completed" ]]; then echo "Still running; GitHub fails a job it can't place within ~15 minutes."; exit 0; fi

# Failed or cancelled jobs, and whether any of them actually ran a step that failed.
jobs=$(gh api "repos/$GH_REPO/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")]')
stalled=$(jq '[.[] | select((.runner_name // "") == "" or ([.steps[]? | select(.conclusion == "failure")] | length) == 0)] | length' <<<"$jobs")
broken=$(jq '[.[] | select((.runner_name // "") != "" and ([.steps[]? | select(.conclusion == "failure")] | length) > 0)] | length' <<<"$jobs")
echo "Jobs that never ran: $stalled  jobs that failed: $broken"

if [[ "$broken" -gt 0 ]]; then echo "A real failure; not retrying."; exit 0; fi
if [[ "$stalled" -eq 0 ]]; then echo "Nothing to retry."; exit 0; fi
if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then echo "Already tried $attempt times; giving up until the next push."; exit 0; fi
if [[ -n "${DRY_RUN:-}" ]]; then echo "Would rerun the failed jobs of run $id."; exit 0; fi
gh run rerun "$id" --failed
echo "Reran the failed jobs of run $id."
