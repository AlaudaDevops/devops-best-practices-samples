#!/usr/bin/env bash
# Series: 01 §11 — acceptance: from commit to production ("how do you know you are done" table)
# One PASS/FAIL line per check, then a summary line; exits
# non-zero when any check fails. Reads the cluster and the registry; the only
# object it creates is a short-lived probe Pod (check 4), deleted afterwards.
set -u

# ---- placeholders: replace or export before running --------------------------
PROJECT="${PROJECT:-shop}"
APP="${APP:-hello}"                                   # Deployment and container name
REGISTRY="${REGISTRY:-registry.example.com}"
STAGING_REPO="${STAGING_REPO:-$REGISTRY/$PROJECT/$APP}"
RELEASE_REPO="${RELEASE_REPO:-$REGISTRY/$PROJECT-prod/$APP}"
TEST_NS="${TEST_NS:-$PROJECT-test}"
PROD_NS="${PROD_NS:-$PROJECT-prod}"
CD_NS="${CD_NS:-$PROJECT-cd}"                         # where promotion runs
ARGOCD_NS="${ARGOCD_NS:-argocd}"
PROD_APPLICATION="${PROD_APPLICATION:-$PROJECT-prod}" # Argo CD Application of envs/prod
BUILD_DIGEST="${BUILD_DIGEST:-}"      # sha256:... reported by CI (IMAGE_DIGEST of build-image)
RELEASE_LABEL="${RELEASE_LABEL:-}"    # tag created by the promotion run, e.g. release-001
PROMOTION_RUN="${PROMOTION_RUN:-}"    # name of that promotion PipelineRun in CD_NS (the run that created RELEASE_LABEL)
UNSIGNED_IMAGE="${UNSIGNED_IMAGE:-}"  # repository@sha256:... of an image NOT signed by the platform
SIGNED_POLICY="${SIGNED_POLICY:-require-signed-images}" # Kyverno policy of the platform repository: policies/require-signed-images.yaml
#   (a ClusterPolicy is matched by its bare name; a namespaced Kyverno Policy appears in PolicyReports as <namespace>/<name>)
COSIGN_PUB="${COSIGN_PUB:-./cosign.pub}"
IGNORE_TLOG="${IGNORE_TLOG:-false}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
# 120, not 60: in Audit mode the PolicyReport of the probe Pod (check 4) can
# say `pass` first and `fail` only about 40 s after the Pod was created, which
# leaves 60 a margin of 20 s.
WAIT_SECONDS="${WAIT_SECONDS:-120}"
# -------------------------------------------------------------------------------

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; fail=$((fail + 1)); }
k() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }
is_digest() { printf '%s\n' "$1" | grep -Eq '^sha256:[0-9a-f]{64}$'; }

# A Deployment runs its .spec.template only once the rollout of that template
# is complete; the template alone says nothing about a rollout stuck in
# ImagePullBackOff while the old Pods keep serving. Same conditions as
# `kubectl rollout status`: the controller has observed the latest generation,
# every replica runs the current template and is available, no old replica is
# left, and at least one replica is requested. Polls up to WAIT_SECONDS; on
# failure $rollout_msg lists the fields that do not hold.
rollout_msg=""
rollout_complete() { # $1 namespace, $2 Deployment
  local s gen obs want upd avail total
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    s=$(k -n "$1" get deploy "$2" -o jsonpath='{.metadata.generation}|{.status.observedGeneration}|{.spec.replicas}|{.status.updatedReplicas}|{.status.availableReplicas}|{.status.replicas}' 2>/dev/null)
    if [ -z "$s" ]; then
      rollout_msg="Deployment $1/$2 not readable"
    else
      IFS='|' read -r gen obs want upd avail total <<EOF_STATUS
$s
EOF_STATUS
      # The controller omits zero counters from .status, so empty means 0.
      obs=${obs:-0} upd=${upd:-0} avail=${avail:-0} total=${total:-0}
      rollout_msg=""
      [ "$obs" -ge "$gen" ] || rollout_msg="$rollout_msg status.observedGeneration=$obs<metadata.generation=$gen"
      [ "$want" -ge 1 ] || rollout_msg="$rollout_msg spec.replicas=$want"
      [ "$upd" -eq "$want" ] || rollout_msg="$rollout_msg status.updatedReplicas=$upd!=spec.replicas=$want"
      [ "$avail" -eq "$want" ] || rollout_msg="$rollout_msg status.availableReplicas=$avail!=spec.replicas=$want"
      [ "$total" -eq "$want" ] || rollout_msg="$rollout_msg status.replicas=$total!=spec.replicas=$want (old replicas left)"
      [ -z "$rollout_msg" ] && return 0
    fi
    sleep 1
  done
  return 1
}

