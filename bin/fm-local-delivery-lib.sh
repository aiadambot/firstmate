#!/usr/bin/env bash
# Local secondmate delivery identity and retained, immutable ready artifacts.
# Source only. fm-local-ready.sh owns publication; fm-merge-local.sh alone owns
# parent landing. Neither writes task metadata. A ready directory is keyed by
# the task generation and full commit id, with a bundle and identity record. A
# parent receipt is that same record, published only after the canonical parent
# default contains the head. Landing then fast-forwards the child default to
# that head for subsequent tasks. Teardown requires receipt and both ancestries.
# Local paths and the existing seed/registry/parent binding must all agree.
# Remote placements are unsupported. All writers hold the child's control lock;
# landing additionally holds the parent's registry and per-project landing locks.

_FM_LOCAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_LOCAL_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_LOCAL_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$_FM_LOCAL_LIB_DIR/fm-secondmate-registry-lib.sh"

fm_local_error() { echo "REFUSED: local delivery: $*" >&2; return 1; }

fm_local_dir() { # existing absolute path, with no symlink components
  local path=$1 resolved
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  resolved=$(cd "$path" && pwd -P) || return 1
  [ "$resolved" = "$path" ]
}

fm_local_file() {
  fm_local_dir "${1%/*}" && [ -f "$1" ] && [ ! -L "$1" ] \
    && [ "$(fm_pr_file_link_count "$1")" = 1 ]
}

fm_local_field() { # exact, single, nonempty field in a line record
  local file=$1 key=$2
  fm_local_file "$file" || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  awk -v k="$key=" 'index($0,k)==1 {n++; v=substr($0,length(k)+1)} END {if(n!=1 || v=="") exit 1; print v}' "$file"
}

