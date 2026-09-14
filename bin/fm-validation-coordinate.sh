#!/usr/bin/env bash
# Coordinate one validation run without starting a second validation pipeline.
#
# A local secondmate calls this helper from its seeded home. The authoritative
# claim is stored in the local parent home, so two mate homes cannot claim the
# same run independently. The claim binds the worker's home, task incarnation,
# worktree, branch, and head. It is never deleted or reassigned by this helper.
#
# Usage:
#   fm-send.sh <nomistakes-mate> "validation-run=<run> worker=<mate-or-main>/<task>"
#   fm-validation-coordinate.sh claim <run> <corr> <worker-home> <task>
#   fm-validation-coordinate.sh attach-run <run> <no-mistakes-run-id>
#   fm-validation-coordinate.sh status <run>
#   fm-validation-coordinate.sh owner-result <run> <verb> <note...>
#
# claim reports the claim once through fm-secondmate-report.sh and then records
# a durable receipt. A crash between the report and the receipt makes the next
# claim repeat that one progress line: reporting is at-least-once, not
# exactly-once.
#
# attach-run records an ownership association; it does not attach to or drive
# the pipeline. status uses the installed no-mistakes public read-only AXI
# interface. No command starts, reattaches to, responds to, or drives a run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,13p' "$0" >&2
  exit 2
}

