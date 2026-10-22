#!/usr/bin/env bash
# Series: the platform configuration article — acceptance: project onboarding checklist (including namespace boundaries)
# One PASS/FAIL line per check, then a summary line; exits
# non-zero when any check fails. The dispatcher result check (every expected
# project listed in `onboarding-runs` has a child run with Succeeded=True) is
# not scripted, check it by hand. Reads the
# cluster; check 6 creates a probe Pod (deleted afterwards) and check 7
# deletes a RoleBinding that GitOps must restore (the script re-creates it from
# a saved copy when GitOps does not), so check 7 runs only with
# ALLOW_MUTATING=true.
set -u

# ---- placeholders: replace or export before running --------------------------
PROJECT="${PROJECT:-}"
# OTHER_PROJECT is used as a namespace name: the project namespace of ANOTHER
# project. A namespace of $PROJECT that has no pull Secret (for example
# $PROJECT-cd) also gives PASS for 6b and says nothing about other projects.
OTHER_PROJECT="${OTHER_PROJECT:-}"   # a project with no imagePullFrom entry for $PROJECT
WORKLOAD_NAMESPACES="${WORKLOAD_NAMESPACES:-$PROJECT $PROJECT-test $PROJECT-prod}"
BUILD_NS="${BUILD_NS:-$PROJECT-build}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
TEST_APPLICATION="${TEST_APPLICATION:-$PROJECT-test}"      # Argo CD Application of envs/test
GITOPS_REPOSITORY_CR="${GITOPS_REPOSITORY_CR:-$PROJECT-gitops}" # PaC Repository of the GitOps repository
EXPECTED_CONNECTORS="${EXPECTED_CONNECTORS:-4}"
# Image in the $PROJECT Harbor project that exists and is pullable from $PROJECT.
# Onboarding pushes no image: run the first CI of the delivery article (sample-app/) on
# main before check 6, or the pull checks cannot tell "missing" from "denied".
PROJECT_IMAGE="${PROJECT_IMAGE:-}"                           # registry.example.com/shop/hello@sha256:...
DRIFT_ROLEBINDING="${DRIFT_ROLEBINDING:-$PROJECT-owners}"   # rendered from the platform repository template rolebinding-owners.yaml
ALLOW_MUTATING="${ALLOW_MUTATING:-false}"
TEST_COMMENT_TIME="${TEST_COMMENT_TIME:-}"   # RFC 3339 UTC time just before commenting /test validate branch:<source-branch> on a merge request
ONBOARDING_NS="${ONBOARDING_NS:-platform-connectors}"
ONBOARDING_RERUN="${ONBOARDING_RERUN:-}"     # name of a manual re-run of the onboarding PipelineRun
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"
# 600 seconds: on ACP Argo CD attempts the automated sync of `projects` once
# every five minutes, so the restore can take a full cycle; 600 covers one
# cycle more.
SYNC_WAIT_SECONDS="${SYNC_WAIT_SECONDS:-600}"
# -------------------------------------------------------------------------------

pass=0
fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; fail=$((fail + 1)); }
k() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

if [ -z "$PROJECT" ] || [ -z "$OTHER_PROJECT" ] || [ "$PROJECT" = "$OTHER_PROJECT" ]; then
  ko "onboarding-safety set PROJECT and a different OTHER_PROJECT to isolated acceptance projects"
  printf '== result: %s pass / %s fail ==\n' "$pass" "$fail"
  exit 1
fi

# Probe Pod that satisfies the `restricted` Pod Security level. Other
# admission failures still need separate diagnosis; a bare `kubectl run` would be
# refused by Pod Security in these namespaces and prove nothing.
# imagePullPolicy Always forces a pull with the Pod's own credentials. With
# the default (IfNotPresent for a digest reference), and where the cluster's
# kubelet does not re-verify credentials of images already on the node, the
# kubelet starts the other project's Pod from the copy that the positive
# control has just put on the node, and 6b fails.
probe_name="acceptance-onboarding-$(date +%s)-$$" # Unique Pod name in each probe namespace.
probe_namespaces=() # Namespaces in which this invocation created that Pod.
probe_pod() { # $1 namespace, $2 image; record only successful creates.
  if k -n "$1" create -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $probe_name
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
      imagePullPolicy: Always
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
YAML
  then
    probe_namespaces+=("$1")
    return 0
  fi
  return 1
}