fm_local_gitdir() {
  local dir
  dir=$(git -C "$1" rev-parse --git-common-dir) || return 1
  case "$dir" in /*) ;; *) dir="$1/$dir" ;; esac
  (cd "$dir" && pwd -P)
}

fm_local_default() {
  local ref branch
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return; fi
  for branch in main master; do
    if git -C "$1" show-ref --verify --quiet "refs/heads/$branch"; then printf '%s\n' "$branch"; return; fi
  done
  return 1
}

fm_local_clean() {
  local status
  status=$(git -C "$1" status --porcelain --untracked-files=all) || return 1
  [ -z "$status" ] || fm_local_error "uncommitted work in $1"
}

fm_local_context() { # child-home task-id; output FM_LOCAL_* identity globals
  fm_local_context_records "$1" "$2" && fm_local_worktree_binding
}

fm_local_context_records() { # every binding except the worker checkout
  local child=$1 task=$2 parent mate project name common mode
  fm_pr_task_id_valid "$task" || return 1
  fm_local_dir "$child" && fm_local_dir "$child/state" && fm_local_dir "$child/data" \
    && fm_local_dir "$child/config" && fm_local_dir "$child/projects" || return 1
  mate=$(fm_parent_channel_home_id "$child") || return 1
  fm_secondmate_parent_record_parse "$child/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || fm_local_error "remote local-only placement is unsupported" || return 1
  parent=$FM_SECONDMATE_PARENT_HOME
  fm_local_dir "$parent" && fm_local_dir "$parent/state" && fm_local_dir "$parent/projects" \
    && fm_local_dir "$parent/data" && fm_local_dir "$parent/config" || return 1
  [ ! -e "$parent/.fm-secondmate-home" ] && [ ! -L "$parent/.fm-secondmate-home" ] || return 1
  secondmate_registry_validate_bindings "$parent/data/secondmates.md" secondmate_registry_path_key "$mate" "$child" || return 1
  [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 0 ] && [ "$SECONDMATE_REGISTRY_MATCH_HOME_KEY" = "local:$child" ] || return 1
  FM_LOCAL_META="$child/state/$task.meta"
  [ "$(fm_local_field "$FM_LOCAL_META" mode)" = local-only ] || return 1
  [ "$(fm_local_field "$FM_LOCAL_META" kind)" = ship ] || return 1
  FM_LOCAL_GEN=$(fm_local_field "$FM_LOCAL_META" spawn_gen) || return 1
  FM_LOCAL_GENERATION_KEY=$(fm_pr_sha256 <(printf '%s' "$FM_LOCAL_GEN")) || return 1
  project=$(fm_local_field "$FM_LOCAL_META" project) || return 1
  name=${project##*/}
  fm_pr_task_id_valid "$name" || return 1
  [ "$project" = "$child/projects/$name" ] && fm_local_dir "$project" || return 1
  case ", $(printf '%s' "$SECONDMATE_REGISTRY_MATCH_PROJECTS" | sed 's/, */, /g'), " in
    *", $name, "*) ;; *) return 1 ;;
  esac
  FM_LOCAL_PROJECT="$parent/projects/$name"
  fm_local_dir "$FM_LOCAL_PROJECT" || return 1
  [ "$(git -C "$FM_LOCAL_PROJECT" rev-parse --show-toplevel)" = "$FM_LOCAL_PROJECT" ] || return 1
  [ "$(git -C "$project" rev-parse --show-toplevel)" = "$project" ] || return 1
  [ -z "$(git -C "$project" remote)" ] || return 1
  [ "$(git -C "$project" config --local --get fm.localSource)" = "$FM_LOCAL_PROJECT" ] || return 1
  common=$(fm_local_gitdir "$FM_LOCAL_PROJECT") || return 1
  [ "$(git -C "$project" config --local --get fm.localSourceGitDir)" = "$common" ] || return 1
  [ "$(fm_local_gitdir "$project")" != "$common" ] || return 1
  mode=$(FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" "$_FM_LOCAL_LIB_DIR/fm-project-mode.sh" "$name") || return 1
  [ "${mode%% *}" = local-only ] || return 1
  FM_LOCAL_PARENT=$parent FM_LOCAL_CHILD=$child FM_LOCAL_MATE=$mate FM_LOCAL_TASK=$task
  FM_LOCAL_CLONE=$project FM_LOCAL_COMMON=$common
  FM_LOCAL_DEFAULT=$(fm_local_default "$FM_LOCAL_PROJECT") || return 1
}