field() { # <record> <key>
  local record=$1 key=$2 value count
  count=$(grep -c "^${key}=" "$record" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^${key}=//p" "$record")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

safe_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(fm_pr_file_link_count "$1")" = 1 ]
}

summary_has_token() { # <summary> <exact-token>
  printf '%s\n' "$1" | tr ' ' '\n' | grep -Fqx "$2"
}

canonical_dir() { # <absolute-directory>
  local physical path=${1%/}
  [ -n "$path" ] || path=/
  if LC_ALL=C printf '%s' "$1" | grep -q '[[:cntrl:]]'; then return 1; fi
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  physical=$(cd "$1" && pwd -P) || return 1
  [ "$physical" = "$path" ] || return 1
  printf '%s' "$physical"
}

resolve_parent() {
  local binding="$FM_HOME/.fm-secondmate-parent" mate_id
  safe_file "$FM_HOME/.fm-secondmate-home" \
    || die "FM_HOME is not a seeded secondmate home"
  safe_file "$binding" || die "the secondmate parent binding is unsafe"
  fm_secondmate_parent_record_parse "$binding" \
    || die "cannot parse the secondmate parent binding"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die "remote validation coordination is unsupported"
  PARENT_HOME=$(canonical_dir "$FM_SECONDMATE_PARENT_HOME") \
    || die "the local parent home is unsafe or missing"
  [ -d "$PARENT_HOME/state" ] && [ ! -L "$PARENT_HOME/state" ] \
    || die "the local parent state directory is unsafe or missing"
  [ -d "$PARENT_HOME/data" ] && [ ! -L "$PARENT_HOME/data" ] \
    && [ "$(canonical_dir "$PARENT_HOME/data")" = "$PARENT_HOME/data" ] \
    || die "the local parent data directory is unsafe or missing"
  CLAIM_DIR="$PARENT_HOME/state/validation-runs"
  [ ! -e "$CLAIM_DIR" ] || { [ -d "$CLAIM_DIR" ] && [ ! -L "$CLAIM_DIR" ]; } \
    || die "the validation claim directory is unsafe"
  mate_id=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home")
  fm_task_id_path_safe "$mate_id" || die "coordinator secondmate identity is invalid"
  secondmate_registry_validate_bindings "$PARENT_HOME/data/secondmates.md" \
    secondmate_registry_path_key "$mate_id" "$FM_HOME" \
    || die "coordinator home is not registered to this parent: $SECONDMATE_REGISTRY_ERROR"
  [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 0 ] || die "remote validation coordination is unsupported"
}

load_claim() { # <run>
  RUN=$1
  fm_task_id_path_safe "$RUN" || die "run id must be path-safe"
  CLAIM="$CLAIM_DIR/$RUN.claim"
  safe_file "$CLAIM" || die "validation run '$RUN' is not claimed or is unsafe"
  CLAIM_CORR=$(field "$CLAIM" corr) || die "validation claim has no unique corr"
  CLAIM_WORKER_HOME=$(field "$CLAIM" worker_home) || die "validation claim has no unique worker_home"
  CLAIM_TASK=$(field "$CLAIM" task) || die "validation claim has no unique task"
  CLAIM_SPAWN_GEN=$(field "$CLAIM" spawn_gen) || die "validation claim has no unique spawn_gen"
  CLAIM_WORKTREE=$(field "$CLAIM" worktree) || die "validation claim has no unique worktree"
  CLAIM_BRANCH=$(field "$CLAIM" branch) || die "validation claim has no unique branch"
  CLAIM_HEAD=$(field "$CLAIM" head) || die "validation claim has no unique head"
  CLAIM_PROJECT=$(field "$CLAIM" project) || die "validation claim has no unique project"
  CLAIM_MODE=$(field "$CLAIM" mode) || die "validation claim has no unique mode"
  CLAIM_COORDINATOR_HOME=$(field "$CLAIM" coordinator_home) || die "validation claim has no unique coordinator_home"
  [ "$CLAIM_COORDINATOR_HOME" = "$FM_HOME" ] || die "validation run '$RUN' belongs to another coordinator"
}

load_attached_run() {
  RUN_RECORD="$CLAIM_DIR/$RUN.run"
  safe_file "$RUN_RECORD" || die "validation run '$RUN' has no safe attached no-mistakes run"
  NM_RUN_ID=$(field "$RUN_RECORD" run_id) || die "attached run record has no unique run_id"
}

validate_worker_home() { # <canonical-worker-home>
  local worker_home=$1 marker binding worker_mate worker_parent
  [ "$worker_home" != "$PARENT_HOME" ] || return 0
  marker="$worker_home/.fm-secondmate-home"
  safe_file "$marker" || die "worker home is not the parent or a seeded local secondmate"
  worker_mate=$(sed -n '1p' "$marker")
  fm_task_id_path_safe "$worker_mate" || die "worker secondmate identity is invalid"
  binding="$worker_home/.fm-secondmate-parent"
  safe_file "$binding" || die "worker secondmate parent binding is unsafe or missing"
  fm_secondmate_parent_record_parse "$binding" || die "worker secondmate parent binding is invalid"
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die "remote worker homes are unsupported"
  worker_parent=$(canonical_dir "$FM_SECONDMATE_PARENT_HOME") \
    || die "worker secondmate parent is unsafe or missing"
  [ "$worker_parent" = "$PARENT_HOME" ] || die "worker secondmate belongs to another parent"
  secondmate_registry_validate_bindings "$PARENT_HOME/data/secondmates.md" \
    secondmate_registry_path_key "$worker_mate" "$worker_home" \
    || die "worker home is not registered to this parent: $SECONDMATE_REGISTRY_ERROR"
  [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 0 ] || die "remote worker homes are unsupported"
}

verify_owner() {
  local worker_home meta spawn_gen mode project worktree branch top
  worker_home=$(canonical_dir "$CLAIM_WORKER_HOME") || die "claimed worker home is unsafe or missing"
  [ "$worker_home" = "$CLAIM_WORKER_HOME" ] || die "claimed worker home identity changed"
  validate_worker_home "$worker_home"
  [ -d "$worker_home/state" ] && [ ! -L "$worker_home/state" ] \
    || die "claimed worker state directory is unsafe or missing"
  meta="$worker_home/state/$CLAIM_TASK.meta"
  safe_file "$meta" || die "claimed worker metadata is missing or unsafe"
  spawn_gen=$(field "$meta" spawn_gen) || die "worker metadata has no unique spawn_gen"
  mode=$(field "$meta" mode) || die "worker metadata has no unique mode"
  project=$(field "$meta" project) || die "worker metadata has no unique project"
  worktree=$(field "$meta" worktree) || die "worker metadata has no unique worktree"
  worktree=$(canonical_dir "$worktree") || die "worker worktree is unsafe or missing"
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || die "worker worktree is not a git checkout"
  top=$(canonical_dir "$top") || die "worker checkout top-level is unsafe"
  [ "$top" = "$worktree" ] || die "worker worktree does not name its checkout top-level"
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD) || die "worker worktree is detached"
  [ "$spawn_gen" = "$CLAIM_SPAWN_GEN" ] || die "worker spawn generation no longer matches the claim"
  [ "$mode" = "$CLAIM_MODE" ] || die "worker delivery mode no longer matches the claim"
  [ "$project" = "$CLAIM_PROJECT" ] || die "worker project no longer matches the claim"
  [ "$worktree" = "$CLAIM_WORKTREE" ] || die "worker worktree no longer matches the claim"
  [ "$branch" = "$CLAIM_BRANCH" ] || die "worker branch no longer matches the claim"
}

