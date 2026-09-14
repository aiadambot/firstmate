#!/usr/bin/env bash
# Exercise the local-only secondmate lifecycle through its public commands.
# A real seeded child clone hands off one real backlog item, freezes a worker
# head, requires the parent receipt for teardown, and lands only through the
# parent's guarded exact-head entrypoint. Refusal cases cover the identity and
# work-preservation boundaries without any remote, PR, or validator call.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid
REAL_GIT=$(command -v git)

TMP_ROOT=$(fm_test_tmproot fm-local-delivery)

make_world() { # <name>
  local name=$1 world="$TMP_ROOT/$1" parent="$TMP_ROOT/$1/parent" child="$TMP_ROOT/$1/child"
  local fakebin pane
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$parent/config"
  fm_git_init_commit "$parent/projects/alpha"
  printf '%s\n' '- alpha [local-only] - private fixture (added 2026-09-14)' > "$parent/data/projects.md"
  touch "$parent/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$world/fake")
  pane="$world/fake/pane.txt"

  PATH="$fakebin:$PATH" FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SECONDMATE_CHARTER='local delivery fixture coordinator' FM_SECONDMATE_SCOPE='local fixture delivery' \
    "$ROOT/bin/fm-home-seed.sh" mate-x "$child" alpha > "$world/seed.out" 2> "$world/seed.err" \
    || fail "$name: seed failed: $(cat "$world/seed.err")"

  fm_write_secondmate_meta "$parent/state/mate-x.meta" "$child" firstmate:fm-mate-x alpha echo
  tasks-axi add local-task 'local delivery fixture' --kind ship --repo alpha \
    --file "$parent/data/backlog.md" >/dev/null \
    || fail "$name: backlog fixture creation failed"
  PATH="$fakebin:$PATH" FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TMUX_LOG="$world/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_WINDOW=firstmate:fm-mate-x \
    "$ROOT/bin/fm-backlog-handoff.sh" mate-x local-task > "$world/handoff.out" 2> "$world/handoff.err" \
    || fail "$name: handoff failed: $(cat "$world/handoff.err")"

  git -C "$child/projects/alpha" worktree add --quiet -b fm/local-task "$world/worker" main
  printf 'implemented\n' > "$world/worker/feature.txt"
  git -C "$world/worker" add feature.txt
  git -C "$world/worker" commit -qm 'implement local fixture'
  mkdir -p "$child/data/local-task"
  fm_write_meta "$child/state/local-task.meta" \
    'window=firstmate:fm-local-task' \
    'endpoint_task_id=local-task' \
    "worktree=$world/worker" \
    "project=$child/projects/alpha" \
    'harness=echo' \
    'kind=ship' \
    'mode=local-only' \
    'yolo=off' \
    "spawn_gen=$name-local-task"
  printf 'done: local fixture ready\n' > "$child/state/local-task.status"
  printf '%s\n' "$world"
}

run_ready() { # <world>
  FM_HOME="$1/child" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-local-ready.sh" local-task
}

run_land() { # <world> <head>
  PATH="$1/fake/fakebin:$PATH" FM_FAKE_GIT_REMOTE_HELPER_MARKER="$1/remote-helper-called" \
    FM_FAKE_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_CHILD_PROJECT="$1/child/projects/alpha" \
    FM_FAKE_GIT_SYNC_FAILURE_MARKER="$1/child-sync-failed" \
    FM_FAKE_GIT_FAIL_CHILD_SYNC_ONCE="${FM_FAKE_GIT_FAIL_CHILD_SYNC_ONCE:-}" \
    FM_HOME="$1/parent" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" --secondmate mate-x local-task "$2"
}

install_child_sync_failure_git() { # <world>
  cat > "$1/fake/fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_GIT_FAIL_CHILD_SYNC_ONCE:-}" = 1 ] \
    && [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_FAKE_GIT_CHILD_PROJECT" ]; then
  for arg in "$@"; do
    if [ "$arg" = merge ] && [ ! -e "$FM_FAKE_GIT_SYNC_FAILURE_MARKER" ]; then
      : > "$FM_FAKE_GIT_SYNC_FAILURE_MARKER"
      exit 1
    fi
  done
fi
exec "$FM_FAKE_REAL_GIT" "$@"
EOF
  chmod +x "$1/fake/fakebin/git"
}

ready_artifact() { # <ready-output>
  printf '%s\n' "$1" | sed -n 's/^ready .* artifact=//p'
}

