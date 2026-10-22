# Alauda DevOps best-practice samples

中文入口：[README.zh-CN.md](README.zh-CN.md)。

The articles are under review in [Knowledge PR #859](https://github.com/alauda/knowledge/pull/859). The `main` links below are their publication targets and become available after that PR is merged.

Related knowledge articles: [Overview](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Alauda_DevOps_Best_Practices_Overview.md), [From Commit to Production](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/From_Commit_to_Production_on_ACP.md), and [Managing Platform Configuration and Onboarding Isolated Projects](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Managing_Platform_Configuration_and_Onboarding_Isolated_Projects_with_Argo_CD_and_Tekton_on_ACP.md).

Sample material accompanying the **Alauda DevOps best-practice series**. The
directories here turn the snippets of the series into files you can read,
render and adapt: a platform GitOps repository, a project GitOps repository
template, a project onboarding pipeline, a sample application with its delivery
line, and acceptance scripts.

> **Not part of the product.** This repository is sample material; it is not
> part of Alauda DevOps and is not covered by product support. It is not
> guaranteed to be compatible with any product version other than the ones
> listed under prerequisites. All names, domains and credentials are
> fictional placeholders.

## Prerequisites

| Component | Version |
|---|---|
| Alauda DevOps Pipelines (Tekton Operator, Pipelines-as-Code, Pruner, Results) | 4.15 |
| Catalog (Artifact Hub Shim) | 1.0 |
| Alauda DevOps Connectors | 1.14 |
| Alauda Container Platform GitOps (Argo CD) | 4.4 |

- The four tools the samples integrate with: **GitLab**, **Harbor**, **Nexus**
  and **SonarQube**, reachable from the cluster.
- The **built-in task catalog** installed and served through the hub resolver.
  The samples reference catalog resources with `resolver: hub`. One run-time
  download remains: the CI image scan needs the Trivy vulnerability DB, which
  `sample-app/.tekton/` points at an internal mirror (placeholder
  `registry.example.com/mirror/trivy-db:2`); with that mirror the samples
  work air-gapped. The pre-merge validation in the two `.tekton/validate.yaml`
  files is written inline with the catalog Tasks `git-clone` and
  `run-script`; set the tool image of its render task before the first merge
  request.
- Argo CD targets the cluster under the name Alauda GitOps registered for it
  (`<cluster-name>`, the ACP cluster name, `global` on the global cluster),
  not `in-cluster` (`platform-repo/README.md`, "Prerequisites").
- Kyverno and the sealed-secrets controller for the platform repository;
  Tekton Chains and the Manual Approval Gate for the delivery line.
- Manual prerequisites that no file here creates (details in
  `platform-repo/README.md`): namespace `platform-connectors`, the four
  Connectors automatic-creation Tasks installed in it, the Pipelines-as-Code
  webhook registration credentials, and an Argo CD repository credential for
  the project GitOps repositories.

## Layout and run order

To explore one part locally, start with the GitOps template or render a platform
layer. These commands need only Kustomize and do not contact a cluster:

```bash
kustomize build platform-repo/argocd/apps
kustomize build platform-repo/components
kustomize build platform-repo/policies
for d in gitops-template/envs/*/; do kustomize build "$d"; done
```

Rendering checks file composition, not CRD admission, credentials, or deployment
readiness. Onboarding, CI/CD, signing, webhooks, and acceptance need the target
cluster and external tools. Follow the run order below for the complete path.

| Order | Directory | Related article | Status | What it is |
|---|---|---|---|---|
| 1 | [`gitops-template/`](gitops-template/) | Managing Platform Configuration and Onboarding Isolated Projects | available | per-project GitOps repository template; pushed to its own repository before any onboarding, which seeds from it |
| 2 | [`platform-repo/`](platform-repo/) | Managing Platform Configuration and Onboarding Isolated Projects | available | platform GitOps repository (`argocd/apps`, `components`, `policies`, `credentials`, `projects`, `templates`): Argo CD app of apps, baseline policies, admin Connectors, project declarations and boundaries, Pruner / Results configuration, pre-merge validation; `onboarding/` is copied into it before the bootstrap |
| 3 | [`onboarding/`](onboarding/) | Managing Platform Configuration and Onboarding Isolated Projects | available | onboarding Pipeline, merge-triggered dispatcher Pipeline, run template, ScheduledTrigger for reconcile and rotation, ServiceAccount and RBAC; deployed by the platform repository, run once per project declaration |
| 4 | [`sample-app/`](sample-app/) | From Commit to Production on ACP | available | small application with CI, digest-based delivery and gated promotion |
| 5 | [`acceptance/`](acceptance/) | From Commit to Production / Managing Platform Configuration | available | acceptance checks as scripts printing `PASS` / `FAIL` per check |

Run order:

1. Push `gitops-template/` to its own repository
   (`https://git.example.com/platform/gitops-template.git`).
2. Prepare the manual prerequisites (namespace `platform-connectors`, the four
   Connectors automatic-creation Tasks in it, webhook registration, Argo CD
   repository credential), copy `onboarding/` into `platform-repo/`, seal the
   credentials, and bootstrap `platform-repo/` (its README).
3. Onboard each project: merging its declaration starts the onboarding
   pipeline, which creates the namespaces and tool tenants, seeds the
   project's GitOps repository from the template and opens a merge request
   against the platform repository that registers the project's Argo CD
   Applications and boundary; merge it. Declarations already in
   `platform-repo/projects/` at bootstrap (`shop`, `payments`) were pushed
   before the platform repository's PaC `Repository` existed, so no merge
   starts them: start the onboarding Run Template once for each (Bootstrap
   step 4 in `platform-repo/README.md`).
4. Push `sample-app/` as the application repository, apply its CD and
   promotion objects (its README says who applies what), and run CI, CD to
   test, promotion and CD to prod.
5. Run `acceptance/` after the step each script checks: the platform checks after
   onboarding and the first application build, and the delivery checks after the
   first promoted production deployment.

**Each top-level directory is self-contained.** It has its own README, its
manifests and scripts use only paths relative to itself, and it can be copied
to become the root of a separate repository (for example `platform-repo/`
becomes your platform configuration repository). READMEs and comments also
point to other directories of this sample set (for example
`sample-app/promotion/`); those references are to the full sample set and do not
travel with a copied directory.

## Replacement points

Every value below is a fictional placeholder. Replace it consistently in every
directory you use.

| Placeholder | Meaning | Used in |
|---|---|---|
| `git.example.com` | GitLab host; `https://git.example.com` is also `spec.git_provider.url` of every PaC `Repository` | `platform-repo/`, `onboarding/`, `sample-app/` |
| `https://git.example.com/platform/platform-config.git` | URL of your platform repository | `platform-repo/argocd/apps/`, `platform-repo/credentials/`, `onboarding/` |
| `https://git.example.com/platform/gitops-template.git` | repository holding the project GitOps template (`gitops-template/`) | `onboarding/` |
| `https://git.example.com/shop/gitops/config.git` | project GitOps repository that onboarding seeds (Argo CD URLs keep `.git`: GitLab redirects the URL without it, and Argo CD does not follow) | `sample-app/cd/`, `platform-repo/templates/` |
| `registry.example.com/mirror/trivy-db:2` | internal mirror of the Trivy vulnerability DB (`mirror.gcr.io/aquasec/trivy-db:2`) | `sample-app/.tekton/` |
| `https://git.example.com/shop/apps/hello` | application repository of `sample-app/` | `sample-app/` |
| `registry.example.com` | Harbor host (image registry; `shop/hello` staging, `shop/hello-mr` merge-request scratch, `shop-prod/hello` release) | `platform-repo/credentials/`, `platform-repo/policies/`, `gitops-template/`, `onboarding/`, `sample-app/`, `acceptance/` |
| `nexus.example.com` | Nexus host | `platform-repo/credentials/`, `onboarding/` |
| `sonar.example.com` | SonarQube host | `platform-repo/credentials/` |
| `platform-connectors` | the one management namespace: admin-level Connectors and their SealedSecrets, published project declarations, the platform repository's PaC Repository, the onboarding pipeline, release Connectors | `platform-repo/`, `onboarding/`, `sample-app/promotion/`, `acceptance/` |
| `argocd` | Argo CD namespace | `platform-repo/argocd/apps/`, `platform-repo/templates/`, `onboarding/`, `acceptance/` |
| `<cluster-name>` | Argo CD cluster name that Alauda GitOps registered for the target ACP cluster (the ACP cluster name, `global` on the global cluster; not `in-cluster`) | `platform-repo/argocd/apps/`, `platform-repo/credentials/`, `platform-repo/templates/`, `onboarding/` |
| `shop`, `payments` | project names (platform project, GitLab group, Harbor project, namespaces `shop`, `shop-test`, `shop-prod`, `shop-build`, `shop-cd`) | `platform-repo/projects/`, `gitops-template/`, `onboarding/`, `sample-app/`, `acceptance/` |
| `shop-platform-owners`, `payments-platform-owners` | owner groups of the projects | `platform-repo/projects/` |
| `shop-maven`, `shop-npm`, `payments-maven` | Nexus repositories of the projects | `platform-repo/projects/`, `onboarding/` |
| `group:release-managers` | approver group for promotion to production | `platform-repo/projects/`, `sample-app/promotion/` |
| `tekton-pipelines` | namespace of the Tekton controller | `platform-repo/policies/` |
| `catalog-pipelines`, `catalog` | hub resolver catalog names: `catalog-pipelines` for Pipelines, `catalog` for Tasks | `sample-app/`, `onboarding/`, `*/.tekton/validate.yaml` (Tasks only) |
| `<platform-project-kind>`, `<platform-project-group>`, `<platform-project-resource>` | kind, API group and resource name of the platform project | `platform-repo/argocd/apps/`, `platform-repo/projects/`, `onboarding/` |
| `<encrypted>` | kubeseal output for your cluster | `platform-repo/credentials/` |
| `<sealed-secrets-namespace>`, `<sealed-secrets-controller>`, `<kube-context>` | namespace and name of the sealed-secrets controller and the kubeconfig context for `kubeseal` | `platform-repo/credentials/SEALED-SECRETS.md` |
| `<cosign-public-key-pem>` | Chains public key (`cosign.pub`) | `platform-repo/policies/` |
| `<s3-secret-name>`, `<postgres-host>`, `<postgres-secret-name>` | Results storage and database (commented-out example values) | `platform-repo/components/` |
| `<digest>` | image digest | `gitops-template/`, `sample-app/`, `acceptance/` |
| `<tag>` | tag of a tool or base image in your registry (`registry.example.com/catalog/<tool>:<tag>`, `registry.example.com/base/<image>:<tag>`); pin by digest where you can | `onboarding/`, `sample-app/`, `*/.tekton/validate.yaml` |
| `samples.example.com` | domain of the sample label keys `samples.example.com/project` and `samples.example.com/project-declaration`; use your own | `platform-repo/projects/`, `onboarding/` |
| `project-onboarding@example.com` | commit author of the onboarding seed commit and merge request | `onboarding/` |

## Operating notes and hardening

Each directory's README has its own section with this title. Five points
apply to the whole sample set. The minimum supported Pipelines line is 4.15;
the other component versions in the prerequisite table are compatibility
inputs to verify in the target platform:

- **The project boundary is a Kyverno policy.** Alauda GitOps manages the
  AppProject of each platform project; the sample sets only `sourceRepos` and
  `destinations` on it, and the `projects` Application shows that AppProject
  as OutOfSync, which is expected. Put any further restriction into the
  Kyverno policy, not into that AppProject. The platform article's project boundary (no Role, RoleBinding, quota,
  LimitRange, NetworkPolicy, PolicyException or AccessPolicy from a project GitOps repository) is the Kyverno
  policy
  `platform-repo/policies/argocd-project-namespace-boundary.yaml`
  (`platform-repo/README.md`).
