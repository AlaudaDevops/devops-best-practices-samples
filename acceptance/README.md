# Acceptance scripts

中文版本：[README.zh-CN.md](README.zh-CN.md)。

The acceptance tables in the [From Commit to Production on ACP](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/From_Commit_to_Production_on_ACP.md)
and [Managing Platform Configuration and Onboarding Isolated Projects with
Argo CD and Tekton on ACP](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Managing_Platform_Configuration_and_Onboarding_Isolated_Projects_with_Argo_CD_and_Tekton_on_ACP.md)
articles have companion scripts. They cover the checks below; CI source and
scan evidence, promotion-result correlation, GitOps review, and dispatcher
child-run completion still require the manual checks described here and in
the articles. The second script covers project and namespace boundaries.

> **Treat a FAIL as "look here".** The scripts read a cluster with the real
> tools behind it (GitLab, Harbor, Kyverno); expect to adjust names to your
> environment first. Check `onboarding-validation` needs the tool image of the seeded
> `.tekton/validate.yaml` to be set (see the prerequisites below).

| Script | Checks |
|---|---|
| `01-commit-to-production.sh` | test runs the CI digest (CD Run Template started by hand in this sample) · release tag has the same digest · prod Application `Synced Healthy` · prod runs the release repository pinned to exactly the digest of the release tag; "runs" in both Deployment checks means the Pod template pins the digest and its rollout is complete (observed generation current, all replicas updated and available, no old replica left, waited up to `WAIT_SECONDS`), and a FAIL names the fields that do not hold · signed positive-control image admitted with an image-specific successful PolicyReport · unsigned image refused (Enforce) or reported (Audit) by the platform policy `require-signed-images` (platform repository `policies/require-signed-images.yaml`) · the ApprovalTask owned by the promotion run `PROMOTION_RUN` (ApprovalTask → CustomRun → PipelineRun) approved with an approver · release image signature and provenance verify; for a group approval the approving members are printed too |
| `02-platform-and-onboarding.sh` | platform onboarding and namespace-boundary checks: workload namespaces `restricted`, build namespace `baseline` · four project Connectors ready · test Application `Synced` (`Healthy` only after the first test CD run) · `/test validate` starts a run that succeeds (only runs labelled `pipelinesascode.tekton.dev/original-prname=validate` whose `pipelinesascode.tekton.dev/event-type` is `test-comment` count, or `pull_request`, the value that Pipelines-as-Code v0.48.1 announces for a later version; on GitLab the run that opens the merge request starts carries `Merge_Request` and cannot pass it) · cross-project pull refused for authorization, not for a missing image (with a positive control) · deleted RoleBinding re-created by GitOps with a new UID · onboarding re-run succeeds and rotates the Harbor robot tokens by design |

Every check prints exactly one line, `PASS <label>` or `FAIL <label>`, and
each script ends with `== result: X pass / Y fail ==` and exits non-zero when
anything failed. Labels such as `delivery-signature` and `onboarding-application` are stable
script-local checklist IDs used to correlate output with this README; they are
not chapter numbers in the English articles.

When the platform installs `policies/no-bare-taskrun.yaml`, remember that it is
a cluster-wide `ClusterPolicy`: changing its `failureAction` affects every
namespace, and an Argo CD self-healing sync can restore the value. Perform this
check only on a dedicated acceptance cluster. Change the policy through a
reviewed platform-repository merge request and wait for Argo CD; do not edit the
live object or apply a per-namespace copy. In `Audit`, create a minimal direct
TaskRun as the project identity and confirm that it is admitted and records a
PolicyReport. Submit the platform-repository change to `Enforce`, repeat the
real request, and confirm that admission rejects it; restore `Audit` through a
merge request after the check. Delete the probe after both observations. A
server-side dry run does not create the PolicyReport used by the Audit assertion.

## Running

Every placeholder is an environment variable at the top of each script. The
registry and tool values have sample defaults (`registry.example.com`, ...),
but `PROJECT` must be set explicitly to an isolated acceptance project before
either script runs; neither script defaults to a production tenant. For the
second script, also set a different `OTHER_PROJECT` to another disposable
acceptance project. Finish the first promotion, production GitOps merge and
rollout before running the delivery script.