identity_hash() { # <ready-artifact>
  bash -c '. "$1"; fm_pr_sha256 "$2"' _ "$ROOT/bin/fm-pr-lib.sh" "$1/identity"
}

receipt_for() { # <world> <ready-artifact>
  printf '%s/parent/state/local-landings/alpha/%s\n' "$1" "$(identity_hash "$2")"
}

run_child_teardown() { # <world>
  FM_HOME="$1/child" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/child/state" FM_DATA_OVERRIDE="$1/child/data" \
    FM_CONFIG_OVERRIDE="$1/child/config" PATH="$1/fake/fakebin:$PATH" \
    FM_FAKE_REAL_GIT="$REAL_GIT" FM_FAKE_GIT_CHILD_PROJECT="$1/child/projects/alpha" \
    FM_FAKE_GIT_SYNC_FAILURE_MARKER="$1/child-sync-failed" \
    "$ROOT/bin/fm-teardown.sh" local-task
}

assert_seed_and_handoff() { # <world>
  local world=$1 parent="$1/parent" child="$1/child" expected_source expected_gitdir
  expected_source=$(cd "$parent/projects/alpha" && pwd -P)
  expected_gitdir=$(git -C "$parent/projects/alpha" rev-parse --absolute-git-dir)
  assert_equals "$expected_source" "$(git -C "$child/projects/alpha" config --local --get fm.localSource)" \
    "seed did not bind the child clone to the canonical parent source"
  assert_equals "$expected_gitdir" "$(git -C "$child/projects/alpha" config --local --get fm.localSourceGitDir)" \
    "seed did not bind the child clone to the canonical parent git directory"
  [ -z "$(git -C "$child/projects/alpha" remote)" ] \
    || fail "local-only seeded clone gained a publishing remote"
  assert_no_grep 'local-task' "$parent/data/backlog.md" "handoff left the task in the parent backlog"
  assert_grep 'local-task' "$child/data/backlog.md" "handoff did not move the task to the secondmate backlog"
}

test_happy_lifecycle() {
  local world parent child head ready_out repeat_out artifact land_out repeat_land receipt next_head
  world=$(make_world happy)
  parent="$world/parent"
  child="$world/child"
  assert_seed_and_handoff "$world"
  ready_out=$(run_ready "$world") || fail "happy: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  artifact=$(ready_artifact "$ready_out")
  assert_present "$artifact/identity" "ready did not publish its immutable identity"
  assert_contains "$ready_out" "head=$head" "ready did not report its exact full head"
  receipt=$(receipt_for "$world" "$artifact")
  assert_absent "$receipt" "ready created a parent landing receipt"
  repeat_out=$(run_ready "$world") || fail "happy: repeated ready failed"
  assert_equals "$ready_out" "$repeat_out" "repeated ready did not resolve to the same immutable artifact"
  [ "$(grep -cF "local-ready-local-task-$head" "$parent/state/mate-x.status")" -eq 1 ] \
    || fail "repeated ready duplicated the parent-channel readiness event"

  cat > "$world/fake/fakebin/git-remote-helper" <<'EOF'
#!/usr/bin/env bash
touch "${FM_FAKE_GIT_REMOTE_HELPER_MARKER:?}"
exit 1
EOF
  chmod +x "$world/fake/fakebin/git-remote-helper"
  git -C "$parent/projects/alpha" config --local 'url.helper::trap.insteadOf' "$child/data/"

  land_out=$(run_land "$world" "$head" 2> "$world/land.err") \
    || fail "happy: parent landing failed: $(cat "$world/land.err")"
  assert_contains "$land_out" "landed mate=mate-x task=local-task head=$head" \
    "landing did not report the approved identity"
  assert_equals "$head" "$(git -C "$parent/projects/alpha" rev-parse HEAD)" \
    "parent project did not fast-forward to the approved head"
  assert_equals "$head" "$(git -C "$child/projects/alpha" rev-parse main)" \
    "parent landing did not synchronize the child default branch to the approved head"
  assert_absent "$world/remote-helper-called" \
    "parent landing allowed local URL rewriting to invoke a remote helper"
  assert_present "$receipt" "parent landing did not retain a receipt"
  repeat_land=$(run_land "$world" "$head" 2> "$world/repeat-land.err") \
    || fail "happy: repeated landing failed: $(cat "$world/repeat-land.err")"
  assert_equals "$land_out" "$repeat_land" "repeated landing did not return the same result"
  [ "$(grep -cF "local-landed-local-task-$head" "$parent/state/mate-x.status")" -eq 1 ] \
    || fail "repeated landing duplicated the parent-channel completion event"

  git -C "$child/projects/alpha" worktree add --quiet -b fm/next-task "$world/next-worker" main
  next_head=$(git -C "$world/next-worker" rev-parse HEAD)
  assert_equals "$head" "$next_head" \
    "a subsequent child task did not branch from the landed default head"

  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err" \
    || fail "happy: receipt-backed teardown failed: $(cat "$world/teardown.err")"
  assert_absent "$child/state/local-task.meta" "receipt-backed teardown left the child task metadata"
  assert_present "$child/projects/alpha/.git" "child cleanup removed the seeded project clone"
  assert_grep 'implemented' "$parent/projects/alpha/feature.txt" "parent source lost the landed content"
  assert_grep 'implemented' "$child/projects/alpha/feature.txt" "child source lost the landed content"
  pass "local-only seed, handoff, immutable ready, parent landing, idempotency, and receipt-backed cleanup"
}