- **PaC without `git_provider.url` sends the token to gitlab.com.**
  Pipelines-as-Code v0.48.1 calls `https://gitlab.com` for status and
  comments, with the Repository's GitLab token, when a `Repository` of a
  self-hosted GitLab has no `spec.git_provider.url`. Every Repository here
  sets it; rotate any token that was sent.
- **The pre-merge check is defined inline.** Both `.tekton/validate.yaml`
  files compose the catalog Tasks `git-clone` and `run-script` in a
  `pipelineSpec`. The optional resolver constraint
  (`platform-repo/policies/pipelinerun-source-baseline.yaml`) does not accept
  an inline `pipelineSpec`: while that policy is in Audit, each validation
  run of a project GitOps repository is reported in the PolicyReport of the
  project namespace; in Enforce the run is not created. Where the constraint
  is on, publish the two tasks as a Pipeline in the catalog and use a hub
  `pipelineRef` (`gitops-template/README.md`).
- **The onboarding run holds CPU while it waits for its child run.** Step 7
  waits up to 20 minutes for the `gitops-repo-update` PipelineRun it starts;
  on a full cluster the child's Pods stay Pending behind the waiting Pod
  (`onboarding/README.md`).
- **Results watching is cluster-wide unless scoped.** Enabling the Results
  watcher can add `results.tekton.dev/*` finalizers to finished runs across
  watched namespaces. Disabling archive watching does not clear finalizers that
  are already present; follow the product recovery procedure before cleanup
  and use external Results storage as the audit source after pruning objects.

