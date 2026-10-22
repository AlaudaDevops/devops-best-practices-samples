# Sample application and its delivery line

中文版本：[README.zh-CN.md](README.zh-CN.md)。

A minimal Go HTTP service (`/` and `/healthz`) with the delivery line of the
Alauda DevOps best-practice series and the "From Commit to Production on ACP" article: CI from the
platform catalog, digest-based delivery through the project GitOps repository,
and gated promotion to the release registry. Every path below is relative to
this directory, so it can be copied to become the root of an application
repository; references to other directories of this sample set (`onboarding/`) point into the full sample set.

This is sample material, not part of the product and not covered by product
support. All names are fictional placeholders.

## Layout

```text
./
├── main.go, main_test.go, go.mod   # the service; no third-party modules
├── Containerfile                   # multi-stage build: test + static binary on a non-root base
├── .tekton/
│   ├── ci.yaml                     # PaC: push to main -> build, scan, push to shop/hello (the only input of CD and promotion)
│   └── ci-merge-request.yaml       # PaC: merge requests -> build, scan, push to the scratch repository shop/hello-mr
├── cd/
│   ├── run-template-test.yaml      # digest -> envs/test, committed directly (submitMode direct)
│   └── run-template-prod.yaml      # release digest -> envs/prod, via merge request (submitMode pr)
├── promotion/
│   ├── pipeline.yaml               # validate-digest -> wait-for-approval -> promote-image
│   ├── run-template.yaml           # fixed repositories, Connectors, identity, 25h timeouts
│   ├── access-policy.yaml          # optional: release Connector released only after approval (approval feature on)
│   ├── optional/console-approver.yaml # optional: ACP role for console approvers (read-only on runs, ApprovalTasks and the namespace in shop-cd, plus ACP projects, groups with member names and two console views platform-wide; creates nothing, reads no Secret)
│   └── standing-access.yaml        # `get` on both promotion Connectors + proxy on the staging one for the release identity (always)
└── chains/
    ├── verify.sh                   # cosign verify + verify-attestation by digest
    └── README.md
```

## Flow

```text
merge request
  -> .tekton/ci-merge-request.yaml  image registry.example.com/shop/hello-mr:<commit> (scratch; not used by the Run Templates)
push to main (merged)
  -> .tekton/ci.yaml            image registry.example.com/shop/hello:<commit>, digest D1
  -> cd/run-template-test.yaml  envs/test: shop/hello@D1 (direct commit) -> Argo CD -> shop-test
  -> promotion/run-template.yaml
       validate-digest -> wait-for-approval (group:release-managers) -> promote-image
                                  registry.example.com/shop-prod/hello:release-001, digest D2
  -> cd/run-template-prod.yaml  envs/prod: digest D2 only (newName shop-prod/hello set at seeding;
                                merge request) -> Argo CD -> shop-prod
```

The three Run Templates are started by hand in this sample, each with the
digest of the previous stage: D1 for `hello-cd-test` and `hello-promote-run`,
D2 for `hello-cd-prod`. The reference way is to render the template with the
digest and `kubectl create` the PipelineRun. When you start a Run Template
from the console, fill in the form fields listed at the top of each template
(for the two CD templates switch Integrations off; the promotion template
has no integration). Starting them from registry events is the reference
practice of the "From Commit to Production on ACP" article and is not implemented here. D2 should equal D1
(skopeo copies by digest without converting the manifest); when it differs,
investigate before deploying.

Merge-request runs (`.tekton/ci-merge-request.yaml`) do not push to
`shop/hello`: the catalog Pipeline scans the image it has pushed, so they push
to the scratch repository `shop/hello-mr`, which the sample's CD and promotion
Run Templates do not use (both fix the repository to `shop/hello`). The `ci.yaml` pre-build guard accepts only a `push` from `main` to `main`.
Named `/test ci` commands bypass PaC event annotations, so the runtime check
rejects those commands before build-image, including comments on `main`.
The guard reads PaC's actual event and branch annotations projected from the
Pod; it does not trust comment-overridable `{{ event_type }}` or branch inputs.
Use `ci-merge-request` for comment-triggered checks. The shared Harbor
credential can still write both repositories; stronger isolation requires
a separate scratch project and a credential unable to write `shop/hello`. A person types the digest into a Run Template, and
`cd/run-template-test.yaml` checks its
`repository@sha256:<64 hex>` form. Before starting a Run Template, check that the digest is the `IMAGE_DIGEST` of
a `.tekton/ci.yaml` run (table below) that ended `Succeeded`, was triggered by
a `push` event, and came from `main`. Before a promotion, check the same
source and verify the image scan result.
Give `hello-mr` a short tag retention in Harbor.

