#!/usr/bin/env bash
# jobs.sh: the Path B step that runs the operations jobs, as the guide runner
# hook `<!-- run hook=jobs -->`. It also proves the admin token from
# barkpark.env is an operator token, because `bp org create` is an operator
# route. Needs RG from the vars file.
#
# It starts barkpark-ops (args: check) and barkpark-backup, waits for each
# execution to finish, and fails unless both succeed.
set -euo pipefail
: "${RG:?vars file must set RG}"

bp --yes org create "guide-$(date +%H%M%S)" >/dev/null
echo "jobs.sh: bp org create succeeded, so the admin token is an operator token"

run_job() {
  local job="$1" exec status i
  exec="$(az containerapp job start -g "$RG" -n "$job" --query name -o tsv)"
  echo "jobs.sh: started $job execution $exec"
  for i in $(seq 1 90); do
    status="$(az containerapp job execution show -g "$RG" -n "$job" --job-execution-name "$exec" \
      --query properties.status -o tsv 2>/dev/null || true)"
    case "$status" in
      Succeeded) echo "jobs.sh: $job $exec succeeded after about $((i * 10)) s"; return 0 ;;
      Failed|Stopped|Degraded) echo "jobs.sh: $job $exec ended $status" >&2; return 1 ;;
    esac
    sleep 10
  done
  echo "jobs.sh: $job $exec still ${status:-unknown} after 15 minutes" >&2
  return 1
}

run_job barkpark-ops
run_job barkpark-backup