fm_local_worktree_binding() { # the task's own worker checkout, exclusively
  local other other_wt other_top
  FM_LOCAL_WT=$(fm_local_field "$FM_LOCAL_META" worktree) || return 1
  fm_local_dir "$FM_LOCAL_WT" || return 1
  [ "$(git -C "$FM_LOCAL_WT" rev-parse --show-toplevel)" = "$FM_LOCAL_WT" ] || return 1
  [ "$(fm_local_gitdir "$FM_LOCAL_WT")" = "$(fm_local_gitdir "$FM_LOCAL_CLONE")" ] || return 1
  [ "$FM_LOCAL_WT" != "$FM_LOCAL_CLONE" ] || return 1
  # A second task record cannot own this same worker checkout.
  for other in "$FM_LOCAL_CHILD"/state/*.meta; do
    [ "$other" = "$FM_LOCAL_META" ] && continue
    fm_local_file "$other" || return 1
    if ! other_wt=$(fm_local_field "$other" worktree 2>/dev/null); then
      # A malformed populated owner must not become an absent owner.
      ! LC_ALL=C grep -q '^worktree=.' "$other" || return 1
      continue
    fi
    other_wt=$(cd "$other_wt" && pwd -P) || return 1
    other_top=$(git -C "$other_wt" rev-parse --show-toplevel) || return 1
    [ "$other_top" != "$FM_LOCAL_WT" ] || fm_local_error "duplicate task ownership of $FM_LOCAL_WT" || return 1
  done
}

fm_local_identity() { # full-ready-head base-head bundle-sha256
  printf '%s\n' 'schema=fm-local-ready.v1' "parent=$FM_LOCAL_PARENT" \
    "child=$FM_LOCAL_CHILD" "mate=$FM_LOCAL_MATE" "task=$FM_LOCAL_TASK" \
    "spawn_gen=$FM_LOCAL_GEN" "project=$FM_LOCAL_PROJECT" "gitdir=$FM_LOCAL_COMMON" \
    "clone=$FM_LOCAL_CLONE" "worktree=$FM_LOCAL_WT" "default=$FM_LOCAL_DEFAULT" \
    "head=$1" "base=$2" "bundle_sha256=$3"
}

fm_local_artifact() { # head; context must already be validated
  local head=$1 base hash actual
  fm_pr_head_valid "$head" || return 1
  FM_LOCAL_READY="$FM_LOCAL_CHILD/data/$FM_LOCAL_TASK/local-ready/$FM_LOCAL_GENERATION_KEY/$head"
  fm_local_file "$FM_LOCAL_READY/identity" && fm_local_file "$FM_LOCAL_READY/ready.bundle" || return 1
  base=$(fm_local_field "$FM_LOCAL_READY/identity" base) || return 1
  fm_pr_head_valid "$base" || return 1
  hash=$(fm_pr_sha256 "$FM_LOCAL_READY/ready.bundle") || return 1
  cmp -s "$FM_LOCAL_READY/identity" <(fm_local_identity "$head" "$base" "$hash") || return 1
  actual=$(git bundle list-heads "$FM_LOCAL_READY/ready.bundle") || return 1
  [ "$actual" = "$head refs/heads/fm/$FM_LOCAL_TASK" ] || return 1
  # Independent, explicitly approved no-op tasks can share a commit. The
  # receipt binds one full delivery identity, never just the commit hash.
  FM_LOCAL_RECEIPT="$FM_LOCAL_PARENT/state/local-landings/${FM_LOCAL_PROJECT##*/}/$(fm_pr_sha256 "$FM_LOCAL_READY/identity")"
}

fm_local_worker_matches() { # head
  [ "$(git -C "$FM_LOCAL_WT" symbolic-ref --quiet --short HEAD)" = "fm/$FM_LOCAL_TASK" ] \
    && [ "$(git -C "$FM_LOCAL_WT" rev-parse HEAD)" = "$1" ] \
    && fm_local_clean "$FM_LOCAL_WT" && fm_local_clean "$FM_LOCAL_CLONE"
}

fm_local_landed() { # child-home task-id; read-only teardown guard
  local head branch_head
  fm_local_context "$1" "$2" || return 1
  head=$(git -C "$FM_LOCAL_WT" rev-parse HEAD) || return 1
  fm_local_artifact "$head" && fm_local_clean "$FM_LOCAL_WT" || return 1
  branch_head=$(git -C "$FM_LOCAL_CLONE" rev-parse --verify --quiet "refs/heads/fm/$FM_LOCAL_TASK" || true)
  if [ -n "$branch_head" ]; then
    [ "$branch_head" = "$head" ] && fm_local_worker_matches "$head" || return 1
  else
    # A prior teardown can have detached and deleted the landed task branch
    # before a pool return failed. Only that branch-absent detached shape may
    # recover; a switched checkout must never hide a newer unlanded task tip.
    ! git -C "$FM_LOCAL_WT" symbolic-ref --quiet HEAD >/dev/null || return 1
    fm_local_clean "$FM_LOCAL_CLONE" || return 1
  fi
  fm_local_file "$FM_LOCAL_RECEIPT" && cmp -s "$FM_LOCAL_READY/identity" "$FM_LOCAL_RECEIPT" || return 1
  git -C "$FM_LOCAL_CLONE" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" || return 1
  git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT"
}