The digest is the only thing handed from one stage to the next; tags are for
people. Where to read it:

| Digest | Where |
|---|---|
| D1 (CI build) | result `IMAGE_DIGEST` of the `build-image` TaskRun of the CI PipelineRun |
| D2 (release) | result `promoted-digest` of the promotion PipelineRun |

```bash
# D1, from the CI PipelineRun <ci-run> in the build namespace
kubectl -n shop-build get taskrun \
  -l tekton.dev/pipelineRun=<ci-run>,tekton.dev/pipelineTask=build-image \
  -o jsonpath='{.items[0].status.results[?(@.name=="IMAGE_DIGEST")].value}'
# D2, from the promotion PipelineRun <promote-run>
kubectl -n shop-cd get pipelinerun <promote-run> \
  -o jsonpath='{.status.results[?(@.name=="promoted-digest")].value}'
```

## Catalog resources used

The catalog Pipelines and Tasks below use `resolver: hub` with an explicit
`version`. The project-local `hello-promote` Pipeline uses the cluster resolver;
its approval step references the installed `ApprovalTask` Custom Task by kind.
The CI scan needs one internal mirror: `trivy-scanner` downloads its
vulnerability DB at run time, from `mirror.gcr.io` unless `trivyExtraArgs`
names another repository, so both `.tekton/` files point it at
`registry.example.com/mirror/trivy-db:2` (replace with your mirror of
`mirror.gcr.io/aquasec/trivy-db:2`; without it an air-gapped run fails at the
scan). Whether the content published under a catalog version can still change
depends on how the catalog is maintained; confirm with the catalog
administrator before relying on it as a pin.

| Kind | Name | Version | Used in |
|---|---|---|---|
| Pipeline | `python-image-build-scan-deploy` | 0.3 | `.tekton/ci.yaml` runs the pre-build shell guard; `.tekton/ci-merge-request.yaml` skips pre-build. Both skip SonarQube and deployment by leaving those inputs empty. |
| Pipeline | `gitops-repo-update` | 0.1 | `cd/` |
| Task | `run-script` | 0.1 | `promotion/pipeline.yaml` (`validate-digest`) |
| Task | `skopeo-copy` | 0.1 | `promotion/pipeline.yaml` (`promote-image`, `imageMappings` form) |
| Custom task | `ApprovalTask` (Manual Approval Gate) | — | `promotion/pipeline.yaml` |

Deployment is GitOps only: the delivery tutorial's `workload-apply` deploy
step is intentionally not used.

### Why a Python Pipeline builds a Go image

The image-build Pipelines of the catalog are `python-image-build-scan-deploy`
and `java-image-build-scan-deploy`. This sample keeps the Go application and
**borrows the image-build part of `python-image-build-scan-deploy` 0.3**:
clone, `build-image` (buildah, from `Containerfile`) and the Trivy scan. Its
Pre-build checks the event and branch using a locally mirrored Python Task
image (only its shell is used; dependency installation is disabled). SonarQube
and deploy are skipped with `sonarURL` and `workloadName` empty; the Go compile and unit
tests run inside the multi-stage `Containerfile`. The CI digest D1 is the
`IMAGE_DIGEST` result of its **`build-image` TaskRun** (command in "Flow"
above). When your catalog has a Go Pipeline, switch both `.tekton/` files to
it and read the digest from its results.

### Using the SonarQube and Nexus Connectors of the project

Onboarding also writes the Connectors `shop-sonarqube` and `shop-nexus` into
namespace `shop`; this sample's CI uses neither (the Go build needs no Nexus
proxy here, and the SonarQube step is skipped). To turn on the SonarQube
scan, set `sonarURL` and `sonarProjectKey`, and mount the project
Connector on the `sonar-credentials` workspace, for example in
`.tekton/ci.yaml`:

```yaml
  params:
    - name: sonarURL
      value: https://sonar.example.com
    - name: sonarProjectKey
      value: shop:hello
  workspaces:
    - name: sonar-credentials
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: shop/shop-sonarqube
          configuration.names: sonar-scanner
```