test_child_local_merge_is_not_parent_landing() {
  local world parent_before head rc
  world=$(make_world child-only-merge)
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  run_ready "$world" >/dev/null || fail "child-only-merge: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  git -C "$world/child/projects/alpha" merge --ff-only "$head" >/dev/null
  set +e
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "child-local merge alone allowed teardown without a parent receipt"
  assert_grep 'no matching parent landing receipt' "$world/teardown.err" \
    "child-only-merge: teardown refusal did not name the missing parent receipt"
  assert_present "$world/child/state/local-task.meta" \
    "child-only-merge: refused teardown discarded child task metadata"
  assert_equals "$parent_before" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "child-only-merge: child merge changed the parent canonical project"
  pass "a child-local merge cannot stand in for parent landing authority"
}

test_dirty_ready_refuses() {
  local world rc
  world=$(make_world dirty-ready)
  printf 'dirty\n' >> "$world/worker/feature.txt"
  set +e
  run_ready "$world" > "$world/ready.out" 2> "$world/ready.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dirty worker was accepted as ready"
  assert_absent "$world/child/data/local-task/local-ready" "dirty ready published an artifact"
  assert_grep 'worker branch/head is not clean and ready' "$world/ready.err" \
    "dirty ready refusal was not explicit"
  pass "ready refuses uncommitted worker state without publishing"
}

test_landing_recovers_receipt_after_parent_progress() {
  local world head ready_out artifact receipt descendant land_out
  world=$(make_world receipt-recovery)
  ready_out=$(run_ready "$world") || fail "receipt-recovery: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  artifact=$(ready_artifact "$ready_out")
  receipt=$(receipt_for "$world" "$artifact")
  run_land "$world" "$head" >/dev/null 2> "$world/first-land.err" \
    || fail "receipt-recovery: initial landing failed: $(cat "$world/first-land.err")"
  assert_present "$receipt" "receipt-recovery: initial landing did not create a receipt"

  rm "$receipt"
  printf 'later parent work\n' > "$world/parent/projects/alpha/later.txt"
  git -C "$world/parent/projects/alpha" add later.txt
  git -C "$world/parent/projects/alpha" commit -qm 'advance parent after local landing'
  descendant=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  git -C "$world/parent/projects/alpha" merge-base --is-ancestor "$head" "$descendant" \
    || fail "receipt-recovery: fixture parent did not advance from the approved head"

  land_out=$(run_land "$world" "$head" 2> "$world/recovery-land.err") \
    || fail "receipt-recovery: landing retry failed: $(cat "$world/recovery-land.err")"
  assert_contains "$land_out" "landed mate=mate-x task=local-task head=$head" \
    "receipt-recovery: retry did not report the approved identity"
  assert_equals "$descendant" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "receipt-recovery: retry moved the descendant parent head"
  assert_present "$receipt" "receipt-recovery: retry did not reconstruct the landing receipt"
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err" \
    || fail "receipt-recovery: receipt-backed teardown failed: $(cat "$world/teardown.err")"
  assert_absent "$world/child/state/local-task.meta" \
    "receipt-recovery: successful teardown left child task metadata"
  pass "landing retry restores a missing receipt after the parent advances beyond the approved head"
}