# Probe Pod that satisfies the `restricted` Pod Security level, so admission
# can only reject it for the image. In Audit mode a bare `kubectl run` gets
# only Kyverno warnings and is then rejected by Pod Security, so no Pod and
# no PolicyReport exist to check; in Enforce mode Kyverno (verifyImages runs
# in its mutating webhook, before Pod Security) rejects it first. This probe
# works in both modes.
probe_pod() { # $1 namespace, $2 image
  k -n "$1" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: acceptance-probe
  labels:
    app.kubernetes.io/part-of: acceptance
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $2
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
YAML
}

# 1. The digest CI built reaches test, by digest. In this sample the CD Run
# Template (sample-app/cd/run-template-test.yaml) is started by hand with the
# IMAGE_DIGEST result of the CI run on main; starting it automatically from a
# Harbor push event is the reference practice of series 01 §6.3, not part of
# this sample. "Runs" needs both: the Deployment template pins the digest, and
# the rollout of that template is complete (rollout_complete).
label="01§11-1 test runs the CI build by digest ($TEST_NS/$APP)"
img=$(k -n "$TEST_NS" get deploy "$APP" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$APP\")].image}" 2>/dev/null)
if ! is_digest "$BUILD_DIGEST"; then
  ko "$label: set BUILD_DIGEST=sha256:<64 hex>"
elif [ "$img" != "$STAGING_REPO@$BUILD_DIGEST" ]; then
  ko "$label: got '$img'"
elif rollout_complete "$TEST_NS" "$APP"; then
  ok "$label"
else
  ko "$label: template has the digest but the rollout is not complete after ${WAIT_SECONDS}s:$rollout_msg"
fi

# 2. The release registry holds the same content. skopeo copies by digest
# without converting the manifest format, so the release digest should equal
# the CI digest; when it differs, investigate (manifest conversion by the
# registry or the copy) before trusting the release. The Harbor projects are
# private and no credential is passed here: run `skopeo login` (or set
# REGISTRY_AUTH_FILE) with read access to the release project first.
label="01§11-2 release tag $RELEASE_REPO:$RELEASE_LABEL has the CI digest"
# Check 3b compares prod against this digest, so keep it defined even when
# this check cannot read the registry.
rel=""
if [ -z "$RELEASE_LABEL" ]; then
  ko "$label: set RELEASE_LABEL"
elif ! command -v skopeo >/dev/null 2>&1; then
  ko "$label: skopeo not installed"
else
  rel=$(skopeo inspect --format '{{.Digest}}' "docker://$RELEASE_REPO:$RELEASE_LABEL" 2>/dev/null)
  if [ -n "$rel" ] && [ "$rel" = "$BUILD_DIGEST" ]; then ok "$label"; else ko "$label: got '$rel'"; fi
fi