The mount needs a grant for the identity the CI run uses (ServiceAccount
`default` of `shop-build`): `get` on `shop-sonarqube` and, once
`enable-connectors-approval` is on, `connectors/proxy` with verb `*`.
Onboarding step 7 renders both into Role `shop-ci-mount`
(`platform-repo/templates/connector-mount-ci.yaml`), next to the rules for
`shop-harbor`. When the scan step fails to authenticate, check this grant
first: the events of the Pod show whether the Connector was mounted.

The key must match the `projectPattern` that onboarding step 5 grants the
project (`^shop(:.*)?$`, `onboarding/pipeline/project-onboarding.yaml`);
the catalog Pipeline's default key is derived from the Git URL
(`{host}-{repoPath}-{repo}`) and does not match it. Set the key: the
project's permission template covers only keys that match the pattern. It is
fixed here while the pattern follows the project name:
when you rename the project or the application, change the key as well.

This step runs the code scan; a failed scan task fails the run. Read the
findings of the analysis in SonarQube. Before you use the result as a
quality gate, check in SonarQube that the gate of that analysis lists the
conditions you expect.

This sample does not cover: a change that breaks a gate
condition, and a Community Build without a branch plugin.

A Maven, npm or pip build mounts `shop-nexus` the same way, with the
configuration its Connector class documents for that build tool. Confirm the
configuration names against the Connectors documentation of your version
(the product documentation). It needs the same grant as the SonarQube mount, for
`shop-nexus`, which the template renders as well. Bind the same Connector to
the Task's `ca-bundle` workspace too: the configuration sends the build tool
through the Connectors proxy with certificate checking on, and the CA of the
proxy reaches the tool through that workspace (for npm: the workspaces
`npm-config` and `ca-bundle`, both from `shop/shop-nexus`). Add a command
that stops the build when the tool's configuration file is not in the
workspace (for npm: the `.npmrc`), because npm without a `.npmrc` uses its
public default registry. This sample has no build that mounts the Nexus
Connector.

## Application repository and its PaC Repository

Push this directory as the application repository `shop/apps/hello`
(`https://git.example.com/shop/apps/hello.git`), in the `apps` subgroup that
onboarding creates in GitLab group `shop`. Onboarding does not add anyone to
that GitLab group: a platform administrator first adds the developers (for
example the members of `shop-platform-owners`) to GitLab group `shop`, so that
they can create the repository. Pipelines-as-Code needs a `Repository` for it
before `.tekton/ci.yaml` runs; onboarding does **not** create one (it
registers only the project GitOps repository, `shop-gitops` in namespace
`shop`). Create it in the build namespace `shop-build`, where the CI
PipelineRun must run because buildah cannot run under `restricted`:

```yaml
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: hello
  namespace: shop-build
spec:
  url: https://git.example.com/shop/apps/hello
  git_provider:
    type: gitlab
    # API base URL of the self-hosted GitLab. Without it Pipelines-as-Code
    # v0.48.1 sends commit status and comments, with the token below, to
    # https://gitlab.com.
    url: https://git.example.com
    # Keys default to provider.token and webhook.secret.
    secret:
      name: hello-pac-auth
    webhook_secret:
      name: hello-pac-auth
  # Run .tekton/ as merged on main, not as proposed by a merge request
  # ([Advanced Repository Configuration](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/advanced_repository_config.html)).
  settings:
    pipelinerun_provenance: "default_branch"
```

Prerequisites:

- Namespace `shop-build` exists (onboarding step 1) and whoever applies the
  `Repository` and its Secret has write access there: onboarding binds the
  project owners only in namespace `shop`, so a platform administrator applies
  them or grants that access (see "Who applies what" below).
- Secret `hello-pac-auth` in `shop-build` with key `provider.token` (a GitLab
  token with `api` and `read_repository` scopes on `shop/apps/hello`, for
  example a group access token with Developer access) and key `webhook.secret` (a random string). Create it with `kubectl
  create secret generic`; never commit it. The role of the token matters as
  well as its scopes: Pipelines-as-Code reports the commit status with it,
  and on a protected branch GitLab takes a status only from a role that may
  push or merge there. With role Developer the status of the `ci` run on
  protected `main` is refused (`403 Forbidden`; event
  `FailedToSetCommitStatus` on the Repository, of type `Normal`) and the
  merge commit shows no status; with role Maintainer it is reported. On an
  unprotected branch Developer is enough (GitLab CE
  18.8, Pipelines-as-Code v0.48.1).
