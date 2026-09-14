#!/usr/bin/env bash
# Freeze a local secondmate worker's ready head for the parent's merge gate.
# Usage: FM_HOME=<seeded-child-home> fm-local-ready.sh <task-id>
# Requires a clean fm/<task-id> worker with a spawn-owned task record and a
# canonical local-only seed binding. No remote, PR or validator is invoked.
# Publishes data/<task-id>/local-ready/<generation-sha256>/<full-head>/ once,
# containing identity and ready.bundle,
# reports its exact head through the existing parent channel, and retains every
# version until normal landed-work cleanup. A repeat validates the same bytes;
# a changed branch requires a new head and fresh parent approval. Publication is
# readiness only, never completion/landing. The parent approves that exact head
# and runs fm-merge-local.sh --secondmate <mate> <task> <full-head>.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-local-delivery-lib.sh
. "$SCRIPT_DIR/fm-local-delivery-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
[ "$#" -eq 1 ] && fm_pr_task_id_valid "$1" && [ -n "${FM_HOME:-}" ] || { echo 'usage: FM_HOME=<child> fm-local-ready.sh <task-id>' >&2; exit 2; }
fm_local_context "$FM_HOME" "$1" || { fm_local_error 'invalid child task or parent/project binding'; exit 1; }
LOCK="$FM_HOME/state/.control-$1.lock"
TMP=
cleanup() { [ -z "$TMP" ] || rm -rf -- "$TMP"; fm_lock_release "$LOCK" || true; }
fm_lock_acquire_wait "$LOCK"
trap cleanup EXIT
fm_local_context "$FM_HOME" "$1" || exit 1
HEAD=$(git -C "$FM_LOCAL_WT" rev-parse HEAD)
fm_local_worker_matches "$HEAD" || { fm_local_error 'worker branch/head is not clean and ready'; exit 1; }
BASE=$(git -C "$FM_LOCAL_PROJECT" rev-parse "refs/heads/$FM_LOCAL_DEFAULT")
git -C "$FM_LOCAL_WT" merge-base --is-ancestor "$BASE" "$HEAD" || { fm_local_error 'rebase onto the current parent default before ready'; exit 1; }
READY_ROOT="$FM_HOME/data/$1/local-ready"
fm_local_dir "$FM_HOME/data" && fm_local_dir "$FM_HOME/data/$1" || exit 1
if [ ! -e "$READY_ROOT" ] && [ ! -L "$READY_ROOT" ]; then mkdir "$READY_ROOT"; fi
fm_local_dir "$READY_ROOT" || exit 1
READY_ROOT="$READY_ROOT/$FM_LOCAL_GENERATION_KEY"
if [ ! -e "$READY_ROOT" ] && [ ! -L "$READY_ROOT" ]; then mkdir "$READY_ROOT"; fi
fm_local_dir "$READY_ROOT" || exit 1
if [ ! -e "$READY_ROOT/$HEAD" ] && [ ! -L "$READY_ROOT/$HEAD" ]; then
  TMP=$(mktemp -d "$READY_ROOT/.ready.XXXXXX")
  # A full bundle also supports a no-op ready head without Git's empty-bundle
  # rejection; it has no remote and cannot publish source commits.
  git -C "$FM_LOCAL_WT" bundle create "$TMP/ready.bundle" "refs/heads/fm/$1"
  fm_local_worker_matches "$HEAD" || exit 1
  [ "$(git bundle list-heads "$TMP/ready.bundle")" = "$HEAD refs/heads/fm/$1" ] || exit 1
  fm_local_identity "$HEAD" "$BASE" "$(fm_pr_sha256 "$TMP/ready.bundle")" > "$TMP/identity"
  chmod 400 "$TMP/identity" "$TMP/ready.bundle"
  mv "$TMP" "$READY_ROOT/$HEAD"
  TMP=
fi
fm_local_artifact "$HEAD" || { fm_local_error 'ready artifact differs from the task identity'; exit 1; }
fm_parent_channel_report "$FM_HOME" "$FM_HOME/state" \
  "working [key=local-ready-$1-$HEAD-$FM_LOCAL_GENERATION_KEY]: child $1 ready in branch fm/$1 head=$HEAD; parent landing required" || exit 1
printf 'ready mate=%s task=%s head=%s artifact=%s\n' "$FM_LOCAL_MATE" "$1" "$HEAD" "$FM_LOCAL_READY"