test_child_sync_failure_is_receipted_and_retryable() {
  local world parent_before child_before ready_out artifact receipt head rc
  world=$(make_world child-sync-retry)
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  child_before=$(git -C "$world/child/projects/alpha" rev-parse main)
  ready_out=$(run_ready "$world") || fail "child-sync-retry: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  artifact=$(ready_artifact "$ready_out")
  receipt=$(receipt_for "$world" "$artifact")
  install_child_sync_failure_git "$world"

  set +e
  FM_FAKE_GIT_FAIL_CHILD_SYNC_ONCE=1 run_land "$world" "$head" \
    > "$world/first-land.out" 2> "$world/first-land.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "child-sync-retry: injected child synchronization failure was ignored"
  assert_present "$world/child-sync-failed" \
    "child-sync-retry: fixture did not reach the child synchronization boundary"
  assert_equals "$head" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "child-sync-retry: failed synchronization did not retain the parent landing"
  assert_not_equals "$parent_before" "$head" \
    "child-sync-retry: fixture did not advance the canonical parent"
  assert_equals "$child_before" "$(git -C "$world/child/projects/alpha" rev-parse main)" \
    "child-sync-retry: injected failure unexpectedly moved the child default"
  assert_present "$receipt" \
    "child-sync-retry: parent landing did not retain its receipt before child synchronization"

  set +e
  run_child_teardown "$world" > "$world/pre-retry-teardown.out" 2> "$world/pre-retry-teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "child-sync-retry: parent receipt alone allowed cleanup before child synchronization"
  assert_present "$world/child/state/local-task.meta" \
    "child-sync-retry: refused cleanup discarded child task metadata"

  run_land "$world" "$head" > "$world/retry-land.out" 2> "$world/retry-land.err" \
    || fail "child-sync-retry: landing retry failed: $(cat "$world/retry-land.err")"
  assert_equals "$head" "$(git -C "$world/child/projects/alpha" rev-parse main)" \
    "child-sync-retry: landing retry did not synchronize the child default"
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err" \
    || fail "child-sync-retry: teardown after successful retry failed: $(cat "$world/teardown.err")"
  assert_absent "$world/child/state/local-task.meta" \
    "child-sync-retry: successful retry and teardown left child task metadata"
  pass "a receipt-before-child-sync failure preserves work and retries through synchronization and teardown"
}

test_child_default_refusals_preserve_both_repositories() {
  local world parent_before child_before ready_out artifact receipt head child_diverged rc

  world=$(make_world dirty-child-default)
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  child_before=$(git -C "$world/child/projects/alpha" rev-parse main)
  ready_out=$(run_ready "$world") || fail "dirty-child-default: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  artifact=$(ready_artifact "$ready_out")
  receipt=$(receipt_for "$world" "$artifact")
  printf 'uncommitted child default state\n' > "$world/child/projects/alpha/local.txt"
  set +e
  run_land "$world" "$head" > "$world/land.out" 2> "$world/land.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dirty child default was accepted for parent landing"
  assert_equals "$parent_before" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "dirty-child-default refusal moved the parent head"
  assert_equals "$child_before" "$(git -C "$world/child/projects/alpha" rev-parse main)" \
    "dirty-child-default refusal moved the child default head"
  assert_grep 'uncommitted child default state' "$world/child/projects/alpha/local.txt" \
    "dirty-child-default refusal discarded uncommitted child state"
  assert_absent "$receipt" "dirty-child-default refusal created a landing receipt"

  world=$(make_world diverged-child-default)
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  ready_out=$(run_ready "$world") || fail "diverged-child-default: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  artifact=$(ready_artifact "$ready_out")
  receipt=$(receipt_for "$world" "$artifact")
  printf 'diverged child default\n' > "$world/child/projects/alpha/child.txt"
  git -C "$world/child/projects/alpha" add child.txt
  git -C "$world/child/projects/alpha" commit -qm 'diverge child default'
  child_diverged=$(git -C "$world/child/projects/alpha" rev-parse main)
  set +e
  run_land "$world" "$head" > "$world/land.out" 2> "$world/land.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "diverged child default was accepted for parent landing"
  assert_equals "$parent_before" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "diverged-child-default refusal moved the parent head"
  assert_equals "$child_diverged" "$(git -C "$world/child/projects/alpha" rev-parse main)" \
    "diverged-child-default refusal moved the child default head"
  assert_absent "$receipt" "diverged-child-default refusal created a landing receipt"
  pass "dirty or diverged child default branches refuse before parent landing and preserve both repositories"
}