- The PaC webhook registration controller configured for `git.example.com`
  creates the webhook (the "Managing Platform Configuration and Onboarding Isolated Projects" article): with the controller's centralized webhook credential (the Developer-level repository token cannot manage webhooks) (platform repository README, "Prerequisites"); without
  the controller, add the webhook in GitLab by hand with the same secret
  (URL, secret token and events: same section).
- Connector `shop-harbor` in namespace `shop` (onboarding step 3), mounted by
  `.tekton/ci.yaml` to push the image.
- `get` on the Connectors that the runs mount. The `connectors-csi` driver
  publishes a Connector volume only if the Pod's ServiceAccount may `get` that
  Connector in the Connector's namespace (Catalog page *Promote Artifacts with
  Skopeo Copy*). Onboarding step 7 renders two such grants for every project
  into the platform repository, and the `projects` Application applies them
  once the registration merge request is merged: Role and RoleBinding
  `shop-ci-mount` in `shop` (`get` and `connectors/proxy` on `shop-harbor`,
  `shop-sonarqube` and `shop-nexus` for ServiceAccount `default` in
  `shop-build`, `platform-repo/templates/connector-mount-ci.yaml`)
  and `shop-delivery-mount` in `shop-cd` (`get` on `shop-gitops-writer` for
  `shop-delivery`, `platform-repo/templates/connector-mount-delivery.yaml`).
  `.tekton/ci.yaml` sets no ServiceAccount, so the CI PipelineRun runs as the
  TektonConfig `default-service-account`; on Alauda DevOps Pipelines 4.15 that
  is empty and the runs use `default`, the subject the
  template grants; if your platform sets a name, change the subject in the
  template. The grants for `shop-release` are in
  `promotion/standing-access.yaml`. These named grants document the workflow;
  ACP default project Connector reads can be broader. They do not remove
  inherited access. Use the proxy permission features for identity-specific
  restrictions, and verify effective access with the actual ServiceAccount.
- The Connectors proxy CA on every registry mount: `.tekton/` binds
  workspace `ca-bundle` and the promotion Run Template binds `src-ca-bundle`
  and `dst-ca-bundle`, because the proxy re-signs TLS.

## Who applies what