axi_status_for_run() { # <run-id> <allow-bound-custody:0|1>
  local requested=$1 allow_custody=${2:-0} out actual branch run_head
  out=$(fm_nm_run_checked "$CLAIM_WORKTREE" 10 axi status --run "$requested") \
    || die "no-mistakes AXI status failed for run '$requested'"
  actual=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$actual" = "$requested" ] || die "no-mistakes returned run '${actual:-unknown}', expected '$requested'"
  branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ "$branch" = "$CLAIM_BRANCH" ] || die "no-mistakes run branch does not match the claim"
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  if ! fm_nm_head_matches_worktree "$CLAIM_WORKTREE" "$run_head" \
    && { [ "$allow_custody" -ne 1 ] || ! fm_nm_run_is_pipeline_owned_active "$out"; }; then
    die "no-mistakes run head does not continue the claimed worker identity"
  fi
  printf '%s\n' "$out"
}

cmd_claim() {
  [ "$#" -eq 4 ] || usage
  local run=$1 corr=$2 worker_home=$3 task=$4
  local meta spawn_gen mode worktree branch head project top worker_owner tmp lock rc=0
  case "$corr" in
    [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
    *) die "corr must be 16 hexadecimal characters" ;;
  esac
  fm_task_id_path_safe "$run" || die "run id must be path-safe"
  fm_task_id_path_safe "$task" || die "task id must be path-safe"
  worker_home=$(canonical_dir "$worker_home") || die "worker home is unsafe or missing"
  validate_worker_home "$worker_home"
  local mate_id pending pending_task pending_parent delivered summary
  mate_id=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home")
  fm_task_id_path_safe "$mate_id" || die "coordinator secondmate identity is invalid"
  pending="$PARENT_HOME/state/pending-replies/$(printf '%s' "$corr" | tr 'A-F' 'a-f')"
  [ -d "$PARENT_HOME/state/pending-replies" ] && [ ! -L "$PARENT_HOME/state/pending-replies" ] \
    || die "the pending-reply directory is unsafe or missing"
  safe_file "$pending" || die "corr does not name a safe routed parent request"
  pending_task=$(field "$pending" task_id) || die "routed request has no unique task_id"
  pending_parent=$(field "$pending" parent_home) || die "routed request has no unique parent_home"
  delivered=$(field "$pending" delivered_epoch) || die "routed request is not confirmed delivered"
  summary=$(field "$pending" request_summary) || die "routed request has no unique request summary"
  [ "$pending_task" = "$mate_id" ] || die "routed request belongs to another secondmate"
  [ "$pending_parent" = "$PARENT_HOME" ] || die "routed request belongs to another parent"
  summary_has_token "$summary" "validation-run=$run" \
    || die "routed request does not name the exact token validation-run=$run"
  meta="$worker_home/state/$task.meta"
  [ -d "$worker_home/state" ] && [ ! -L "$worker_home/state" ] \
    || die "worker state directory is unsafe or missing"
  safe_file "$meta" || die "worker metadata is missing or unsafe"
  spawn_gen=$(field "$meta" spawn_gen) || die "worker metadata has no unique spawn_gen"
  worktree=$(field "$meta" worktree) || die "worker metadata has no unique worktree"
  project=$(field "$meta" project) || die "worker metadata has no unique project"
  mode=$(field "$meta" mode) || die "worker metadata has no unique mode"
  if [ "$worker_home" = "$PARENT_HOME" ]; then
    worker_owner=main
  else
    worker_owner=$(sed -n '1p' "$worker_home/.fm-secondmate-home")
  fi
  summary_has_token "$summary" "worker=$worker_owner/$task" \
    || die "routed request does not name the exact worker token worker=$worker_owner/$task"
  worktree=$(canonical_dir "$worktree") || die "worker worktree is unsafe or missing"
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || die "worker worktree is not a git checkout"
  top=$(canonical_dir "$top") || die "worker checkout top-level is unsafe"
  [ "$top" = "$worktree" ] || die "worker worktree does not name its checkout top-level"
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD) || die "worker worktree is detached"
  head=$(git -C "$worktree" rev-parse --verify HEAD) || die "cannot read worker head"

  if [ ! -e "$CLAIM_DIR" ]; then
    mkdir "$CLAIM_DIR" 2>/dev/null || true
  fi
  [ -d "$CLAIM_DIR" ] && [ ! -L "$CLAIM_DIR" ] \
    || die "cannot create a safe validation claim directory"
  chmod 700 "$CLAIM_DIR" 2>/dev/null || true
  CLAIM="$CLAIM_DIR/$run.claim"
  lock="$CLAIM.lock"
  fm_lock_try_acquire "$lock" || die "validation run '$run' claim is busy"
  trap 'fm_lock_release "$lock"' EXIT
  tmp=$(mktemp "$CLAIM_DIR/.claim.XXXXXX") || die "cannot stage validation claim"
  {
    printf 'schema=fm-validation-run.v1\n'
    printf 'corr=%s\n' "$(printf '%s' "$corr" | tr 'A-F' 'a-f')"
    printf 'coordinator_home=%s\n' "$(canonical_dir "$FM_HOME")"
    printf 'worker_home=%s\n' "$worker_home"
    printf 'task=%s\n' "$task"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'project=%s\n' "$project"
    printf 'mode=%s\n' "$mode"
    printf 'worktree=%s\n' "$worktree"
    printf 'branch=%s\n' "$branch"
    printf 'head=%s\n' "$head"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  if [ -e "$CLAIM" ]; then
    safe_file "$CLAIM" || rc=1
    [ "$rc" -ne 0 ] || cmp -s "$tmp" "$CLAIM" || rc=1
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || die "validation run '$run' already has a different owner"
  else
    mv "$tmp" "$CLAIM" || die "cannot publish validation claim"
  fi
  local report_receipt report_note report_tmp
  report_receipt="$CLAIM.reported"
  if ! safe_file "$report_receipt"; then
    [ ! -e "$report_receipt" ] && [ ! -L "$report_receipt" ] \
      || die "validation claim report receipt is unsafe"
    report_note="validation run $run exclusively claimed by $task at $branch/$head"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-secondmate-report.sh" working "$corr" "$report_note"
    report_tmp=$(mktemp "$CLAIM_DIR/.reported.XXXXXX") || die "cannot stage validation claim report receipt"
    printf 'schema=fm-validation-claim-report.v1\n' > "$report_tmp"
    chmod 600 "$report_tmp" 2>/dev/null || true
    mv "$report_tmp" "$report_receipt" || die "cannot publish validation claim report receipt"
  fi
  fm_lock_release "$lock"
  trap - EXIT
  printf 'claimed: %s owner=%s spawn_gen=%s branch=%s head=%s\n' "$run" "$task" "$spawn_gen" "$branch" "$head"
}