```bash
export KUBE_CONTEXT=<context>          # optional; default is the current context
export PROJECT=<isolated-acceptance-project>
BUILD_DIGEST=sha256:<digest> RELEASE_LABEL=release-001 PROMOTION_RUN=<pipelinerun> \
UNSIGNED_IMAGE=registry.example.com/"$PROJECT"-prod/acceptance-unsigned@sha256:<digest> \
COSIGN_PUB=./cosign.pub ./01-commit-to-production.sh

# ALLOW_MUTATING=true lets check `onboarding-self-healing` delete the disposable,
# subject-free RoleBinding <project>-self-healing-probe and wait for GitOps to re-create it; without it that check
# reports FAIL "skipped" and the run cannot pass.
OTHER_PROJECT=<second-isolated-acceptance-project> \
PROJECT_IMAGE=registry.example.com/"$PROJECT"/hello@sha256:<digest> \
TEST_COMMENT_TIME=<RFC 3339 UTC, just before commenting> \
ONBOARDING_RERUN=<pipelinerun> ALLOW_MUTATING=true ./02-platform-and-onboarding.sh
```

Add `IGNORE_TLOG=true` to the `01-commit-to-production.sh` line on an
air-gapped platform whose Chains uploads to no transparency log (the
assumption of the platform policy `require-signed-images`, which sets
`ignoreTlog: true`); otherwise the signature check `delivery-signature` fails looking up
the log entry. Only when the platform keeps signatures in a separate
repository (optional hardening, `sample-app/chains/README.md`), also add
`COSIGN_REPOSITORY=<signature repository>` to that line: without it the
signature check `delivery-signature` fails with "no signatures found".

The cross-project pull check in `02-platform-and-onboarding.sh` prints its
lines as `onboarding-cross-project-positive` and `onboarding-cross-project-negative`. The negative check runs
only after 6a passed: for a private Harbor project a missing image and a
refused pull give the same event text, so only the positive control proves
the image exists. Both probes set `imagePullPolicy: Always`: the positive
control has just put the image on the node, and with the default policy,
where the cluster's kubelet does not re-verify credentials of images already
on the node, the kubelet starts the other project's Pod from that copy without
asking for a
credential (`already present on machine`). So the
check proves that the registry refuses the other project. It does not prove
the same for a Pod that keeps the default pull policy: that needs a cluster
setting which re-checks pull credentials for images already on a node (the
`AlwaysPullImages` admission plugin, or a kubelet credential verification
policy other than `NeverVerify`; this sample does not cover either).

The delivery script first verifies the production signature and provenance
with cosign. `delivery-signed-image` then requires admission of that digest
and a matching `pass` report with `verified image signatures for <image>` or
`verified from cache`. Both forms must belong to the exact probe Pod UID and
policy; the live Pod must still contain exactly the independently verified image.
A generic initial pass is insufficient. If it fails, the unsigned check cannot pass.

The pull checks test one direction per invocation. Swap `PROJECT` and
`OTHER_PROJECT`, use an existing image from the other registry project as
`PROJECT_IMAGE`, and repeat with the corresponding validation and onboarding
run inputs to test the opposite direction. Both projects must be disposable.
Merge and synchronize the registration containing the dedicated
`<project>-self-healing-probe` RoleBinding before the self-healing check;
existing projects obtain it through a reviewed registration update.

In Audit mode check `delivery-unsigned-image` reads the PolicyReport whose `.scope.uid` is the
uid of its probe Pod (Kyverno 1.15 per-resource reports; their results carry
no `resources` list), so a report left by an earlier run cannot match. The
check waits up to `WAIT_SECONDS` (default 120) for a `fail` result: the
report of an unsigned image can say `pass` (`image verified`) first and turn
to `fail` (`no signatures found`) only later, about 40 s after the Pod is
created. The negative check requires a missing-signature message; a generic
policy failure or registry login failure does not count. When you read a
report by hand, wait a minute; a `pass` that follows a real verification
names the image (`verified image signatures for <image>`) or reports
`verified from cache` for that exact Pod UID and its checked image.

Needs `kubectl`; `skopeo` for the registry check and `cosign` for the
signature check of the delivery article. The Harbor projects are private and the
script passes no credential: log in first with a credential that can read
the release project (`skopeo login registry.example.com`, or point
`REGISTRY_AUTH_FILE` at an auth file; `cosign login registry.example.com`
for the signature check). This client login is separate from Kyverno's image
registry credential: configure Kyverno with pull access to the private release
projects and their signature artifacts before switching the policy to `Enforce`.

Inputs that earlier steps must produce first:

- `BUILD_DIGEST`: the `IMAGE_DIGEST` result of the `build-image` task of a CI
  run on `main` (merge-request runs push only to the scratch repository
  `shop/hello-mr`, which CD and promotion never read; see
  `sample-app/.tekton/ci-merge-request.yaml`). Deploying it to test is manual in this sample:
  start the CD Run Template `hello-cd-test` with it.