Application developers own the content of the CD and promotion objects (they
are part of this application's repository), but this sample grants the project
owners write access only in namespace `shop`. Applying the objects, starting
runs and approving need access that the sample leaves to the platform
administrator:

| Object or action | Namespace | Who does it in this sample | Access needed |
|---|---|---|---|
| PaC `Repository` `hello` and Secret `hello-pac-auth` | `shop-build` | platform administrator, or the owners after a grant | create/update `repositories.pipelinesascode.tekton.dev` and `secrets` in `shop-build` |
| Read the CI results (D1) | `shop-build` | platform administrator, or the owners after a grant | `view` in `shop-build` |
| `cd/run-template-*.yaml`, `promotion/pipeline.yaml`, `promotion/run-template.yaml` | `shop-cd` | platform administrator, or the owners after a grant | create/update `triggertemplates` and `pipelines` in `shop-cd` |
| Start a Run Template, read D2 | `shop-cd` | platform administrator, or the owners after a grant | create/get `pipelineruns` in `shop-cd` |
| Approve a promotion | `shop-cd` | members of `release-managers` | patch `approvaltasks.openshift-pipelines.org` in `shop-cd` (granted by the Manual Approval Gate installation; the sample assumes a user changes only their own approval input, which must be verified in the target version); a group member approves with one JSON patch that sets the group entry's `input` to `approve` and adds themself to its `users` (`replace` on `/spec/approvers/<i>/input` plus `add` on `/spec/approvers/<i>/users`); send both changes in the same patch. When the entry already lists another member (only with `numberOfApprovalsRequired` above 1), a later member appends with one `add` on `/spec/approvers/<i>/users/-` (a single object); each member of a group counts as one approval. The sample adds no binding for kubectl approvers; console approvers need an ACP role, see `promotion/optional/console-approver.yaml` |
| `promotion/standing-access.yaml` | `platform-connectors` | platform administrator only | — |
| `promotion/optional/console-approver.yaml` (optional) | cluster-scoped, binding in `shop-cd` | platform administrator only | — |
| `promotion/access-policy.yaml` (optional) | `platform-connectors` | platform administrator only, immediately after turning on `enable-connectors-approval` (mounts without a grant fail from then on) and before `enable-connector-proxy-permissions` | — |
| Chains registry credential (`platform-repo/components/chains-registry-credential.yaml` and Secret `chains-registry-credential`) | `tekton-pipelines` (Chains namespace) | platform administrator only (the Secret is created with kubectl, not committed); the project needs nothing for signing | — |

Do not grant the owners `edit` in `shop-cd`: `edit` includes creating Pods,
a Pod can mount any Secret of its own namespace (the Secret of
`shop-gitops-writer` is there), and Pod creation in `shop-cd` belongs to the
promotion guardrails (next section).

## Operating notes and hardening

What this sample leaves open, who can hit it, and the recommended hardening.

- **GitOps write credential next to the pipelines.** Connector
  `shop-gitops-writer` (a `maintainer` group token) and its Secret live in
  `shop-cd`, where CD and promotion run. Anyone who can create a Pod or a
  PipelineRun in `shop-cd` can mount the Secret directly, without the
  Connectors proxy or an approval, and push `envs/prod` to `main` unless
  `main` is protected (gitops-template README, "Who may change `main`").
  Hardening: keep the Connector and its Secret in a namespace where no
  pipeline runs and project members cannot create Pods (for example
  `platform-connectors`), mount it across namespaces (`connectors:
  <namespace>/<name>`, as every mount of this sample does), and give
  `shop-delivery` access through an
  AccessPolicy (Connectors documentation: *Connectors CSI Driver*,
  *AccessPolicy*). Moving the Secret does not make `edit` in `shop-cd` safe
  for the owners: `edit` still lets them create Pods there. Restrict Pod
  creation in `shop-cd` and enforce rules 2–3 of the promotion guardrails
  (item "Promotion guardrails are not deployed" below; Catalog page *Constrain
  Artifact Promotion with Kyverno*).
- **Approvers are written three times.** `approvers.prod` of the project
  declaration is a reviewed record; what takes effect is the ApprovalTask list
  in `promotion/pipeline.yaml` and `approvers` in
  `promotion/access-policy.yaml`. Nothing copies or compares them: keep the
  three identical. Hardening: an onboarding step that fails when the three
  differ, and rule 4 below.
- **Promotion guardrails are not deployed.** Approval protects the release
  Connector only after the administrator enables both Connector approval and
  proxy-permission checks and applies the matching production AccessPolicy
  (see `promotion/access-policy.yaml` for the required order). With those
  controls active, the policy releases it to the Pods of an approved promotion
  run. With the default disabled flags, a runtime ApprovalTask alone does not
  restrict the mount. The sample also does not restrict what else may run in
  `shop-cd`. Deploy rules 1–3 of the Catalog page *Constrain Artifact
  Promotion with Kyverno* (`promotion-runs-use-a-template`,
  `no-taskrun-outside-a-template`, `no-pod-outside-a-template`) as a platform
  baseline, plus rule 4 (`template-changes-by-maintainers-only`) because this
  sample's promotion Pipeline lives in the namespace. Alternatively, restrict
  Pod creation in `shop-cd` to the Tekton controller.
- **The release robot can read the staging project.** Onboarding gives the
  release robot of `shop-prod-registry` `pull` on `shop` as well as pull and
  push on `shop-prod`; the promotion copy needs all three. The robot cannot
  push to `shop`: promotion does not reuse the CI push credential.
- **Release labels must be unique.** The promotion Pipeline checks the label
  format but does not query Harbor for an existing tag. Use a fresh label for
  every run and enable tag immutability on the `<project>-prod` Harbor project;
  treat a duplicate-label failure as a failed promotion.
- **Production admits more than release images.** The platform policy
  `require-signed-images` selects Pods by image reference
  (`registry.example.com/shop-prod/*`), so a Pod in `shop-prod` running an
  image from any other repository is not evaluated; and a signature does not
  say which Pipeline produced the image. Hardening: a policy that admits only
  `registry.example.com/<project>-prod/*@sha256:*` in the `*-prod`
  namespaces. The optional provenance condition on the Pipeline name in
  `policies/require-signed-images.yaml` of the platform repository narrows
  mistakes; it does not prove which Pipeline produced the image, because any
  namespace can run a Pipeline of that name (`chains/README.md`).
- **Keep the approval record.** Who approved a release is recorded on the
  ApprovalTask (`status.approversResponse`). Tekton Results archives TaskRun,
  PipelineRun and log records (Pipelines documentation: *Understanding Tekton
  Results*): export the ApprovalTask
  (`kubectl -n shop-cd get approvaltask <name> -o yaml`) before the promotion
  run is pruned (the Pruner defaults in `components/pruner-defaults.yaml` of
  the platform repository keep the newest 200 finished runs per namespace and
  status), or keep the runs in `shop-cd` longer.
- **Scope Results before enabling archive watching.** The Results watcher can
  add `results.tekton.dev/*` finalizers to finished PipelineRun and TaskRun
  objects in every watched namespace. Turning it off does not remove existing
  finalizers, so deletion can stay blocked; follow the product procedure to
  re-enable the component before cleaning them up. Keep audit history in the
  external Results store after the Kubernetes objects are pruned.

## Trigger and re-run

```text
/test ci-merge-request branch:<source-branch>
```

Post this on the merge request. PaC uses its source branch; `branch:` records
that choice for the reader. Named `/test ci` commands intentionally fail the
release-candidate pre-build guard, even on `main`. Retry release-candidate CI
with a new reviewed push to `main`. See [Trigger PAC Pipelines](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html).

## Replacement points

| Placeholder | Where | Meaning |
|---|---|---|
| `registry.example.com/shop/hello` | `.tekton/ci.yaml`, `cd/`, `promotion/` | staging image repository (Harbor project `shop`) |
| `registry.example.com/shop/hello-mr` | `.tekton/ci-merge-request.yaml` | scratch repository for merge-request builds (Harbor project `shop`) |
| `registry.example.com/shop-prod/hello` | `cd/run-template-prod.yaml`, `promotion/` | release image repository (Harbor project `shop-prod`) |
| `registry.example.com/base/golang:<tag>`, `registry.example.com/base/static:<tag>` | `Containerfile` | build and runtime base images; pin by digest. The build pulls them through the project Harbor Connector: keep them in the project's own Harbor project, or in a shared project that the project robot can pull (check that pull first) |
| `registry.example.com/catalog/<tool>:<tag>` | `cd/`, `promotion/` | tool images for git, kustomize, glab, run-script, skopeo |
| `registry.example.com/mirror/trivy-db:2` | `.tekton/ci.yaml`, `.tekton/ci-merge-request.yaml` (`trivyExtraArgs`) | internal mirror of the Trivy vulnerability DB `mirror.gcr.io/aquasec/trivy-db:2`, needed air-gapped |
| `https://git.example.com` | this README (`spec.git_provider.url` of Repository `hello`) | GitLab API base URL for Pipelines-as-Code |
| `https://git.example.com/shop/gitops/config.git` | `cd/` | project GitOps repository seeded from the GitOps template |
| `https://git.example.com/shop/apps/hello`, `hello`, `hello-pac-auth` | this README | application repository, its PaC `Repository` in `shop-build` and that Repository's Secret |
| `shop-build`, `shop-cd` | all | build namespace (CI) and delivery namespace (CD, promotion); onboarding creates both from the declaration (`namespaces.build`, `namespaces.delivery`) |
| `shop-delivery`, `shop-release` | `cd/`, `promotion/` | ServiceAccounts of the delivery and release identities, created by onboarding step 1 in `shop-cd` |
| `shop-harbor` (namespace `shop`) | `.tekton/ci.yaml` | project Harbor Connector with push access to `shop`, written by onboarding step 3 (`harbor-tenant`) |
| `shop-gitops-writer` (namespace `shop-cd`) | `cd/` | GitLab Connector with push and merge request access to the GitOps repository, written by onboarding step 2 (`gitlab-gitops-writer`) |
| `shop-registry-readonly`, `shop-prod-registry` (namespace `platform-connectors`) | `promotion/` | read-only staging Connector and release Connector (push to `shop-prod`, and pull from `shop`, which the promotion copy needs), written by onboarding step 3 (`harbor-staging-readonly`, `harbor-release`); `shop-registry-readonly` also supplies the proxy CA for `src-ca-bundle` |
| `group:release-managers` | `promotion/pipeline.yaml`, `promotion/access-policy.yaml`, `promotion/optional/console-approver.yaml` (subject `release-managers`) | approver group, by its canonical identifier (the ACP group's resource name) |
| `<cluster-name>` | `promotion/optional/console-approver.yaml` | ACP cluster name (`global` on the global cluster) |