run_refresh() { # <world>
  FM_HOME="$1/child" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-local-refresh.sh" local-task
}

test_parent_advance_is_reachable_through_refresh() {
  local world parent child base refreshed rc head ready_out

  world=$(make_world parent-advance)
  parent="$world/parent"
  child="$world/child"

  printf 'parent work\n' > "$parent/projects/alpha/parent.txt"
  git -C "$parent/projects/alpha" add parent.txt
  git -C "$parent/projects/alpha" commit -qm 'another task landed in the parent'
  base=$(git -C "$parent/projects/alpha" rev-parse HEAD)

  set +e
  run_ready "$world" > "$world/ready.out" 2> "$world/ready.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "readiness accepted a head that predates the advanced parent default"

  refreshed=$(run_refresh "$world") || fail "refresh failed after the parent default advanced"
  assert_contains "$refreshed" "base=$base" "refresh did not report the new parent base"
  assert_equals "$base" "$(git -C "$child/projects/alpha" rev-parse refs/heads/main)" \
    "refresh did not carry the advanced parent default into the child clone"
  assert_equals "$base" "$(git -C "$parent/projects/alpha" rev-parse refs/heads/main)" \
    "refresh moved the parent project"
  [ -z "$(git -C "$child/projects/alpha" remote)" ] || fail "refresh gave the child clone a remote"

  run_refresh "$world" >/dev/null || fail "a repeated refresh was not safe to retry"
  assert_equals "$base" "$(git -C "$child/projects/alpha" rev-parse refs/heads/main)" \
    "a repeated refresh moved the child default again"

  set +e
  run_ready "$world" > "$world/ready2.out" 2> "$world/ready2.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "refresh rebased the worker instead of leaving that explicit"

  git -C "$world/worker" rebase --quiet "$base" || fail "worker could not rebase onto the refreshed base"
  ready_out=$(run_ready "$world") || fail "readiness failed after an explicit rebase onto the refreshed base"
  head=$(git -C "$world/worker" rev-parse HEAD)
  assert_contains "$ready_out" "head=$head" "readiness did not report the rebased head"
  run_land "$world" "$head" >/dev/null 2> "$world/land.err" \
    || fail "landing failed after refresh and rebase: $(cat "$world/land.err")"
  assert_equals "$head" "$(git -C "$parent/projects/alpha" rev-parse refs/heads/main)" \
    "landing did not fast-forward the parent default to the rebased head"
  pass "a parent default advanced by another task is reachable through an explicit local refresh and rebase"
}