- `RELEASE_LABEL`: the release tag given to the promotion run, for example
  `release-001`. The prod check compares the Deployment image with the
  release repository at the digest this tag resolves to in the registry.
- `PROMOTION_RUN`: the name of the promotion PipelineRun (in the delivery
  namespace `shop-cd`) that created `RELEASE_LABEL`. The approval check reads
  only the ApprovalTask owned by this run, and fails when the variable is
  unset, the run does not exist, or it does not own exactly one ApprovalTask.
  Run the script while that run still exists: keep the promotion run and its
  ApprovalTask out of run cleanup until the acceptance is done.
- `UNSIGNED_IMAGE`: the delivery line as this sample runs it does not produce
  one: the promotion Run Template is the only path it uses to write the
  release project, and those runs are signed. The sample does not deploy
  rules 1–3 of the promotion guardrails, nor rule 4 (`sample-app/README.md`,
  "Operating notes and hardening", item "Promotion guardrails are not
  deployed"); the check does not use another write path either, it needs a
  known unsigned image. A platform administrator pushes a throw-away image
  into the release project with the admin Harbor credential (for example
  `skopeo copy docker://registry.example.com/base/<image>@sha256:<digest> docker://registry.example.com/"$PROJECT"-prod/acceptance-unsigned:once`),
  passes its digest reference here, and deletes the tag after the check.
- `PROJECT_IMAGE`: an image that CI already pushed to the `shop` Harbor
  project; onboarding pushes none, so run the first CI of the delivery article before
  `02-platform-and-onboarding.sh`.
- The tool image of `.tekton/validate.yaml` of the project GitOps
  repository: check `onboarding-validation` needs the run that `/test validate` starts to
  succeed, and the render task of the seeded file keeps the `<tag>`
  placeholder of the template until it is set. The status of that run shows
  on every merge request of that repository, the production ones included.
  Set the image in the template repository before onboarding, or by a merge
  request in a repository already seeded. Where the optional resolver
  constraint is in Enforce, the check also needs the published Pipeline
  (gitops-template README, "The merge request check uses Tasks from the
  platform catalog").

## What the scripts change

- Delivery probes with unique names beginning `acceptance-delivery-`,
  cleaned up on exit, plus unique `acceptance-onboarding-` pull probes in the
  project and other project's namespace, also cleaned up on exit. The probes satisfy the `restricted` Pod Security
  level; inspect other admission policies if they are refused.
- `onboarding-self-healing` deletes the subject-free RoleBinding
  `<project>-self-healing-probe`, rendered from
  `platform-repo/templates/rolebinding-self-healing-probe.yaml` and applied by
  the platform repository's `projects` Application, and waits for GitOps to
  re-create it. It saves the object and its UID first and passes only when a
  RoleBinding of that name with a different UID appears within
  `SYNC_WAIT_SECONDS` (default 600; allow for the automated sync interval of
  the `projects` Application, five minutes here; `onboarding/README.md`,
  assumption 10). A refused delete fails at once and changes nothing; when
  GitOps does not re-create it in time, the script re-creates it from the saved
  copy and the FAIL line says "restored by the script" (if that also fails, the
  FAIL line gives the path of the saved copy). It runs only with
  `ALLOW_MUTATING=true`; without it the check reports FAIL "skipped". The
  binding must carry `samples.example.com/acceptance-probe: self-healing` and
  have no subjects. A missing probe or an override naming an access grant
  fails before deletion; never use the owners' RoleBinding as the probe.
- Two steps stay manual: posting `/test validate branch:<source-branch>` on
  a merge request of the project GitOps repository (on a merge request PaC
  runs its source branch and does not use `branch:`; write the source branch
  there to keep the single command form), with `TEST_COMMENT_TIME` set to the
  time taken just before posting it (RFC 3339 UTC; a later time can miss the
  run the comment started), and
  starting the onboarding re-run (then set `ONBOARDING_RERUN`). The re-run
  check reads the run status and, per Harbor TaskRun (`harbor-tenant`,
  `harbor-staging-readonly`, `harbor-release`, selected by
  `tekton.dev/pipelineTask`), the `robot-token-rotated` result, expected `true`
  because the pipeline uses `robotTokenPolicy: refresh`; read the task logs to
  confirm that no new tool-side object was created, as the series describes.

This is sample material, not part of the product.