cleanup_probes() { # Remove only this invocation's successfully created probes.
  local probe_namespace # One namespace recorded after creation.
  for probe_namespace in "${probe_namespaces[@]}"; do
    k -n "$probe_namespace" delete pod "$probe_name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup_probes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Waits until the probe's container is running or waiting for a reason from
# the regex in $2; prints the state it saw.
probe_state() { # $1 namespace, $2 regex of expected states
  local s=""
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    s=$(k -n "$1" get pod "$probe_name" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
    printf '%s\n' "$s" | grep -Eq "$2" && break
    sleep 1
  done
  printf '%s\n' "$s"
}

# 2. Namespace boundaries (the namespace-boundary section and onboarding acceptance row 2): workload namespaces enforce
# `restricted`; the build namespace is `baseline` so buildah can run.
for ns in $WORKLOAD_NAMESPACES; do
  lv=$(k get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
  if [ "$lv" = "restricted" ]; then ok "onboarding-workload-security $ns enforces restricted"; else ko "onboarding-workload-security $ns enforces restricted: got '$lv'"; fi
done
lv=$(k get ns "$BUILD_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
if [ "$lv" = "baseline" ]; then ok "onboarding-build-security $BUILD_NS enforces baseline"; else ko "onboarding-build-security $BUILD_NS enforces baseline: got '$lv'"; fi

# 3. The four project-level Connectors are ready. Reads the Ready condition
# instead of parsing the table columns of `kubectl get connectors`. It counts
# every Connector in $PROJECT: a project that has added Connectors of its own
# sets EXPECTED_CONNECTORS to the new total.
label="onboarding-connectors $EXPECTED_CONNECTORS Connectors ready in $PROJECT"
rows=$(k -n "$PROJECT" get connectors.connectors.alauda.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
total=$(printf '%s\n' "$rows" | grep -c '=')
ready=$(printf '%s\n' "$rows" | grep -c '=True$')
if [ "$total" -eq "$EXPECTED_CONNECTORS" ] && [ "$ready" -eq "$total" ]; then
  ok "$label"
else
  ko "$label: $ready ready of $total ($(printf '%s' "$rows" | tr '\n' ' '))"
fi

# 4. The project GitOps repository exists and its test Application is synced.
# Right after onboarding, envs/test still holds the seeded placeholder digest,
# so the Pod cannot start and health is not Healthy yet; health is only
# expected to be Healthy after the first CD run to test (the delivery article). The check
# therefore requires Synced and prints the health it saw.
label="onboarding-application Argo CD $TEST_APPLICATION Synced"
st=$(k -n "$ARGOCD_NS" get applications.argoproj.io "$TEST_APPLICATION" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
case "$st" in
  "Synced Healthy") ok "$label (Healthy)" ;;
  Synced\ *) ok "$label (health '${st#Synced }': Healthy only after the first CD run to test)" ;;
  *) ko "$label: got '$st'" ;;
esac

# 5. A `/test` comment starts a PipelineRun in the project. Posting the comment
# is manual (`/test validate branch:<source-branch>` on a merge request of
# the GitOps repository; on a merge request PaC runs its source branch and
# does not use `branch:`). This check waits for the newest run created after
# TEST_COMMENT_TIME that the comment started, and for it to succeed. validate
# also runs on every merge request update, so the run is selected by the
# PipelineRun labels PaC sets (upstream pkg/kubeinteraction/labels.go,
# pkg/resolve/resolve.go): original-prname=validate (the PipelineRun name in
# .tekton/) and the event type of a `/test <name>` comment. On
# Pipelines-as-Code v0.48.1 that type is test-comment, and every such run
# gets the warning "the test-comment event type is deprecated, this will be
# changed to pull_request in the future", so both values are accepted. On
# GitLab the run that opening the merge request starts carries
# event-type=Merge_Request, which cannot pass this check.
# Precondition: the render task of .tekton/validate.yaml on main has its tool
# image set; the seeded file keeps the <tag> placeholder of the template
# until then. Where the optional resolver constraint is in Enforce, the file
# must reference a published Pipeline instead of its inline definition.
# TEST_COMMENT_TIME is the time taken just before posting the comment; the
# FAIL hint below means: note the time, post the comment, then export it.
label="onboarding-validation /test validate starts a run that succeeds"
if [ -z "$TEST_COMMENT_TIME" ]; then
  ko "$label: comment first, then set TEST_COMMENT_TIME (RFC 3339 UTC)"
else
  result=""
  validation_deadline=$((SECONDS + WAIT_SECONDS)) # Bound elapsed time, not five-second iterations.
  while [ "$SECONDS" -lt "$validation_deadline" ]; do
    # RFC 3339 UTC timestamps sort lexically, so a string comparison is a time
    # comparison here.
    run=$(k -n "$PROJECT" get pipelinerun \
      -l "pipelinesascode.tekton.dev/repository=$GITOPS_REPOSITORY_CR,pipelinesascode.tekton.dev/event-type in (test-comment,pull_request),pipelinesascode.tekton.dev/original-prname=validate" \
      -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.metadata.name}{"\n"}{end}' 2>/dev/null |
      awk -v t="$TEST_COMMENT_TIME" '$1 >= t' | sort | tail -1 | cut -d' ' -f2)
    if [ -n "$run" ]; then
      result=$(k -n "$PROJECT" get pipelinerun "$run" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
      [ "$result" = "True" ] || [ "$result" = "False" ] && break
    fi
    validation_pause=$((validation_deadline - SECONDS)) # Remaining seconds, capped at the poll interval.
    [ "$validation_pause" -le 0 ] && break
    [ "$validation_pause" -le 5 ] || validation_pause=5
    sleep "$validation_pause"
  done
  if [ "${result:-}" = "True" ]; then ok "$label ($run)"; else ko "$label: /test-started run='${run:-none}' Succeeded='${result:-}'"; fi
fi

# 6. Cross-project pull is refused. Positive control first: the same image
# must start in the owning project; 6b runs only when it did. The positive
# control is what proves the image exists: for a private Harbor project a
# missing image and a refused pull produce the same event text ("pull access
# denied ... authorization failed"), so 6b's check of the events for 401 /
# unauthorized / denied cannot tell them apart on its own.
if [ -z "$PROJECT_IMAGE" ]; then
  ko "onboarding-cross-project-positive positive control: set PROJECT_IMAGE"
  ko "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images: set PROJECT_IMAGE"
else
  positive=""
  if probe_pod "$PROJECT" "$PROJECT_IMAGE" >/dev/null 2>&1; then
    s=$(probe_state "$PROJECT" '^[0-9]{4}-|ImagePullBackOff|ErrImagePull')
    case "$s" in
      [0-9][0-9][0-9][0-9]-*)
        positive=yes
        ok "onboarding-cross-project-positive positive control: image starts in $PROJECT"
        ;;
      *) ko "onboarding-cross-project-positive positive control: image starts in $PROJECT: state '$s'" ;;
    esac
  else
    ko "onboarding-cross-project-positive positive control: probe Pod not admitted in $PROJECT"
  fi

  if [ -z "$positive" ]; then
    # Without a passing positive control a pull error proves nothing.
    ko "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images: not checked, positive control onboarding-cross-project-positive failed"
  elif probe_pod "$OTHER_PROJECT" "$PROJECT_IMAGE" >/dev/null 2>&1; then
    s=$(probe_state "$OTHER_PROJECT" '^[0-9]{4}-|ImagePullBackOff|ErrImagePull')
    case "$s" in
      ImagePullBackOff | ErrImagePull)
        # Select by UID so events of an earlier probe with the same name
        # cannot decide the result.
        uid=$(k -n "$OTHER_PROJECT" get pod "$probe_name" -o jsonpath='{.metadata.uid}' 2>/dev/null)
        ev=$(k -n "$OTHER_PROJECT" get events --field-selector "involvedObject.uid=$uid" \
          -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null)
        # Match 401 only as a standalone number: a bare `401` also hits the
        # hex digest in "Failed to pull image ...@sha256:..." messages.
        if printf '%s\n' "$ev" | grep -Eqi 'unauthorized|(^|[^[:alnum:]])401([^[:alnum:]]|$)|denied|forbidden'; then
          ok "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images ($s, unauthorized)"
        else
          ko "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images: $s without an authorization error in the events"
        fi
        ;;
      *) ko "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images: state '$s'" ;;
    esac
  else
    ko "onboarding-cross-project-negative $OTHER_PROJECT cannot pull $PROJECT images: probe Pod not admitted (check Pod Security, not the pull)"
  fi