cmd_attach_run() {
  [ "$#" -eq 2 ] || usage
  local requested=$2 out record tmp lock rc=0 reverse_dir reverse reverse_tmp reverse_lock reverse_rc=0
  load_claim "$1"
  verify_owner
  [ "$CLAIM_MODE" != local-only ] \
    || die "local-only workers cannot attach a no-mistakes run; v1.64.0 has no nonpublishing initialization path"
  [ "$(git -C "$CLAIM_WORKTREE" rev-parse --verify HEAD)" = "$CLAIM_HEAD" ] \
    || die "worker head changed before the no-mistakes run was attached"
  case "$requested" in ''|*[!A-Za-z0-9._-]*) die "no-mistakes run id is invalid" ;; esac
  out=$(axi_status_for_run "$requested" 0)
  record="$CLAIM_DIR/$RUN.run"
  lock="$record.lock"
  fm_lock_try_acquire "$lock" || die "validation run '$RUN' attachment is busy"
  trap '[ -z "${reverse_lock:-}" ] || fm_lock_release "$reverse_lock"; fm_lock_release "$lock"' EXIT
  if [ -e "$record" ]; then
    safe_file "$record" || die "validation run '$RUN' has an unsafe attachment"
    [ "$(field "$record" run_id)" = "$requested" ] \
      || die "validation run '$RUN' is already attached to a different no-mistakes run"
  fi

  reverse_dir="$CLAIM_DIR/by-no-mistakes-run"
  if [ ! -e "$reverse_dir" ]; then mkdir "$reverse_dir" 2>/dev/null || true; fi
  [ -d "$reverse_dir" ] && [ ! -L "$reverse_dir" ] \
    || die "the no-mistakes run ownership directory is unsafe"
  chmod 700 "$reverse_dir" 2>/dev/null || true
  reverse="$reverse_dir/$requested.owner"
  reverse_lock="$reverse.lock"
  fm_lock_try_acquire "$reverse_lock" || die "no-mistakes run '$requested' ownership is busy"
  reverse_tmp=$(mktemp "$reverse_dir/.owner.XXXXXX") || die "cannot stage no-mistakes run ownership"
  {
    printf 'schema=fm-validation-actual-run-owner.v1\n'
    printf 'request=%s\n' "$RUN"
    printf 'coordinator_home=%s\n' "$FM_HOME"
    printf 'worker_home=%s\n' "$CLAIM_WORKER_HOME"
    printf 'task=%s\n' "$CLAIM_TASK"
    printf 'spawn_gen=%s\n' "$CLAIM_SPAWN_GEN"
  } > "$reverse_tmp"
  chmod 600 "$reverse_tmp" 2>/dev/null || true
  if [ -e "$reverse" ]; then
    safe_file "$reverse" || reverse_rc=1
    [ "$reverse_rc" -ne 0 ] || cmp -s "$reverse_tmp" "$reverse" || reverse_rc=1
    rm -f "$reverse_tmp"
    [ "$reverse_rc" -eq 0 ] \
      || die "no-mistakes run '$requested' already has a different validation owner"
  else
    mv "$reverse_tmp" "$reverse" || die "cannot publish no-mistakes run ownership"
  fi

  tmp=$(mktemp "$CLAIM_DIR/.run.XXXXXX") || die "cannot stage no-mistakes run attachment"
  printf 'schema=fm-validation-run-attachment.v1\nrun_id=%s\n' "$requested" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  if [ -e "$record" ]; then
    safe_file "$record" || rc=1
    [ "$rc" -ne 0 ] || cmp -s "$tmp" "$record" || rc=1
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || die "validation run '$RUN' is already attached to a different no-mistakes run"
  else
    mv "$tmp" "$record" || die "cannot publish no-mistakes run attachment"
  fi
  fm_lock_release "$reverse_lock"
  reverse_lock=
  fm_lock_release "$lock"
  trap - EXIT
  printf '%s\n' "$out"
  printf 'attached: %s no-mistakes-run=%s\n' "$RUN" "$requested"
}