# 3. The prod Argo CD Application is in sync and healthy.
label="01§11-3 Argo CD $PROD_APPLICATION Synced Healthy"
st=$(k -n "$ARGOCD_NS" get applications.argoproj.io "$PROD_APPLICATION" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
if [ "$st" = "Synced Healthy" ]; then ok "$label"; else ko "$label: got '$st'"; fi

# 3b. Prod runs exactly the release of this acceptance: the RELEASE repository
# pinned to the digest that check 2 read from the release tag. A prefix match
# on "$RELEASE_REPO@sha256:" is not enough, because any earlier release in the
# same repository would pass it. As in check 1, the rollout of that template
# must also be complete.
label="01§11-3b prod runs $RELEASE_REPO@<digest of $RELEASE_LABEL>"
img=$(k -n "$PROD_NS" get deploy "$APP" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$APP\")].image}" 2>/dev/null)
if ! is_digest "$rel"; then
  ko "$label: check 2 read no release digest (RELEASE_LABEL, skopeo, registry login), got '$rel'"
elif [ "$img" != "$RELEASE_REPO@$rel" ]; then
  ko "$label: expected '$RELEASE_REPO@$rel', got '$img'"
elif rollout_complete "$PROD_NS" "$APP"; then
  ok "$label ($rel)"
else
  ko "$label: template has the digest but the rollout is not complete after ${WAIT_SECONDS}s:$rollout_msg"
fi

# 4. An unsigned image is refused by admission in prod: rejected at creation
# (Enforce) or recorded as a failed result in a PolicyReport (Audit) by the
# platform policy $SIGNED_POLICY (policies/require-signed-images.yaml of the
# platform repository; it matches the repositories of the release project).
# No earlier step produces UNSIGNED_IMAGE: the promotion Run Template is the
# only path the sample uses to write the release project, and its runs are
# signed. The sample does not deploy promotion guardrails 1-3
# (sample-app/README.md, "Operating notes and hardening"); the check does not
# rely on another way to write it either. A platform administrator pushes a
# throw-away unsigned image into the release project with the admin Harbor
# credential for this check and deletes it afterwards (acceptance/README.md).
label="01§11-4 unsigned image refused or reported in $PROD_NS"
if [ -z "$UNSIGNED_IMAGE" ]; then
  ko "$label: set UNSIGNED_IMAGE=<repository>@sha256:<digest>"
else
  k -n "$PROD_NS" delete pod acceptance-probe --ignore-not-found >/dev/null 2>&1
  if out=$(probe_pod "$PROD_NS" "$UNSIGNED_IMAGE" 2>&1); then
    # Created: only acceptable in Audit mode, where a report must appear.
    # Kyverno 1.15 writes one PolicyReport per resource and names the resource
    # in the report's `.scope` (its results carry no `resources` list), so the
    # report is selected by the uid of this probe Pod: a report left for the
    # probe Pod of an earlier run cannot match.
    # The report of an unsigned image can say `pass` ("image verified") first
    # and turn to `fail` ("no signatures found") only later, about 40 s after
    # the Pod is created (Kyverno 1.15.9). That first `pass` does not count;
    # the loop below waits for `fail` until WAIT_SECONDS is over.
    uid=$(k -n "$PROD_NS" get pod acceptance-probe -o jsonpath='{.metadata.uid}' 2>/dev/null)
    found=""
    for _ in $(seq 1 "$WAIT_SECONDS"); do
      found=$(k -n "$PROD_NS" get policyreports -o jsonpath="{range .items[?(@.scope.uid==\"$uid\")]}{range .results[?(@.policy==\"$SIGNED_POLICY\")]}{.result}{'\n'}{end}{end}" 2>/dev/null | grep -x fail)
      [ -n "$uid" ] && [ -n "$found" ] && break
      sleep 1
    done
    if [ -n "$found" ]; then ok "$label (Audit: reported)"; else ko "$label: Pod admitted and no failed PolicyReport result"; fi
  else
    if printf '%s\n' "$out" | grep -qi "$SIGNED_POLICY"; then ok "$label (Enforce: rejected)"; else ko "$label: rejected for another reason: $out"; fi
  fi
  k -n "$PROD_NS" delete pod acceptance-probe --ignore-not-found >/dev/null 2>&1
fi

# 5. The approval of this promotion is on record: the ApprovalTask that
# belongs to PROMOTION_RUN is approved and names who approved it. Ownership
# chain (Tekton Pipelines createCustomRun + Manual Approval Gate
# createApprovalTask): the PipelineRun owns the CustomRun of its approval task
# and labels it tekton.dev/pipelineRun=<run>; the gate creates the ApprovalTask
# owned by that CustomRun and copies the CustomRun's labels onto it. The label
# narrows the list; the owner chain (ApprovalTask -> CustomRun -> PipelineRun
# UID) is then checked so that a deleted and re-created run of the same name,
# or another run's ApprovalTask, cannot be picked. For a group approver the
# response carries the group name; the approving people are listed in its
# groupMembers, so both are printed.
label="01§11-5 ApprovalTask of promotion run $CD_NS/${PROMOTION_RUN:-<unset>} approved with an approver"
at=""
if [ -z "$PROMOTION_RUN" ]; then
  ko "$label: set PROMOTION_RUN=<promotion PipelineRun name in $CD_NS>"
elif ! pr_uid=$(k -n "$CD_NS" get pipelinerun "$PROMOTION_RUN" -o jsonpath='{.metadata.uid}' 2>/dev/null) || [ -z "$pr_uid" ]; then
  ko "$label: PipelineRun $PROMOTION_RUN not found in $CD_NS"
else
  owned=()
  for cand in $(k -n "$CD_NS" get approvaltasks.openshift-pipelines.org -l "tekton.dev/pipelineRun=$PROMOTION_RUN" -o name 2>/dev/null); do
    cr=$(k -n "$CD_NS" get "$cand" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="CustomRun")].name}' 2>/dev/null)
    [ -n "$cr" ] || continue
    cr_owner=$(k -n "$CD_NS" get customruns.tekton.dev "$cr" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="PipelineRun")].uid}' 2>/dev/null)
    [ "$cr_owner" = "$pr_uid" ] && owned+=("$cand")
  done
  # The sample promotion Pipeline has exactly one approval task
  # (wait-for-approval), so anything but one owned ApprovalTask is a failure.
  if [ "${#owned[@]}" -ne 1 ]; then
    ko "$label: expected 1 ApprovalTask owned by $PROMOTION_RUN, found ${#owned[@]}${owned[0]:+ (${owned[*]})}"
  else
    at="${owned[0]}"
    state=$(k -n "$CD_NS" get "$at" -o jsonpath='{.status.state}')
    who=$(k -n "$CD_NS" get "$at" -o jsonpath='{range .status.approversResponse[*]}{.name}={.response}{"["}{.groupMembers[*].name}{"] "}{end}')
    case "$state:$who" in
      approved:*=approved*) ok "$label ($at: $who)" ;;
      *) ko "$label: $at state='$state' responses='$who'" ;;
    esac
  fi