fi

# 7. A manual change is reverted by GitOps (selfHeal): delete a RoleBinding
# that onboarding manages and wait for it to come back. The UID tells the
# re-created object from the original one: a delete that was refused or has not
# completed leaves the original in place, which must not count as restored.
# The object is saved first and re-created by the script when GitOps does not
# restore it in time, so a failed check does not leave the project without it.
label="onboarding-self-healing deleted RoleBinding $PROJECT/$DRIFT_ROLEBINDING is restored"
if [ "$ALLOW_MUTATING" != "true" ]; then
  ko "$label: skipped, set ALLOW_MUTATING=true to run"
elif ! old_uid=$(k -n "$PROJECT" get rolebinding "$DRIFT_ROLEBINDING" -o jsonpath='{.metadata.uid}' 2>/dev/null) || [ -z "$old_uid" ]; then
  ko "$label: RoleBinding does not exist before the test"
elif ! saved=$(mktemp "${TMPDIR:-/tmp}/acceptance-rolebinding.XXXXXX") ||
  ! k -n "$PROJECT" get rolebinding "$DRIFT_ROLEBINDING" -o yaml --show-managed-fields=false >"$saved" 2>/dev/null; then
  ko "$label: could not save the RoleBinding before deleting it, nothing deleted"
elif ! out=$(k -n "$PROJECT" delete rolebinding "$DRIFT_ROLEBINDING" 2>&1); then
  ko "$label: delete failed, nothing changed: $out"
  rm -f "$saved"
