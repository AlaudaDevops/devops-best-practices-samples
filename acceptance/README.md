# Acceptance scripts

The acceptance tables of the Alauda DevOps best-practice series written as
scripts: article 01 ("how do you know you are done", from commit to
production) and article 02 chapter 15 (project onboarding, plus the namespace
boundaries of chapter 13).

> **Treat a FAIL as "look here".** The scripts read a cluster with the real
> tools behind it (GitLab, Harbor, Kyverno); expect to adjust names to your
> environment first. Check `02§15-5` needs the tool image of the seeded
> `.tekton/validate.yaml` to be set (see the prerequisites below).

| Script | Checks |
|---|---|
| `01-commit-to-production.sh` | test runs the CI digest (CD Run Template started by hand in this sample) · release tag has the same digest · prod Application `Synced Healthy` · prod runs the release repository pinned to exactly the digest of the release tag; "runs" in both Deployment checks means the Pod template pins the digest and its rollout is complete (observed generation current, all replicas updated and available, no old replica left, waited up to `WAIT_SECONDS`), and a FAIL names the fields that do not hold · unsigned image refused (Enforce) or reported (Audit) by the platform policy `require-signed-images` (platform repository `policies/require-signed-images.yaml`) · the ApprovalTask owned by the promotion run `PROMOTION_RUN` (ApprovalTask → CustomRun → PipelineRun) approved with an approver · release image signature and provenance verify; for a group approval the approving members are printed too |
| `02-platform-and-onboarding.sh` | rows 2–8 of the 02 §15 table; row 1 (every onboarding run listed in the dispatcher's `onboarding-runs` result is `True`) is not scripted, check it by hand: workload namespaces `restricted`, build namespace `baseline` · four project Connectors ready · test Application `Synced` (`Healthy` only after the first CD run to test of article 01) · `/test validate` starts a run that succeeds (only runs labelled `pipelinesascode.tekton.dev/original-prname=validate` whose `pipelinesascode.tekton.dev/event-type` is `test-comment` count, or `pull_request`, the value that Pipelines-as-Code v0.48.1 announces for a later version; on GitLab the run that opening the merge request starts carries `Merge_Request` and cannot pass it) · cross-project pull refused for authorization, not for a missing image (with a positive control) · deleted RoleBinding re-created by GitOps with a new UID · onboarding re-run succeeds and rotates the Harbor robot tokens by design |

Every check prints exactly one line, `PASS <label>` or `FAIL <label>`, and
each script ends with `== result: X pass / Y fail ==` and exits non-zero when
anything failed. Labels start with the article and chapter of the table row
(for example `02§15-4`).

## Running

Every placeholder is an environment variable at the top of each script, with
the sample values (`shop`, `payments`, `registry.example.com`, ...) as defaults.

```bash
export KUBE_CONTEXT=<context>          # optional; default is the current context
BUILD_DIGEST=sha256:<digest> RELEASE_LABEL=release-001 PROMOTION_RUN=<pipelinerun> \
UNSIGNED_IMAGE=registry.example.com/shop-prod/hello@sha256:<digest> \
COSIGN_PUB=./cosign.pub ./01-commit-to-production.sh

# ALLOW_MUTATING=true lets check 02§15-7 delete the RoleBinding shop-owners
# (<project>-owners) and wait for GitOps to re-create it; without it that check
# reports FAIL "skipped" and the run cannot pass.
PROJECT_IMAGE=registry.example.com/shop/hello@sha256:<digest> \
TEST_COMMENT_TIME=<RFC 3339 UTC, just before commenting> \
ONBOARDING_RERUN=<pipelinerun> ALLOW_MUTATING=true ./02-platform-and-onboarding.sh
```

Add `IGNORE_TLOG=true` to the `01-commit-to-production.sh` line on an
air-gapped platform whose Chains uploads to no transparency log (the
assumption of the platform policy `require-signed-images`, which sets
`ignoreTlog: true`); otherwise the signature check `01§11-6` fails looking up
the log entry. Only when the platform keeps signatures in a separate
repository (optional hardening, `sample-app/chains/README.md`), also add
`COSIGN_REPOSITORY=<signature repository>` to that line: without it the
signature check `01§11-6` fails with "no signatures found".

Check 6 of `02-platform-and-onboarding.sh` (cross-project pull, row 6 of the
02 §15 table) prints its lines as `02§15-6a` and `02§15-6b`. 6b runs
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

In Audit mode check `01§11-4` reads the PolicyReport whose `.scope.uid` is the
uid of its probe Pod (Kyverno 1.15 per-resource reports; their results carry
no `resources` list), so a report left by an earlier run cannot match. The
check waits up to `WAIT_SECONDS` (default 120) for a `fail` result: the
report of an unsigned image can say `pass` (`image verified`) first and turn
to `fail` (`no signatures found`) only later, about 40 s after the Pod is
created (Kyverno 1.15.9). When you read a
report by hand, wait a minute; a `pass` that follows a real verification
names the image (`verified image signatures for <image>`).

Needs `kubectl`; `skopeo` for the registry check and `cosign` for the
signature check of article 01. The Harbor projects are private and the
script passes no credential: log in first with a credential that can read
the release project (`skopeo login registry.example.com`, or point
`REGISTRY_AUTH_FILE` at an auth file; `cosign login registry.example.com`
for the signature check).

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
  `skopeo copy docker://registry.example.com/base/<image>@sha256:<digest> docker://registry.example.com/shop-prod/acceptance-unsigned:once`),
  passes its digest reference here, and deletes the tag after the check.
- `PROJECT_IMAGE`: an image that CI already pushed to the `shop` Harbor
  project; onboarding pushes none, so run the first CI of article 01 before
  `02-platform-and-onboarding.sh`.
- The tool image of `.tekton/validate.yaml` of the project GitOps
  repository: check `02§15-5` needs the run that `/test validate` starts to
  succeed, and the render task of the seeded file keeps the `<tag>`
  placeholder of the template until it is set. The status of that run shows
  on every merge request of that repository, the production ones included.
  Set the image in the template repository before onboarding, or by a merge
  request in a repository already seeded. Where the optional resolver
  constraint is in Enforce, the check also needs the published Pipeline
  (gitops-template README, "The merge request check uses Tasks from the
  platform catalog").

## What the scripts change

- A probe Pod named `acceptance-probe` (unsigned-image check in the prod
  namespace; pull checks in the project and the other project's namespace),
  deleted after each check. The probe satisfies the `restricted` Pod Security
  level, so it is refused only for its image, never for its security context.
- `02§15-7` deletes the RoleBinding `shop-owners` (owners of the declaration,
  applied by the platform repository's `projects` Application) and waits for GitOps to
  re-create it. It saves the object and its UID first and passes only when a
  RoleBinding of that name with a different UID appears within
  `SYNC_WAIT_SECONDS` (default 600; allow for the automated sync interval of
  the `projects` Application, five minutes here; `onboarding/README.md`,
  assumption 10). A refused delete fails at once and changes nothing; when
  GitOps does not re-create it in time, the script re-creates it from the saved
  copy and the FAIL line says "restored by the script" (if that also fails, the
  FAIL line gives the path of the saved copy). It runs only with
  `ALLOW_MUTATING=true`; without it the check reports FAIL "skipped".
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