fi

# 6. Result shape: the release image carries a signature and a provenance
# attestation that verify with the platform key. Chains stores the promotion
# run's own signature and attestation beside the release image, pushed with
# the central registry credential of the Chains controller
# (platform-repo/components/chains-registry-credential.yaml; the promotion
# pushes through the production registry Connector, which Chains does not
# use, and the release identity's ServiceAccount holds no registry Secret).
# Only when the platform keeps signatures in a separate repository (optional
# hardening, sample-app/chains/README.md) set COSIGN_REPOSITORY.
label="01§11-6 release image signed and attested"
if ! command -v cosign >/dev/null 2>&1 || [ ! -s "$COSIGN_PUB" ]; then
  ko "$label: needs cosign and COSIGN_PUB"
elif [ "${img#"$RELEASE_REPO@sha256:"}" = "$img" ]; then
  # Check 3b found no release digest to verify.
  ko "$label: no release digest in $PROD_NS (see 3b)"
else
  rel_img="$RELEASE_REPO@${img##*@}"
  tlog=()
  [ "$IGNORE_TLOG" = "true" ] && tlog=(--insecure-ignore-tlog=true)
  if cosign verify --key "$COSIGN_PUB" ${tlog[@]+"${tlog[@]}"} "$rel_img" >/dev/null 2>&1 &&
    cosign verify-attestation --key "$COSIGN_PUB" --type slsaprovenance ${tlog[@]+"${tlog[@]}"} "$rel_img" >/dev/null 2>&1; then
    ok "$label ($rel_img)"
  else
    ko "$label ($rel_img)"
  fi
fi

echo "== result: $pass pass / $fail fail =="
[ "$fail" -eq 0 ]