else
  uid=""
  for _ in $(seq 1 "$SYNC_WAIT_SECONDS"); do
    uid=$(k -n "$PROJECT" get rolebinding "$DRIFT_ROLEBINDING" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    [ -n "$uid" ] && [ "$uid" != "$old_uid" ] && break
    sleep 1
  done
  if [ -n "$uid" ] && [ "$uid" != "$old_uid" ]; then
    ok "$label (re-created, uid $uid)"
    rm -f "$saved"
  elif [ -n "$uid" ]; then
    # Same UID: the original object was never removed, so there is nothing
    # to restore.
    ko "$label: the original RoleBinding (uid $old_uid) is still there after ${SYNC_WAIT_SECONDS}s, the delete did not take effect"
    rm -f "$saved"
  else
    # Server-set metadata of the saved copy is dropped (managedFields are
    # already left out above), so `create` accepts it as a new object.
    if out=$(sed -E '/^  (uid|resourceVersion|creationTimestamp|generation):/d' "$saved" | k -n "$PROJECT" create -f - 2>&1); then
      ko "$label: not re-created by GitOps after ${SYNC_WAIT_SECONDS}s; restored by the script from the saved copy"
      rm -f "$saved"
    else
      ko "$label: not re-created by GitOps after ${SYNC_WAIT_SECONDS}s; restore by the script failed ($out), saved copy: $saved"
    fi
  fi
fi

# 8. A re-run of onboarding creates no new tool-side object and rotates the
# tokens by design: the run succeeds, and each of the three Harbor TaskRuns
# reports robot-token-rotated=true, because the pipeline sets
# robotTokenPolicy: refresh (a new robot token on every run). Each TaskRun is
# judged on its own, selected by its tekton.dev/pipelineTask label.
# Limitation: `.items[0]` takes the first TaskRun the API lists for that label
# pair, unsorted. It assumes one TaskRun per pipeline task of the run; if
# `kubectl get taskrun -l tekton.dev/pipelineRun=<run>,tekton.dev/pipelineTask=<task>`
# lists more than one, read the result of the newest one by hand.
label="onboarding-rerun onboarding re-run succeeds and rotates the Harbor robot tokens"
if [ -z "$ONBOARDING_RERUN" ]; then
  ko "$label: re-run onboarding, then set ONBOARDING_RERUN"
else
  st=$(k -n "$ONBOARDING_NS" get pipelinerun "$ONBOARDING_RERUN" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null)
  bad=""
  for task in harbor-tenant harbor-staging-readonly harbor-release; do
    rot=$(k -n "$ONBOARDING_NS" get taskrun \
      -l "tekton.dev/pipelineRun=$ONBOARDING_RERUN,tekton.dev/pipelineTask=$task" \
      -o jsonpath='{.items[0].status.results[?(@.name=="robot-token-rotated")].value}' 2>/dev/null)
    [ "$rot" = "true" ] || bad="$bad $task='$rot'"
  done
  if [ "$st" = "True" ] && [ -z "$bad" ]; then ok "$label"; else ko "$label: Succeeded='$st' robot-token-rotated not true:${bad:- none}"; fi
fi

echo "== result: $pass pass / $fail fail =="
[ "$fail" -eq 0 ]