The Connectors approval feature is off by default and the samples work
without it. Before you turn it on, prepare a `connectors/proxy` grant (verb
`*`, through RBAC or an AccessPolicy) for every identity that mounts a
Connector not behind approval: with `enable-connectors-approval` on, the
CSI driver serves a Connector only to an identity that holds this grant.
The RBAC grants ship already (inert while the flag is off): the CI and CD
templates `platform-repo/templates/connector-mount-*.yaml` and
`sample-app/promotion/standing-access.yaml` (read-only Connector of the
release identity). Give no identity a direct `connectors/proxy` grant on
the approval-gated release Connector: its mount is authorized only through
the approval check of `sample-app/promotion/access-policy.yaml`, so apply
that file before the first promotion. Order: flag
`enable-connectors-approval`; immediately
`onboarding/optional/admin-connectors-access.yaml` and
`sample-app/promotion/access-policy.yaml`; then flag
`enable-connector-proxy-permissions`. Apply the two AccessPolicy files only
after the approval flag is on; AccessPolicies are accepted from then on.

## Conventions used in every file

- Each YAML file starts with a `# Series:` comment naming the related article
  and, where useful, its section, so you can find the text that explains it.
- Credentials appear only as `SealedSecret` examples with `<encrypted>` values;
  no plaintext `Secret` is ever committed.
