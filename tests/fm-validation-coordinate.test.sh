#!/usr/bin/env bash
# Behavior coverage for exclusive validation ownership and correlated reporting.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-validation-coordinate)
PARENT="$TMP_ROOT/parent"
MATE_A="$TMP_ROOT/mate-a"
MATE_B="$TMP_ROOT/mate-b"
WORKER="$TMP_ROOT/worker-home"
WORKTREE="$TMP_ROOT/worker"
mkdir -p "$PARENT/state" "$MATE_A/state" "$MATE_B/state" "$WORKER/state" "$WORKTREE"

git -C "$WORKTREE" init -q --initial-branch=validation
git -C "$WORKTREE" config user.name fixture
git -C "$WORKTREE" config user.email fixture@example.invalid
printf 'fixture\n' > "$WORKTREE/input"
git -C "$WORKTREE" add input
git -C "$WORKTREE" commit -qm fixture

for mate in "$MATE_A" "$MATE_B"; do
  printf '%s\n' "${mate##*/}" > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$mate/.fm-secondmate-parent"
done
printf 'worker-mate\n' > "$WORKER/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$WORKER/.fm-secondmate-parent"
mkdir -p "$PARENT/data"
cat > "$PARENT/data/secondmates.md" <<EOF
- mate-a - Coordinates validation requests. (home: $MATE_A; scope: validation; projects: sample; added 2026-09-14)
- mate-b - Coordinates other validation requests. (home: $MATE_B; scope: other validation; projects: sample; added 2026-09-14)
- worker-mate - Owns the bounded validation worker. (home: $WORKER; scope: worker; projects: sample; added 2026-09-14)
EOF
cat > "$WORKER/state/validator.meta" <<EOF
worktree=$WORKTREE
project=sample
kind=ship
mode=no-mistakes
spawn_gen=validator-generation
EOF

# fm-secondmate-report is exercised as the public routing helper. Its local
# parent destination needs the coordinator's task record in the parent home.
cat > "$PARENT/state/mate-a.meta" <<EOF
kind=secondmate
home=$MATE_A
window=fixture:fm-mate-a
backend=tmux
worktree=$MATE_A
spawn_gen=mate-a-generation
EOF
cat > "$PARENT/state/mate-b.meta" <<EOF
kind=secondmate
home=$MATE_B
window=fixture:fm-mate-b
backend=tmux
worktree=$MATE_B
spawn_gen=mate-b-generation
EOF

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SEND_LOG="$TMP_ROOT/send.log"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "$SEND_LOG"; exit 0 ;;
  display-message) printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-mate-a\nfm-mate-b\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/sleep"

PATH="$FAKEBIN:$PATH" SEND_LOG="$SEND_LOG" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" mate-a "validation-run=run-1 worker=worker-mate/validator" >/dev/null 2>&1
PENDING=$(find "$PARENT/state/pending-replies" -maxdepth 1 -type f | head -1)
[ -n "$PENDING" ] || fail "real fm-send did not create a pending routed request"
CORR=${PENDING##*/}
cp "$PENDING" "$PENDING.original"
sed 's/validation-run=run-1/validation-run=run-10/' "$PENDING.original" > "$PENDING"
set +e
PREFIX=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a prefix run token authorized a different validation request"
assert_contains "$PREFIX" "exact token validation-run=run-1" "prefix-run refusal was not explicit"
mv "$PENDING.original" "$PENDING"

cp "$PENDING" "$PENDING.original"
sed 's/worker=worker-mate\/validator/worker=worker-mate\/other-task/' "$PENDING.original" > "$PENDING"
set +e
WRONG_WORKER=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a request for another worker task authorized this claim"
assert_contains "$WRONG_WORKER" "exact worker token worker=worker-mate/validator" \
  "wrong-worker refusal was not explicit"
mv "$PENDING.original" "$PENDING"

OUT=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator)
assert_contains "$OUT" 'claimed: run-1 owner=validator' "claim did not expose its owner"
assert_contains "$(cat "$PARENT/state/mate-a.status")" "working [corr=$CORR]: validation run run-1 exclusively claimed" \
  "claim progress did not traverse the correlated parent route"

# The exact same owner can retry, while a second coordinator cannot take over
# or report against the first coordinator's claim.
FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator >/dev/null
[ "$(grep -c "exclusively claimed" "$PARENT/state/mate-a.status")" -eq 1 ] \
  || fail "an idempotent claim retry duplicated parent progress"