fm_local_landed_receipt() { # child-home task-id; proof without the worker checkout
  local ready_root ready head branch_head landed
  fm_local_context_records "$1" "$2" || return 1
  ready_root="$FM_LOCAL_CHILD/data/$FM_LOCAL_TASK/local-ready/$FM_LOCAL_GENERATION_KEY"
  fm_local_dir "$ready_root" || return 1
  # The task branch tip is the worker's own latest line: an unlanded tip is live
  # work this cleanup would destroy. A retained readiness the tip already left
  # behind is history, and only fails to prove the landing through its own entry.
  branch_head=$(git -C "$FM_LOCAL_CLONE" rev-parse --verify --quiet "refs/heads/fm/$FM_LOCAL_TASK" || true)
  if [ -n "$branch_head" ]; then
    git -C "$FM_LOCAL_CLONE" merge-base --is-ancestor "$branch_head" "refs/heads/$FM_LOCAL_DEFAULT" || return 1
  fi
  landed=1
  for ready in "$ready_root"/*; do
    fm_local_dir "$ready" || return 1
    head=${ready##*/}
    FM_LOCAL_WT=$(fm_local_field "$ready/identity" worktree) || return 1
    fm_local_artifact "$head" || return 1
    if ! fm_local_file "$FM_LOCAL_RECEIPT" || ! cmp -s "$ready/identity" "$FM_LOCAL_RECEIPT"; then continue; fi
    git -C "$FM_LOCAL_CLONE" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" || continue
    git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" || continue
    landed=0
  done
  return "$landed"
}

# A child clone has no remote, so a parent default advanced by any other task is
# unreachable until it is carried across locally. This fast-forwards the clone's
# own default only: it never writes the parent, the worker checkout, or fm/<task>,
# and it leaves the worker's rebase onto the new base explicit.
fm_local_refresh() ( # child-home task-id
  set -eu
  local child=$1 task=$2 lock tmp='' base clone_default imported
  fm_local_context "$child" "$task" || { fm_local_error 'invalid child task or parent/project binding'; exit 1; }
  lock="$FM_LOCAL_CHILD/state/.control-$task.lock"
  # shellcheck disable=SC2329 # Registered by the EXIT trap below.
  local_refresh_cleanup() {
    [ -z "$tmp" ] || rm -rf -- "$tmp"
    fm_lock_release "$lock" || true
  }
  fm_lock_acquire_wait "$lock"
  trap local_refresh_cleanup EXIT
  fm_local_context "$child" "$task" || exit 1
  fm_local_clean "$FM_LOCAL_CLONE" || exit 1
  [ "$(git -C "$FM_LOCAL_CLONE" symbolic-ref --quiet --short HEAD)" = "$FM_LOCAL_DEFAULT" ] \
    || { fm_local_error 'child clone is not on its default branch'; exit 1; }
  base=$(git -C "$FM_LOCAL_PROJECT" rev-parse --verify "refs/heads/$FM_LOCAL_DEFAULT") || exit 1
  clone_default=$(git -C "$FM_LOCAL_CLONE" rev-parse --verify "refs/heads/$FM_LOCAL_DEFAULT") || exit 1
  if [ "$clone_default" != "$base" ]; then
    # The clone already holds everything up to its own default, so only the
    # advance is packed - and only once the parent proves it is a continuation.
    git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$clone_default" "$base" \
      || { fm_local_error 'child default diverged from the parent default; nothing was moved'; exit 1; }
    tmp=$(mktemp -d "$FM_LOCAL_CHILD/data/$task/.refresh.XXXXXX")
    # Local object transfer only: no remote, no refspec, no FETCH_HEAD.
    git -C "$FM_LOCAL_PROJECT" bundle create "$tmp/default.bundle" "$clone_default..refs/heads/$FM_LOCAL_DEFAULT" >/dev/null 2>&1 \
      || { fm_local_error 'could not pack the parent default advance; nothing was moved'; exit 1; }
    git -C "$FM_LOCAL_CLONE" bundle verify "$tmp/default.bundle" >/dev/null || exit 1
    imported=$(git -C "$FM_LOCAL_CLONE" bundle unbundle "$tmp/default.bundle") || exit 1
    [ "$imported" = "$base refs/heads/$FM_LOCAL_DEFAULT" ] || exit 1
    git -C "$FM_LOCAL_CLONE" merge-base --is-ancestor "$clone_default" "$base" \
      || { fm_local_error 'child default diverged from the parent default; nothing was moved'; exit 1; }
    git -C "$FM_LOCAL_CLONE" -c core.hooksPath=/dev/null merge --ff-only "$base" >/dev/null || exit 1
    [ "$(git -C "$FM_LOCAL_CLONE" rev-parse HEAD)" = "$base" ] || exit 1
  fi
  fm_local_clean "$FM_LOCAL_CLONE" || exit 1
  printf 'refreshed mate=%s task=%s default=%s base=%s worker=%s\n' \
    "$FM_LOCAL_MATE" "$task" "$FM_LOCAL_DEFAULT" "$base" "$FM_LOCAL_WT"
)