- Deployment manifests and promotion sources reference application images by
  digest. Builds and promotion targets also write tags
  (`sample-app/.tekton/ci.yaml` pushes `:{{ revision }}`, the promotion run
  template copies to `:$(tt.params.release-label)`), and tool and base images
  use the `<tag>` placeholder above.
- Tasks are referenced, never inlined (no `taskSpec`). Pipelines are
  referenced too, with one exception: the two `.tekton/validate.yaml` files
  compose two catalog Tasks in a `pipelineSpec` ("Operating notes and
  hardening"). The forms of reference:
  catalog Tasks and Pipelines with `resolver: hub` and a pinned
  version; project-local Pipelines (onboarding, promotion) with
  `resolver: cluster`; the Tasks shipped with Alauda DevOps Connectors, which
  are installed in the namespace that runs them, with a plain `taskRef`
  (`kind: Task`, `name`).
- Re-run a PipelineRun from its merge request with
  `/test <pipelinerun-name> branch:<source-branch>`. To re-run a
  push-triggered PipelineRun, comment `/test <pipelinerun-name> branch:<branch>`
  on the latest commit of that branch. For complete trigger syntax, see the
  [Pipelines as Code product documentation](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html).
  The release-candidate `ci` definition is an exception: its pre-build guard
  rejects comment events; retry it with a new reviewed push to `main`.
- Connectors CSI mounts identify the Connector with the `connectors`
  attribute (`<namespace>/<name>`, always with the namespace), not with the
  deprecated `connector.name` / `connector.namespace` pair (Connectors
  documentation, *Connectors CSI Driver*). Both forms mount the same files
  for one Connector.