test_teardown_refuses_missing_or_advanced_worker() {
  local world head later rc ready_out artifact

  world=$(make_world missing-worker)
  git -C "$world/child/projects/alpha" worktree remove --force "$world/worker"
  set +e
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing local-only worker allowed teardown"
  assert_present "$world/child/state/local-task.meta" \
    "missing-worker refusal discarded the task metadata"

  world=$(make_world advanced-branch)
  run_ready "$world" >/dev/null || fail "advanced-branch: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  run_land "$world" "$head" >/dev/null 2> "$world/land.err" \
    || fail "advanced-branch: landing failed: $(cat "$world/land.err")"
  git -C "$world/worker" checkout --quiet --detach "$head"
  later=$(printf 'later task work\n' | git -C "$world/child/projects/alpha" commit-tree \
    "$(git -C "$world/child/projects/alpha" rev-parse "$head^{tree}")" -p "$head")
  git -C "$world/child/projects/alpha" update-ref refs/heads/fm/local-task "$later" "$head"
  set +e
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "receipt for an older head allowed teardown after the task branch advanced"
  assert_equals "$later" "$(git -C "$world/child/projects/alpha" rev-parse refs/heads/fm/local-task)" \
    "advanced-branch refusal discarded the newer task head"
  assert_equals "$head" "$(git -C "$world/worker" rev-parse HEAD)" \
    "advanced-branch refusal moved the detached receipted checkout"
  assert_present "$world/child/state/local-task.meta" \
    "advanced-branch refusal discarded the task metadata"

  world=$(make_world reassigned-slot)
  ready_out=$(run_ready "$world") || fail "reassigned-slot: ready failed"
  artifact=$(ready_artifact "$ready_out")
  : > "$TMP_ROOT/treehouse-state.json"
  printf 'task=other-task\nhome=%s\n' "$world/child" > "$world/.fm-slot-owner"
  set +e
  run_child_teardown "$world" > "$world/teardown.out" 2> "$world/teardown.err"
  rc=$?
  set -e
  rm -f "$TMP_ROOT/treehouse-state.json"
  [ "$rc" -ne 0 ] || fail "a reassigned pool slot waived the parent landing proof"
  assert_contains "$(cat "$world/teardown.err")" 'cannot be proved' \
    "reassigned-slot refusal did not name the missing landing proof"
  assert_present "$world/child/state/local-task.meta" \
    "reassigned-slot refusal discarded the task metadata"
  assert_present "$artifact/identity" \
    "reassigned-slot refusal discarded the retained ready artifact"
  assert_present "$world/.fm-slot-owner" \
    "reassigned-slot refusal touched the new owner's slot claim"
  assert_present "$world/worker/feature.txt" \
    "reassigned-slot refusal removed the reassigned checkout"

  head=$(git -C "$world/worker" rev-parse HEAD)
  run_land "$world" "$head" >/dev/null 2> "$world/land.err" \
    || fail "reassigned-slot: landing failed: $(cat "$world/land.err")"
  : > "$TMP_ROOT/treehouse-state.json"
  set +e
  run_child_teardown "$world" > "$world/teardown2.out" 2> "$world/teardown2.err"
  rc=$?
  set -e
  rm -f "$TMP_ROOT/treehouse-state.json"
  [ "$rc" -eq 0 ] || fail "a landed task with a reassigned slot was stranded: $(cat "$world/teardown2.err")"
  assert_absent "$world/child/state/local-task.meta" \
    "landed reassigned-slot teardown left its task record behind"
  assert_present "$world/.fm-slot-owner" \
    "landed reassigned-slot teardown removed the new owner's slot claim"
  assert_present "$world/worker/feature.txt" \
    "landed reassigned-slot teardown removed the reassigned checkout"
  assert_present "$(receipt_for "$world" "$artifact")" \
    "landed reassigned-slot teardown removed the parent landing receipt"
  pass "teardown preserves a missing worker record, a newer task branch beyond the receipted head, and an unlanded reassigned slot while a landed one still cleans up"
}

test_reused_task_same_head_has_distinct_delivery_identity() {
  local world child head first_ready first_artifact first_receipt second_ready second_artifact second_receipt
  local ready_lines receipt_count rc
  world=$(make_world reused-task)
  child="$world/child"
  first_ready=$(run_ready "$world") || fail "reused-task: first ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  first_artifact=$(ready_artifact "$first_ready")
  first_receipt=$(receipt_for "$world" "$first_artifact")
  ready_lines=$(grep -c 'child local-task ready in branch' "$world/parent/state/mate-x.status")
  assert_equals "$first_ready" "$(run_ready "$world")" \
    "reused-task: same-generation ready retry changed identity"
  assert_equals "$ready_lines" "$(grep -c 'child local-task ready in branch' "$world/parent/state/mate-x.status")" \
    "reused-task: same-generation ready retry duplicated its parent event"
  run_land "$world" "$head" >/dev/null 2> "$world/first-land.err" \
    || fail "reused-task: first landing failed: $(cat "$world/first-land.err")"
  run_land "$world" "$head" >/dev/null 2> "$world/first-land-repeat.err" \
    || fail "reused-task: same-generation landing retry failed: $(cat "$world/first-land-repeat.err")"
  receipt_count=$(find "$world/parent/state/local-landings/alpha" -type f | wc -l)
  assert_equals 1 "$receipt_count" "reused-task: same-generation landing retry created another receipt"
  run_child_teardown "$world" >/dev/null 2> "$world/first-teardown.err" \
    || fail "reused-task: first cleanup failed: $(cat "$world/first-teardown.err")"

  git -C "$child/projects/alpha" worktree prune
  if git -C "$child/projects/alpha" show-ref --verify --quiet refs/heads/fm/local-task; then
    git -C "$child/projects/alpha" worktree add --quiet "$world/worker-2" fm/local-task
  else
    git -C "$child/projects/alpha" worktree add --quiet -b fm/local-task "$world/worker-2" "$head"
  fi
  mkdir -p "$child/data/local-task"
  fm_write_meta "$child/state/local-task.meta" \
    'window=firstmate:fm-local-task' \
    'endpoint_task_id=local-task' \
    "worktree=$world/worker-2" \
    "project=$child/projects/alpha" \
    'harness=echo' \
    'kind=ship' \
    'mode=local-only' \
    'yolo=off' \
    'spawn_gen=reused-task-second-generation'
  printf 'done: reused no-op fixture ready\n' > "$child/state/local-task.status"

  second_ready=$(run_ready "$world") || fail "reused-task: second-generation ready failed"
  second_artifact=$(ready_artifact "$second_ready")
  second_receipt=$(receipt_for "$world" "$second_artifact")
  assert_equals "$head" "$(git -C "$world/worker-2" rev-parse HEAD)" \
    "reused-task: second generation was not the intended same-head no-op"
  assert_not_equals "$first_artifact" "$second_artifact" \
    "reused-task: two generations at the same head collided on one ready artifact"
  assert_not_equals "$first_receipt" "$second_receipt" \
    "reused-task: two generations at the same head collided on one landing receipt"
  assert_equals "$((ready_lines + 1))" \
    "$(grep -c 'child local-task ready in branch' "$world/parent/state/mate-x.status")" \
    "reused-task: second-generation readiness was hidden by the first parent event"
  run_land "$world" "$head" >/dev/null 2> "$world/second-land.err" \
    || fail "reused-task: second landing failed: $(cat "$world/second-land.err")"
  assert_present "$first_receipt" "reused-task: second landing replaced the first receipt"
  assert_present "$second_receipt" "reused-task: second landing did not publish its own receipt"
  run_child_teardown "$world" >/dev/null 2> "$world/second-teardown.err" || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "reused-task: second cleanup failed: $(cat "$world/second-teardown.err")"
  assert_absent "$child/state/local-task.meta" "reused-task: second cleanup left task metadata"
  pass "same-head reused task generations keep distinct artifacts and receipts while retries stay idempotent"
}