# The receipt is the single report-once gate, so reporting is at-least-once:
# a claim interrupted before its receipt lands repeats that one progress line.
rm "$PARENT/state/validation-runs/run-1.claim.reported"
FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator >/dev/null
[ "$(grep -c "exclusively claimed" "$PARENT/state/mate-a.status")" -eq 2 ] \
  || fail "claim retry after a lost report receipt did not re-report parent progress"
[ -f "$PARENT/state/validation-runs/run-1.claim.reported" ] \
  || fail "claim retry did not recover its report receipt"
FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator >/dev/null
[ "$(grep -c "exclusively claimed" "$PARENT/state/mate-a.status")" -eq 2 ] \
  || fail "a recovered report receipt did not suppress the next claim report"

# A claim binds exactly one head. When the same coordinator, worker home and
# task retry after the worker committed again, the refusal names the advanced
# head instead of blaming another owner, and the claim keeps its bound head.
CLAIMED_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
printf 'advanced\n' >> "$WORKTREE/input"
git -C "$WORKTREE" commit -qam advanced
ADVANCED_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
set +e
ADVANCED=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "an advanced worker head was adopted by the existing claim"
assert_contains "$ADVANCED" "the worker advanced to $ADVANCED_HEAD" \
  "advanced-head refusal did not name the new head"
case "$ADVANCED" in
  *"already has a different owner"*) fail "an own-claim retry was blamed on a different owner" ;;
esac
[ "$(sed -n 's/^head=//p' "$PARENT/state/validation-runs/run-1.claim")" = "$CLAIMED_HEAD" ] \
  || fail "a refused claim retry rebound the run to the advanced head"
[ "$(grep -c "exclusively claimed" "$PARENT/state/mate-a.status")" -eq 2 ] \
  || fail "a refused claim retry reported progress"
git -C "$WORKTREE" reset -q --hard "$CLAIMED_HEAD"

# A worker that left the claimed branch is not a head advance, so the generic
# stale-identity refusal stands instead of new-head re-routing advice.
git -C "$WORKTREE" checkout -q -b other-validation
printf 'other branch\n' >> "$WORKTREE/input"
git -C "$WORKTREE" commit -qam other
set +e
SWITCHED=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-1 "$CORR" "$WORKER" validator 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a switched worker branch was adopted by the existing claim"
assert_contains "$SWITCHED" "already has a different owner" \
  "a branch switch was not refused as a conflicting claim identity"
case "$SWITCHED" in
  *"advanced to"*) fail "a branch switch was reported as a head advance" ;;
esac
[ "$(sed -n 's/^branch=//p' "$PARENT/state/validation-runs/run-1.claim")" = validation ] \
  || fail "a refused branch switch rebound the claim to another branch"
[ "$(sed -n 's/^head=//p' "$PARENT/state/validation-runs/run-1.claim")" = "$CLAIMED_HEAD" ] \
  || fail "a refused branch switch rebound the claim to another head"
git -C "$WORKTREE" checkout -q validation
git -C "$WORKTREE" branch -qD other-validation
git -C "$WORKTREE" reset -q --hard "$CLAIMED_HEAD"

