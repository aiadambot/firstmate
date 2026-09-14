#!/usr/bin/env bash
# Carry an advanced parent default into a local secondmate's child clone.
# Usage: FM_HOME=<seeded-child-home> fm-local-refresh.sh <task-id>
# A child clone has no remote, so a parent default advanced by another task is
# otherwise unreachable and wedges readiness and landing. This fast-forwards the
# clone's own default branch from local objects only. It never writes the parent
# project, the worker checkout or fm/<task-id>, never forces or resets, and never
# rebases: the worker rebases onto the reported base itself and publishes a new
# ready head. Uncommitted or diverged work refuses without moving anything.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-local-delivery-lib.sh
. "$SCRIPT_DIR/fm-local-delivery-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
[ "$#" -eq 1 ] && fm_pr_task_id_valid "$1" && [ -n "${FM_HOME:-}" ] || { echo 'usage: FM_HOME=<child> fm-local-refresh.sh <task-id>' >&2; exit 2; }
fm_local_refresh "$FM_HOME" "$1"