test_landing_refusals_preserve_work() {
  local world head parent_before rc base other

  world=$(make_world dirty-parent)
  run_ready "$world" >/dev/null || fail "dirty-parent: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  printf 'uncommitted parent state\n' > "$world/parent/projects/alpha/local.txt"
  set +e
  run_land "$world" "$head" > "$world/land.out" 2> "$world/land.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dirty parent accepted a ready head"
  assert_equals "$parent_before" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "dirty-parent refusal moved the parent head"
  assert_grep 'uncommitted parent state' "$world/parent/projects/alpha/local.txt" \
    "dirty-parent refusal discarded the uncommitted file"
  assert_present "$world/child/state/local-task.meta" "dirty-parent refusal discarded child ownership"

  world=$(make_world diverged)
  run_ready "$world" >/dev/null || fail "diverged: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  printf 'parent change\n' > "$world/parent/projects/alpha/parent.txt"
  git -C "$world/parent/projects/alpha" add parent.txt
  git -C "$world/parent/projects/alpha" commit -qm 'parent diverged'
  parent_before=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  set +e
  run_land "$world" "$head" > "$world/land.out" 2> "$world/land.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "diverged parent accepted a stale ready head"
  assert_equals "$parent_before" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "diverged refusal moved the parent head"
  assert_present "$world/child/state/local-task.meta" "diverged refusal discarded child ownership"

  world=$(make_world foreign-head)
  run_ready "$world" >/dev/null || fail "foreign-head: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  base=$(git -C "$world/parent/projects/alpha" rev-parse HEAD)
  set +e
  run_land "$world" "$base" > "$world/foreign.out" 2> "$world/foreign.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign approved head was accepted"
  assert_equals "$base" "$(git -C "$world/parent/projects/alpha" rev-parse HEAD)" \
    "foreign-head refusal moved the parent"
  assert_absent "$world/parent/state/local-landings" "foreign-head refusal created a landing receipt"

  world=$(make_world changed-identity)
  local changed_ready changed_artifact changed_receipt
  changed_ready=$(run_ready "$world") || fail "changed-identity: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  changed_artifact=$(ready_artifact "$changed_ready")
  changed_receipt=$(receipt_for "$world" "$changed_artifact")
  git -C "$world/child/projects/alpha" config --local fm.localSource "$world/foreign-source"
  set +e
  run_land "$world" "$head" > "$world/identity.out" 2> "$world/identity.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "changed seed identity was accepted"
  assert_absent "$changed_receipt" "changed identity created a receipt"

  world=$(make_world symlink-artifact)
  local symlink_ready symlink_artifact symlink_receipt
  symlink_ready=$(run_ready "$world") || fail "symlink-artifact: ready failed"
  head=$(git -C "$world/worker" rev-parse HEAD)
  symlink_artifact=$(ready_artifact "$symlink_ready")
  symlink_receipt=$(receipt_for "$world" "$symlink_artifact")
  mv "$symlink_artifact/identity" "$world/identity.saved"
  ln -s "$world/identity.saved" "$symlink_artifact/identity"
  set +e
  run_land "$world" "$head" > "$world/symlink.out" 2> "$world/symlink.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked ready identity was accepted"
  assert_absent "$symlink_receipt" "symlinked identity created a receipt"

  world=$(make_world duplicate-owner)
  fm_write_meta "$world/child/state/other-task.meta" \
    'kind=ship' 'mode=local-only' "worktree=$world/worker"
  set +e
  run_ready "$world" > "$world/duplicate.out" 2> "$world/duplicate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate worker ownership was accepted"
  assert_grep 'duplicate task ownership' "$world/duplicate.err" \
    "duplicate ownership refusal was not explicit"
  assert_absent "$world/child/data/local-task/local-ready" \
    "duplicate ownership published a ready artifact"
  printf 'worktree=%s\n' "$world/worker" >> "$world/child/state/other-task.meta"
  if run_ready "$world" > "$world/malformed-owner.out" 2> "$world/malformed-owner.err"; then
    fail 'duplicate worktree fields hid a competing owner'
  fi
  assert_absent "$world/child/data/local-task/local-ready" \
    'malformed competing owner published a ready artifact'

  world=$(make_world alias-owner)
  ln -s "$world/worker" "$world/worker-alias"
  fm_write_meta "$world/child/state/other-task.meta" \
    'kind=ship' 'mode=local-only' "worktree=$world/worker-alias"
  set +e
  run_ready "$world" > "$world/alias.out" 2> "$world/alias.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "alias of an already-owned worker was accepted"
  assert_grep 'duplicate task ownership' "$world/alias.err" \
    "alias ownership refusal was not explicit"
  assert_absent "$world/child/data/local-task/local-ready" \
    "alias ownership published a ready artifact"

  world=$(make_world symlink-parent-data)
  mv "$world/parent/data" "$world/parent-data.saved"
  ln -s "$world/parent-data.saved" "$world/parent/data"
  head=$(git -C "$world/worker" rev-parse HEAD)
  set +e
  run_ready "$world" > "$world/parent-data.out" 2> "$world/parent-data.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked parent data directory was accepted"
  assert_equals "$head" "$(git -C "$world/worker" rev-parse HEAD)" \
    "symlinked parent data refusal moved the task head"
  assert_present "$world/child/state/local-task.meta" \
    "symlinked parent data refusal discarded child ownership"
  assert_absent "$world/child/data/local-task/local-ready" \
    "symlinked parent data directory allowed a ready artifact"

  other=$(git -C "$TMP_ROOT/foreign-head/worker" rev-parse HEAD)
  [ -n "$other" ] || fail "refusal fixtures lost their committed worker source"
  pass "delivery refuses dirty, diverged, foreign, changed, symlinked, duplicate, and alias identities without discarding work"
}

case ${FM_LOCAL_DELIVERY_TEST_CASE:-all} in
  receipt-recovery)
    test_landing_recovers_receipt_after_parent_progress
    ;;
  child-sync)
    test_happy_lifecycle
    test_child_local_merge_is_not_parent_landing
    test_child_sync_failure_is_receipted_and_retryable
    test_child_default_refusals_preserve_both_repositories
    ;;
  all)
    test_happy_lifecycle
    test_child_local_merge_is_not_parent_landing
    test_dirty_ready_refuses
    test_landing_recovers_receipt_after_parent_progress
    test_child_sync_failure_is_receipted_and_retryable
    test_child_default_refusals_preserve_both_repositories
    test_teardown_refuses_missing_or_advanced_worker
    test_parent_advance_is_reachable_through_refresh
    test_reused_task_same_head_has_distinct_delivery_identity
    test_landing_refusals_preserve_work
    ;;
  *)
    fail "unknown FM_LOCAL_DELIVERY_TEST_CASE: $FM_LOCAL_DELIVERY_TEST_CASE"
    ;;
esac