MATE_COPY="$TMP_ROOT/mate-a-copy"
mkdir -p "$MATE_COPY/state"
printf 'mate-a\n' > "$MATE_COPY/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE_COPY/.fm-secondmate-parent"
set +e
COPIED=$(FM_HOME="$MATE_COPY" "$ROOT/bin/fm-validation-coordinate.sh" status run-1 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a copied coordinator home used the registered mate identity"
assert_contains "$COPIED" "coordinator home is not registered to this parent" \
  "copied-home refusal was not explicit"

mv "$PARENT/data" "$PARENT/data-real"
ln -s "$PARENT/data-real" "$PARENT/data"
set +e
SYMLINK_DATA=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" status run-1 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a symlinked parent data directory was consumed"
assert_contains "$SYMLINK_DATA" "parent data directory is unsafe" \
  "symlinked-parent-data refusal was not explicit"
rm "$PARENT/data"
mv "$PARENT/data-real" "$PARENT/data"

cp "$PARENT/data/secondmates.md" "$PARENT/data/secondmates.original"
grep -v '^- worker-mate ' "$PARENT/data/secondmates.original" > "$PARENT/data/secondmates.md"
set +e
MOVED_WORKER=$(FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" status run-1 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a removed worker registration remained authorized"
assert_contains "$MOVED_WORKER" "worker home is not registered to this parent" \
  "removed-worker-registration refusal was not explicit"
mv "$PARENT/data/secondmates.original" "$PARENT/data/secondmates.md"
set +e
FOREIGN=$(FM_HOME="$MATE_B" "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' forged 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a second coordinator reported against another coordinator's run"
assert_contains "$FOREIGN" "belongs to another coordinator" "foreign-coordinator refusal was not explicit"

NM_LOG="$TMP_ROOT/no-mistakes.log"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NM_LOG"
run_id=${4:-}
[ "${NM_WRONG_ID:-0}" != 1 ] || run_id=foreign-run
head=${NM_HEAD:-deadbeef}
printf 'run:\n  id: %s\n  branch: validation\n  head: %s\n  status: %s\n' "$run_id" "$head" "${NM_STATUS:-running}"
[ -z "${NM_OUTCOME:-}" ] || printf '  outcome: %s\n' "$NM_OUTCOME"
if [ "${NM_FOREIGN_ACTIVE:-0}" = 1 ]; then
  printf 'branch_sync:\n  state: pipeline_owned\n'
elif [ -n "${NM_LOCAL_HEAD:-}" ]; then
  printf 'branch_sync:\n  state: %s\n  local:\n    branch: %s\n    head: "%s"\n    clean: true\n' \
    "${NM_SYNC_STATE:-local_owned}" "${NM_LOCAL_BRANCH:-validation}" "$NM_LOCAL_HEAD"
fi
SH
chmod +x "$FAKEBIN/no-mistakes"
NM_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
set +e
FOREIGN_ACTIVE=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_FOREIGN_ACTIVE=1 FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" attach-run run-1 fixture-run 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "first attach trusted unanchored pipeline-owned custody"
assert_contains "$FOREIGN_ACTIVE" "run head does not continue" \
  "unanchored active-run refusal was not explicit"

PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" attach-run run-1 fixture-run >/dev/null

PATH="$FAKEBIN:$PATH" SEND_LOG="$SEND_LOG" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" mate-a "validation-run=run-2 worker=worker-mate/validator" >/dev/null 2>&1
PENDING_2=
for candidate in "$PARENT/state/pending-replies"/*; do
  [ "$candidate" = "$PENDING" ] || PENDING_2=$candidate
done
[ -n "$PENDING_2" ] || fail "second real fm-send did not create a distinct pending request"
CORR_2=${PENDING_2##*/}
FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-2 "$CORR_2" "$WORKER" validator >/dev/null
set +e
DUPLICATE_ACTUAL=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" attach-run run-2 fixture-run 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "two validation requests attached the same actual no-mistakes run"
assert_contains "$DUPLICATE_ACTUAL" "already has a different validation owner" \
  "duplicate actual-run ownership refusal was not explicit"

PATH="$FAKEBIN:$PATH" SEND_LOG="$SEND_LOG" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-send.sh" mate-a "validation-run=run-local worker=worker-mate/validator" >/dev/null 2>&1
PENDING_LOCAL=
for candidate in "$PARENT/state/pending-replies"/*; do
  [ "$candidate" = "$PENDING" ] || [ "$candidate" = "$PENDING_2" ] || PENDING_LOCAL=$candidate
done
[ -n "$PENDING_LOCAL" ] || fail "local-only request did not get its own pending correlation"
CORR_LOCAL=${PENDING_LOCAL##*/}
sed 's/^mode=.*/mode=local-only/' "$WORKER/state/validator.meta" > "$WORKER/state/validator.meta.next"
mv "$WORKER/state/validator.meta.next" "$WORKER/state/validator.meta"
FM_HOME="$MATE_A" "$ROOT/bin/fm-validation-coordinate.sh" claim run-local "$CORR_LOCAL" "$WORKER" validator >/dev/null
set +e
LOCAL_ATTACH=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" attach-run run-local local-run 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a local-only worker attached a publishing no-mistakes run"
assert_contains "$LOCAL_ATTACH" "local-only workers cannot attach" \
  "local-only no-mistakes capability refusal was not explicit"
sed 's/^mode=.*/mode=no-mistakes/' "$WORKER/state/validator.meta" > "$WORKER/state/validator.meta.next"
mv "$WORKER/state/validator.meta.next" "$WORKER/state/validator.meta"

STATUS=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" status run-1)
assert_contains "$STATUS" 'claim: run=run-1 owner=validator' "status omitted the immutable owner identity"
assert_contains "$STATUS" 'id: fixture-run' "status did not expose the AXI status evidence"
[ "$(tail -1 "$NM_LOG")" = 'axi status --run fixture-run' ] \
  || fail "status drove something other than the supported read-only AXI status interface: $(cat "$NM_LOG")"

set +e
WRONG=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" NM_WRONG_ID=1 FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" status run-1 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "status accepted a different run than the requested attachment"
assert_contains "$WRONG" "returned run 'foreign-run', expected 'fixture-run'" "wrong-run refusal was not explicit"

set +e
PREMATURE=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' premature 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a running AXI run was reported as done"
assert_contains "$PREMATURE" "done requires a passed or checks-passed AXI outcome" \
  "premature-done refusal was not explicit"

PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" NM_OUTCOME=checks-passed FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' "review evidence captured" >/dev/null
assert_contains "$(cat "$PARENT/state/mate-a.status")" \
  "done [corr=$CORR]: validation run run-1 owner-reported by validator: review evidence captured" \
  "owner result lost its request correlation or evidence classification"

mv "$PARENT/state/validation-runs" "$PARENT/state/validation-runs-real"
ln -s "$PARENT/state/validation-runs-real" "$PARENT/state/validation-runs"
set +e
REDIRECTED=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" status run-1 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a symlink redirected the authoritative claim store"
assert_contains "$REDIRECTED" "validation claim directory is unsafe" "claim-store symlink refusal was not explicit"
rm "$PARENT/state/validation-runs"
mv "$PARENT/state/validation-runs-real" "$PARENT/state/validation-runs"

# A local advance that the attached run does not contain invalidates later reports.
printf 'advanced\n' >> "$WORKTREE/input"
git -C "$WORKTREE" add input
git -C "$WORKTREE" commit -qm advanced
set +e
STALE=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$NM_HEAD" NM_OUTCOME=checks-passed FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' stale 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a changed worker head reported against the old validation run"
assert_contains "$STALE" "run head does not continue" "stale-head refusal was not explicit"

ADVANCED_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$ADVANCED_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 working "pipeline fix head captured" >/dev/null
assert_contains "$(cat "$PARENT/state/mate-a.status")" \
  "working [corr=$CORR]: validation run run-1 owner-reported by validator: pipeline fix head captured" \
  "a run-attributed pipeline head advance could not continue reporting"

# The real terminal shape: the pipeline's own fix commits finish the run, so its
# final head is not an object this worker copy has. The daemon's branch_sync
# record of this worker's branch and head is what proves the identity.
PIPELINE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
set +e
UNPROVEN=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$PIPELINE_HEAD" NM_STATUS=completed \
  NM_OUTCOME=passed FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' "no provenance" 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a terminal run with no branch_sync provenance was accepted"
assert_contains "$UNPROVEN" "run head does not continue" "unprovenanced terminal refusal was not explicit"

set +e
FOREIGN_LOCAL=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$PIPELINE_HEAD" NM_STATUS=completed \
  NM_OUTCOME=passed NM_LOCAL_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' "foreign worker" 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a terminal run recorded against another worker head was accepted"
assert_contains "$FOREIGN_LOCAL" "run head does not continue" "changed-identity terminal refusal was not explicit"

set +e
FOREIGN_BRANCH=$(PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$PIPELINE_HEAD" NM_STATUS=completed \
  NM_OUTCOME=passed NM_LOCAL_HEAD="$ADVANCED_HEAD" NM_LOCAL_BRANCH=other-branch FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' "foreign branch" 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a terminal run recorded against another branch was accepted"
assert_contains "$FOREIGN_BRANCH" "run head does not continue" "foreign-branch terminal refusal was not explicit"

PATH="$FAKEBIN:$PATH" NM_LOG="$NM_LOG" NM_HEAD="$PIPELINE_HEAD" NM_STATUS=completed \
  NM_OUTCOME=passed NM_LOCAL_HEAD="$ADVANCED_HEAD" FM_HOME="$MATE_A" \
  "$ROOT/bin/fm-validation-coordinate.sh" owner-result run-1 'done' "pipeline fixes passed" >/dev/null
assert_contains "$(cat "$PARENT/state/mate-a.status")" \
  "done [corr=$CORR]: validation run run-1 owner-reported by validator: pipeline fixes passed" \
  "a terminal run finished by pipeline commits could not be reported"

pass "validation coordination keeps one global owner and correlates owner-reported evidence"