cmd_status() {
  [ "$#" -eq 1 ] || usage
  load_claim "$1"
  verify_owner
  load_attached_run
  printf 'claim: run=%s owner=%s spawn_gen=%s branch=%s head=%s\n' \
    "$RUN" "$CLAIM_TASK" "$CLAIM_SPAWN_GEN" "$CLAIM_BRANCH" "$CLAIM_HEAD"
  axi_status_for_run "$NM_RUN_ID" 1
}

cmd_owner_result() {
  [ "$#" -ge 3 ] || usage
  local run=$1 verb=$2 out outcome
  shift 2
  case "$verb" in working|done|blocked|failed) ;; *) die "verb must be working, done, blocked, or failed" ;; esac
  [ -n "$*" ] || die "result note is required"
  load_claim "$run"
  verify_owner
  load_attached_run
  out=$(axi_status_for_run "$NM_RUN_ID" 1)
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$verb" in
    done)
      case "$outcome" in passed|checks-passed) ;; *) die "done requires a passed or checks-passed AXI outcome" ;; esac
      ;;
    failed)
      case "$outcome" in failed|cancelled) ;; *) die "failed requires a failed or cancelled AXI outcome" ;; esac
      ;;
    working|blocked)
      fm_nm_run_is_active "$out" || die "$verb requires an active AXI run"
      ;;
  esac
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-secondmate-report.sh" "$verb" "$CLAIM_CORR" \
    "validation run $run owner-reported by $CLAIM_TASK: $*"
  printf 'reported: %s corr=%s evidence=owner-reported\n' "$run" "$CLAIM_CORR"
}

[ -n "${FM_HOME:-}" ] || die "FM_HOME is required"
FM_HOME=$(canonical_dir "$FM_HOME") || die "FM_HOME is unsafe or missing"
resolve_parent

COMMAND=${1:-}
[ -n "$COMMAND" ] || usage
shift
case "$COMMAND" in
  claim) cmd_claim "$@" ;;
  attach-run) cmd_attach_run "$@" ;;
  status) cmd_status "$@" ;;
  owner-result) cmd_owner_result "$@" ;;
  *) usage ;;
esac