fm_local_land() ( # parent-home mate-id task-id approved-full-head
  set -eu
  local parent=$1 mate=$2 task=$3 head=$4 child lock registry_lock project_lock receipt_dir imported tmp='' status=0
  fm_pr_task_id_valid "$mate" && fm_pr_task_id_valid "$task" && fm_pr_head_valid "$head" || exit 2
  fm_local_dir "$parent" && fm_local_dir "$parent/state" || exit 1
  [ ! -e "$parent/.fm-secondmate-home" ] && [ ! -L "$parent/.fm-secondmate-home" ] \
    && [ -z "${FM_TASK_ID:-}" ] || { fm_local_error 'only the parent firstmate may land'; exit 1; }
  registry_lock="$parent/state/.secondmate-registry.lock"
  lock='' project_lock=''
  # shellcheck disable=SC2329 # Registered by the EXIT trap below.
  local_land_cleanup() {
    [ -z "$tmp" ] || rm -f -- "$tmp"
    [ -z "$project_lock" ] || fm_lock_release "$project_lock" || true
    [ -z "$lock" ] || fm_lock_release "$lock" || true
    fm_lock_release "$registry_lock" || true
  }
  fm_lock_acquire_wait "$registry_lock"
  trap local_land_cleanup EXIT
  secondmate_registry_line_for_id "$parent/data/secondmates.md" "$mate" || exit 1
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || { fm_local_error 'remote local-only placement is unsupported'; exit 1; }
  child=$SECONDMATE_REGISTRY_HOME
  fm_local_context "$child" "$task" && [ "$FM_LOCAL_PARENT" = "$parent" ] || exit 1
  lock="$child/state/.control-$task.lock"
  fm_lock_acquire_wait "$lock"
  fm_local_context "$child" "$task" && [ "$FM_LOCAL_PARENT" = "$parent" ] || exit 1
  project_lock="$parent/state/.local-landing-${FM_LOCAL_PROJECT##*/}.lock"
  fm_lock_acquire_wait "$project_lock"
  fm_local_artifact "$head" || { fm_local_error 'foreign head or changed ready identity'; exit 1; }
  fm_local_worker_matches "$head" || { fm_local_error 'worker changed since readiness'; exit 1; }
  [ "$(git -C "$FM_LOCAL_CLONE" symbolic-ref --quiet --short HEAD)" = "$FM_LOCAL_DEFAULT" ] || exit 1
  git -C "$FM_LOCAL_CLONE" merge-base --is-ancestor "refs/heads/$FM_LOCAL_DEFAULT" "$head" \
    || { fm_local_error 'child default diverged or advanced beyond the ready head'; exit 1; }
  fm_local_clean "$FM_LOCAL_PROJECT" || exit 1
  [ "$(git -C "$FM_LOCAL_PROJECT" symbolic-ref --quiet --short HEAD)" = "$FM_LOCAL_DEFAULT" ] || exit 1
  # The original task stays in its child's backlog; no mirror task is created.
  FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" FM_DATA_OVERRIDE="$child/data" \
    FM_CONFIG_OVERRIDE="$child/config" "$_FM_LOCAL_LIB_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent || status=$?
  case "$status" in
    1|3) ;;
    0) fm_local_error 'task is still held for the captain'; exit 1 ;;
    *) fm_local_error 'cannot read captain hold'; exit 1 ;;
  esac
  receipt_dir=${FM_LOCAL_RECEIPT%/*}
  if [ -e "$FM_LOCAL_RECEIPT" ] || [ -L "$FM_LOCAL_RECEIPT" ]; then
    if ! fm_local_file "$FM_LOCAL_RECEIPT" || ! cmp -s "$FM_LOCAL_READY/identity" "$FM_LOCAL_RECEIPT"; then
      fm_local_error 'duplicate landing ownership or changed receipt'; exit 1
    fi
    git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" || exit 1
  else
    if [ ! -e "$parent/state/local-landings" ] && [ ! -L "$parent/state/local-landings" ]; then mkdir "$parent/state/local-landings"; fi
    fm_local_dir "$parent/state/local-landings" || exit 1
    if [ ! -e "$receipt_dir" ] && [ ! -L "$receipt_dir" ]; then mkdir "$receipt_dir"; fi
    fm_local_dir "$receipt_dir" || exit 1
    # Bundle verification/import is local object transfer only. No remote refs,
    # FETCH_HEAD or task metadata are written. The merge names the approved SHA.
    git -C "$FM_LOCAL_PROJECT" bundle verify "$FM_LOCAL_READY/ready.bundle" >/dev/null || exit 1
    imported=$(git -C "$FM_LOCAL_PROJECT" bundle unbundle "$FM_LOCAL_READY/ready.bundle") || exit 1
    [ "$imported" = "$head refs/heads/fm/$task" ] || exit 1
    git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" \
      || git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "refs/heads/$FM_LOCAL_DEFAULT" "$head" \
      || { fm_local_error 'parent default diverged; run FM_HOME=<child> bin/fm-local-refresh.sh <task-id>, rebase and publish a new ready head'; exit 1; }
    tmp=$(mktemp "$receipt_dir/.landing.XXXXXX")
    cat "$FM_LOCAL_READY/identity" > "$tmp"
    chmod 400 "$tmp"
    fm_local_artifact "$head" && fm_local_worker_matches "$head" && fm_local_clean "$FM_LOCAL_PROJECT" || exit 1
    # Recover a merge-before-receipt crash even if another approved landing has
    # since advanced the parent. A contained head needs only its receipt.
    if ! git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT"; then
      git -C "$FM_LOCAL_PROJECT" -c core.hooksPath=/dev/null merge --ff-only "$head" >/dev/null || exit 1
    fi
    git -C "$FM_LOCAL_PROJECT" merge-base --is-ancestor "$head" "refs/heads/$FM_LOCAL_DEFAULT" || exit 1
    mv "$tmp" "$FM_LOCAL_RECEIPT"
    tmp=
  fi
  # The parent receipt is authoritative. Refresh this clone only afterward so
  # the next worker starts at the landed head; a failed refresh remains retryable.
  fm_local_worker_matches "$head" || exit 1
  [ "$(git -C "$FM_LOCAL_CLONE" symbolic-ref --quiet --short HEAD)" = "$FM_LOCAL_DEFAULT" ] || exit 1
  git -C "$FM_LOCAL_CLONE" -c core.hooksPath=/dev/null merge --ff-only "$head" >/dev/null || exit 1
  [ "$(git -C "$FM_LOCAL_CLONE" rev-parse HEAD)" = "$head" ] || exit 1
  fm_parent_channel_report "$child" "$child/state" \
    "done [key=local-landed-$task-$head-$FM_LOCAL_GENERATION_KEY]: child $task landed in parent $FM_LOCAL_PROJECT head=$head mode=local-only" || exit 1
  printf 'landed mate=%s task=%s head=%s project=%s receipt=%s\n' "$mate" "$task" "$head" "$FM_LOCAL_PROJECT" "$FM_LOCAL_RECEIPT"
)
