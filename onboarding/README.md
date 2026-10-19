# Project onboarding pipeline

Sample onboarding pipeline for the Alauda DevOps best-practice series, article
02 ("Manage platform configuration with Argo CD and Tekton and onboard isolated
projects automatically"), chapters 8–12. One run turns a merged project
declaration into an isolated project: namespaces, one tenant in each of GitLab,
Harbor, Nexus and SonarQube, project-level Connectors, the identities and
Connectors of delivery and promotion, a seeded project GitOps repository, and a
merge request to the platform repository that registers the project's Argo CD
Applications and boundary. Copy this directory as is; every path below is
relative to this directory, except references to other directories of this
sample set (`sample-app/...`, `VERIFY-TODO.md`), which point into the full
sample set.

This is sample material, not part of the product and not covered by product
support. All names, domains and credentials are fictional placeholders.

## What the pipeline does

The platform project is created manually on the platform beforehand (series 02
§9); the pipeline starts from its declaration and exports the platform project's
manifest. Step numbers follow series 02 §9. Everything runs in the management
namespace `platform-connectors`, next to the admin-level Connectors it mounts.

| Step | PipelineTask | What it does | Uses |
|---|---|---|---|
| 1 | `validate-declaration` | reads ConfigMap `project-<project>` from `platform-connectors`, checks the fields and the naming convention of series 02 §16, derives the Nexus repository list and the environment list | catalog `kubectl` 0.1 |
| 1 | `export-platform-project` | `kubectl get <platform-project-kind> <platformProject> -o yaml` without `status`, server-set metadata and the Argo CD / GitOps plugin tracking markers, stored as ConfigMap `onboarding-<project>-register` for step 7 | catalog `kubectl` 0.1 |
| 1 | `create-namespaces` | creates `<project>`, `<project>-<env>` per environment, `<project>-cd` and `<project>-build` if absent; labels them `cpaas.io/project=<project>`, Pod Security `restricted` (workloads, delivery) or `baseline` (build); binds the onboarding ServiceAccount inside each; creates ServiceAccounts `<project>-delivery` and `<project>-release` in `<project>-cd` | catalog `kubectl` 0.1 |
| 2 | `gitlab-tenant` | GitLab group `<project>`, subgroups `apps` and `gitops`, group access token (`accessLevel: developer`, set explicitly), Connector `<project>/<project>-gitlab` | `gitlab-connector-automatic-creation` |
| 2 | `gitlab-gitops-writer` | second group access token (`accessLevel: maintainer`), Connector `<project>-cd/<project>-gitops-writer` for CD and promotion only | `gitlab-connector-automatic-creation` |
| 3 | `harbor-tenant` | Harbor projects `<project>` and `<project>-prod`; Connector `<project>/<project>-harbor`, which CI mounts to push images to `<project>`; image pull Secrets bound to `default` in the workload and build namespaces, with which those namespaces pull project images | `harbor-connector-automatic-creation` |
| 3 | `harbor-staging-readonly`, `harbor-release` | two more robot accounts: pull on `<project>` (read-only staging); pull and push on `<project>-prod` plus pull on `<project>` (release: the promotion copy needs this pull, `sample-app/README.md`, "Operating notes and hardening"), Connectors `platform-connectors/<project>-registry-readonly` and `platform-connectors/<project>-prod-registry` for promotion | `harbor-connector-automatic-creation` |
| 4 | `nexus-tenant` | the declared Nexus repositories, a user scoped to them, Connector `<project>/<project>-nexus` | `nexus-connector-automatic-creation` |
| 5 | `sonarqube-tenant` | SonarQube user, permission template scoped to `^<project>(:.*)?$`, token, Connector `<project>/<project>-sonarqube`; SonarQube projects are created by the first scan | `sonarqube-connector-automatic-creation` |
| 6 | `seed-gitops-repo`, `create-pac-repository` | creates `<project>/gitops/config` and seeds it once from the template (`envs/_<env>` or `envs/_env` becomes `envs/<env>`); creates the PaC `Repository` `<project>-gitops`, with the platform-injected values in `spec.params` (`registry`, the four Connector names), and its Secret `<project>-gitops-auth` | catalog `gitlab-cli` 0.1, catalog `kubectl` 0.1 |
| 7 | `register-project` | starts a PipelineRun `register-project-<project>-*` of the catalog Pipeline `gitops-repo-update` 0.1 in `submitMode: pr`: it clones the platform repository, runs its `templates/render.sh` and opens one merge request with `projects/<project>/` (Applications, AppProject patch, owners' RoleBinding, Connector-mount grants for CI and CD, exported platform project); waits for it | catalog `kubectl` 0.1, catalog Pipeline `gitops-repo-update` 0.1 |

Steps 2–5 run in parallel after the namespaces exist. Tool-side work belongs to
the product Tasks; ordering, declaration parsing, idempotency and registration
belong to the pipeline (series 02 §10).

**Why step 7 is a second PipelineRun.** A Pipeline cannot be a task of another
Pipeline, and re-implementing `gitops-repo-update` from its Tasks (`git-clone`,
`run-script`, `git-cli`, `gitlab-mr-create`) would copy its branch, change
detection and merge-request logic. So step 7 creates a PipelineRun of the
catalog Pipeline as it is and passes it two things: `updateArgs` (project,
GitOps repository URL, cluster, Argo CD namespace) and the `update-scripts`
workspace, bound to ConfigMap `onboarding-<project>-register` with the exported
platform project. The rendering itself runs inside the platform repository
clone, from its own `templates/`, so a template change is reviewed in the same
repository it affects. Onboarding applies nothing to Argo CD: the objects exist
once a platform administrator merges the request and the `projects` Application
syncs. A direct `kubectl apply` of the rendered directory is only mentioned as a
commented fallback in the Pipeline; this sample grants no RBAC for it.

## Layout

```text
./
├── pipeline/
│   ├── project-onboarding.yaml     # the Pipeline (steps 1–7)
│   └── onboard-changed-projects.yaml  # merge trigger: one project-onboarding run per changed declaration
├── run-template/
│   ├── triggertemplate.yaml        # Run Template: `project` is the only TriggerTemplate parameter; in the console run form fill in `project` only
│   └── triggerbinding.yaml         # maps an event body field `project` for an EventListener
├── triggers/
│   ├── shop.yaml                   # one ScheduledTrigger per project: reconcile and rotation every third day
│   └── payments.yaml
├── rbac/                           # ServiceAccount project-onboarding and its permissions
│   ├── release-connectors-shop.yaml   # one file per project: its promotion Connectors
│   └── release-connectors-payments.yaml
├── optional/
│   └── admin-connectors-access.yaml   # AccessPolicy for the admin Connectors; add it only once the approval feature is on
└── kustomization.yaml              # renders all of the above
```

## Prerequisites

- Alauda DevOps Pipelines 4.15 (with Tekton Triggers, the ScheduledTrigger
  controller and the cluster resolver), the built-in catalog served through the
  hub resolver (including the Pipeline `gitops-repo-update` 0.1), Alauda DevOps
  Connectors 1.14 with the GitLab, Harbor, Nexus and SonarQube Connector
  components and the Connectors CSI Driver, Argo CD in namespace `argocd`, and
  the Pipelines-as-Code webhook registration controller configured for
  `git.example.com` with its central webhook credential (series 02 §11). The
  developer token that onboarding writes into `<project>-gitops-auth` cannot
  manage webhooks, so the controller creates and removes the webhook of the
  project GitOps repository with the central credential. The controller also
  needs the Pipelines-as-Code controller URL of the platform; the central
  credential, that precondition, and the URL, secret token and events of a
  webhook added by hand, are in the platform repository README,
  "Prerequisites".
- The platform repository bootstrapped: namespace `platform-connectors` with the
  admin Connectors `gitlab-admin`, `harbor-admin`, `nexus-admin` and
  `sonarqube-admin`, the project declarations published as ConfigMaps
  `project-<name>`, and `templates/render.sh` on its `main` branch.
- The project GitOps template pushed to its own repository,
  `https://git.example.com/platform/gitops-template.git` by default.
- The platform project (for example `shop`) created on the platform. On ACP
  this also creates namespace `shop`, labelled only
  `cpaas.io/inner-namespace: shop`; `create-namespaces` adopts that one
  namespace (labels it `cpaas.io/project=shop`) instead of refusing it.
- Connector approval: as shipped, the pipeline relies on RBAC only
  (`rbac/admin-connectors.yaml`), which is enough while the cluster flags
  `enable-connectors-approval` and `enable-connector-proxy-permissions` are
  off (the default). Before a platform administrator turns them on, follow
  the order in `optional/admin-connectors-access.yaml`: approval flag, then
  that AccessPolicy, then the proxy-permissions flag. Create the AccessPolicy
  only after the approval flag is on; it is accepted from then on.

## Install the four Connectors automatic-creation Tasks

The four Tasks are shipped with Alauda DevOps Connectors 1.14; they are **not**
in the catalog. Install each one into `platform-connectors` (the namespace where
the pipeline runs) as described on its product page:

| Task | Product documentation |
|---|---|
| `gitlab-connector-automatic-creation` | https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-gitlab/how_to/using_gitlab_connector_automatic_creation_task.html |
| `harbor-connector-automatic-creation` | https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-harbor/how_to/using_harbor_connector_automatic_creation_task.html |
| `nexus-connector-automatic-creation` | https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.html |
| `sonarqube-connector-automatic-creation` | https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-sonarqube/how_to/using_sonarqube_connector_automatic_creation_task.html |

Check that they are present:

```bash
kubectl -n platform-connectors get tasks.tekton.dev \
  gitlab-connector-automatic-creation harbor-connector-automatic-creation \
  nexus-connector-automatic-creation sonarqube-connector-automatic-creation
```

## Install the pipeline

```bash
kustomize build . >/dev/null && echo "PASS render"
kubectl apply -k .
```

In a GitOps setup, add this directory as one more Application of the platform
repository instead of applying it by hand: copy it to `onboarding/` of the
platform repository, whose sample ships that fifth Application as
`argocd/apps/platform-onboarding.yaml` (path `onboarding`, destination
namespace `platform-connectors`).

## Input: the project declaration

The pipeline reads exactly one input, the declaration of the project named by
the `project` parameter, from key `<project>.yaml` of ConfigMap
`project-<project>` in `platform-connectors`. Step 1 rejects the run when:

- `name` differs from `project`, or `platformProject` or `environments` is empty;
- `owners` is empty or an entry is not a bare group name;
- `tools` is not exactly `gitlab`, `harbor`, `nexus`, `sonarqube` (this sample
  onboards all four);
- `namespaces.workloads` is not `<project>` followed by `<project>-<env>` for each
  environment, `namespaces.build` is not `<project>-build`, or
  `namespaces.delivery` is not `<project>-cd`;
- `gitlab.group` is not `<project>` or `gitlab.subgroups` is not `apps`, `gitops`;
- `harbor.projects` is not `<project>`, `<project>-prod`; `sonarqube.project` is
  not `<project>`; a Nexus repository name does not start with `<project>-` or
  lacks `format` / `type`;
- an approver is not a group (`group:<name>`);
- a derived namespace is on the reserved list (`default`, `kube`, `kube-*`,
  `argocd*`, `tekton-*`, `cpaas-*`, `*-system`, `platform`, `platform-*`,
  `kyverno*`, `sealed-secrets*`; extend it for your platform).

Step 1 does not check the length of the derived names. `<project>` is limited
to 32 characters, an environment name is not limited, and a namespace name is a
DNS label of at most 63 characters: keep `<project>-<env>` within 63
characters, or the API server refuses the namespace later, in
`create-namespaces`.

`create-namespaces` also fails when a namespace it would use already exists
without the label `cpaas.io/project=<project>`, instead of taking it over. The
one exception is namespace `<project>` itself when the platform created it
with the platform project (label `cpaas.io/inner-namespace=<project>` and no
`cpaas.io/project`): that namespace is adopted.

`approvers` is a reviewed record: the Pipeline checks its form only and
injects it nowhere. The approvers that take effect are written in the
project's promotion Pipeline and AccessPolicy (`sample-app/promotion/`) and
must be kept identical by hand; see "Operating notes and hardening".

`imagePullFrom` (cross-project pulls, series 02 §13) is reported as a warning:
this sample does not implement it.

## Outputs

| Where | What |
|---|---|
| cluster | namespaces `shop`, `shop-test`, `shop-prod`, `shop-cd` (`restricted`), `shop-build` (`baseline`), all labelled `cpaas.io/project=shop` |
| GitLab | group `shop` with subgroups `apps` and `gitops`, two group access tokens (developer with `api` + `read_repository` for the project Connector and PaC, maintainer with `api` + `read_repository` + `write_repository` for the GitOps writer; a group token covers every subgroup and repository of the group), repository `shop/gitops/config` |
| Harbor | projects `shop` and `shop-prod`, three robot accounts (project, read-only staging, release: push to `shop-prod` and pull from `shop`) |
| Nexus | repositories `shop-maven`, `shop-npm`, one user scoped to them |
| SonarQube | one user and a permission template for project keys `^shop(:.*)?$` |
| namespace `shop` | Connectors `shop-gitlab`, `shop-harbor`, `shop-nexus`, `shop-sonarqube` and their Secrets; PaC `Repository` `shop-gitops` (`spec.git_provider.url` = the `gitlab-url` param; `spec.settings.pipelinerun_provenance: default_branch`; `spec.params`: `registry` = `registry.example.com/shop`, `gitlab-connector`, `harbor-connector`, `nexus-connector`, `sonarqube-connector`) and Secret `shop-gitops-auth` |
| namespace `shop-cd` | ServiceAccounts `shop-delivery` and `shop-release`; Connector `shop-gitops-writer` and its Secret |
| `shop`, `shop-test`, `shop-prod`, `shop-build` | image pull Secret `shop-harbor-pull`, added to ServiceAccount `default` (for `shop-build` see also `sample-app/chains/README.md`, "Where signatures are stored") |
| `platform-connectors` | Connectors `shop-registry-readonly` and `shop-prod-registry` and their Secrets; ConfigMap `onboarding-shop-register`; PipelineRun `register-project-shop-*` |
| platform repository | one merge request adding `projects/shop/`; after its merge the `projects` Application creates `Application`s `shop-test` and `shop-prod`, patches `AppProject` `shop`, creates RoleBinding `shop-owners` in `shop` for group `shop-platform-owners`, grants `get` and `connectors/proxy` on `shop-harbor`, `shop-sonarqube` and `shop-nexus` to ServiceAccount `default` of `shop-build` (Role `shop-ci-mount` in `shop`) and on `shop-gitops-writer` to `shop-delivery` (Role `shop-delivery-mount` in `shop-cd`), and applies the platform project |
| PipelineRun results | the seven `connector-ref` values, `harbor-robot-token-rotated` and `register-run` |

No credential and no tool-side object ID is written back to git.

## Run it

**From the console (Run Template).** `run-template/triggertemplate.yaml` is a
Run Template for the Pipeline `project-onboarding`; start a run from it,
enter the project name in the Pipeline field `project` and leave the other
fields at their defaults. The reference way is the **Manually** PipelineRun
below; this sample does not cover the console form path.
`platform-connectors` belongs to no ACP project: open it by URL
(`.../console-acp/workspace/<project>~<cluster>~platform-connectors/...`) or
give it a project.

**On merge (Pipelines-as-Code).** The platform repository sample ships
`.tekton/onboard-changed-projects.yaml`, one PipelineRun for all projects that
Pipelines-as-Code starts on a push to `main` changing `projects/*.yaml` (a
merged declaration). It runs `pipeline/onboard-changed-projects.yaml`, which
diffs the pushed commit against its first parent, reads `name` from each
changed declaration, waits until Argo CD has published that revision as
ConfigMap `project-<name>` and creates the same PipelineRun as below
(`onboard-<name>-*`, labelled `samples.example.com/dispatched-by`) for each
project. A new project needs no new file here or in the platform repository's
`.tekton/`. Re-run it with a comment on the merge commit
`/test onboard-changed-projects branch:main`, for example when its run failed
because Argo CD had not published the declaration within `sync-timeout`. The
comment works only while the merge commit is still the HEAD of `main`;
otherwise start the Run Template above for the project.

**Manually.** Create a PipelineRun equivalent to the Run Template:

```bash
kubectl create -f - <<'YAML'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: project-onboarding-shop-
  namespace: platform-connectors
spec:
  pipelineRef:
    resolver: cluster
    params:
      - name: kind
        value: pipeline
      - name: name
        value: project-onboarding
      - name: namespace
        value: platform-connectors
  params:
    - name: project
      value: shop
  taskRunTemplate:
    serviceAccountName: project-onboarding
  workspaces:
    - name: gitlab-admin
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: platform-connectors/gitlab-admin
          configuration.names: gitlabconfig,gitconfig
          token.expiration: 45m
    - name: harbor-admin
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: platform-connectors/harbor-admin
          configuration.names: harbor-cli-config
          token.expiration: 45m
    - name: nexus-admin
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: platform-connectors/nexus-admin
          token.expiration: 45m
    - name: sonarqube-admin
      csi:
        driver: connectors-csi
        readOnly: true
        volumeAttributes:
          connectors: platform-connectors/sonarqube-admin
          configuration.names: sonar-scanner
          token.expiration: 45m
YAML
```

`token.expiration: 45m` keeps the proxy token of each mount valid for longer
than the 30m timeout of each onboarding Task; without it the token lasts the
CSI default of 30m (Connectors documentation: *Connectors CSI Driver*). The
Run Template and the merge-triggered dispatcher set the same value.

**On a schedule (ScheduledTrigger).** Each onboarded project gets one file in
`triggers/` (copy `triggers/shop.yaml`, change the name and the `project`
value), one file in `rbac/` (copy `rbac/release-connectors-shop.yaml`, change
the names) and one line each in `kustomization.yaml`. The trigger renders the
Run Template every third day (`0 2 */3 * *`), which re-runs the whole pipeline:

- the Connectors Tasks rotate the long-lived tool credentials and write them
  back to the Connector Secrets (the Harbor Task reports `robot-token-rotated`);
  `create-pac-repository` copies the rotated group token into
  `shop-gitops-auth`;
- namespaces, labels, ServiceAccounts, RoleBindings and the PaC Repository are
  reconciled; an already seeded GitOps repository is not touched; step 7
  renders the same files, and its push step opens a merge request only when
  they differ from `main`. Merge or close the merge request of the first run
  before the schedule starts. To see whether a run changed anything, look for a
  merge request, not at the `changed` result of the child run.

Keep the schedule shorter than the validity of the GitLab and SonarQube
tokens. `token-duration` (30 days) is the validity of the GitLab group tokens
that the first run creates; a group token rotated by a re-run is valid for 7
days. Keep the interval so far below 7 days that one missed run does no harm
(the sample runs every third day), and alert on a failed run. The two group
tokens, and the PaC `provider.token` copied from the developer token, end a
week after each re-run. The pipeline sets no validity for the Harbor and
Nexus credentials, so rotate those as your security policy requires.
Place the schedule in the project's idle hours. Re-run a run that started
before a rotation and fails to authenticate: the new run reads the rotated
Secret (series 02 §12; Connectors documentation: *Rotation-during-use race*
on the GitLab automatic-creation page).

Check a trigger with:

```bash
kubectl -n platform-connectors get scheduledtrigger project-onboarding-shop
```

## Verify an onboarded project

Selected checks from series 02 §15 (after the merge request of step 7 is
merged):

```bash
kubectl get ns shop -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'   # restricted
kubectl get ns shop-build -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'   # baseline
kubectl -n shop get connectors                                                               # four Connectors
kubectl -n shop-cd get sa shop-delivery shop-release                                         # two identities
kubectl -n argocd get application shop-test -o jsonpath='{.status.sync.status} {.status.health.status}'   # Synced (Healthy after the first CD run to test)
```

Re-running the pipeline for the same project must report existing objects and
make no change, except the rotated credentials.

## Operating notes and hardening

What this sample leaves open, who can hit it, and the recommended hardening.

- **The GitOps writer Secret sits where CD runs.** Connector
  `<project>-gitops-writer` and its Secret are written into `<project>-cd`, the
  namespace of the CD and promotion runs. Anyone who can create a Pod there
  can mount it without the Connectors proxy or an approval. Hardening: write
  it into a namespace where no pipeline runs (for example
  `platform-connectors`, as for the promotion Connectors; that needs its
  names in `rbac/release-connectors-<project>.yaml`) and let CD mount it
  across namespaces through a Role granting `get` on the Connector (plus
  `connectors/proxy` with verb `*` for when the approval flag is on; see
  `sample-app/promotion/standing-access.yaml`) (Connectors documentation:
  *Connectors CSI Driver*, *AccessPolicy*).
- **The onboarding ServiceAccount can use the admin Secrets.** Its RBAC holds
  no Secret API access in `platform-connectors`, but it creates PipelineRuns
  there, and a Pod can mount any Secret of its own namespace. Treat it, and
  anyone able to create Pods or PipelineRuns in `platform-connectors`, as
  holding the admin credentials. Optional hardening (not enabled): a Kyverno
  rule that lets this ServiceAccount create only PipelineRuns of
  `project-onboarding` and `gitops-repo-update`, without inline specs or
  `secret` workspaces.
- **Approvers are not synchronized.** See the note under "Input"; an
  onboarding step that compares the declaration with the promotion Pipeline
  and AccessPolicy of the project and fails on a difference is the
  hardening.
- **The GitOps repository is not protected.** Onboarding creates
  `<project>/gitops/config` but configures no branch protection or code
  owners, so a holder of the maintainer token can change `envs/prod` on
  `main` without review. Hardening: protect `main` and require code owner
  approval for `envs/prod/` (gitops-template README, "Who may change
  `main`").
- **GitLab group members.** Onboarding creates the group and its tokens; a
  platform administrator adds the developers to GitLab group `<project>`, and
  gives the identity of the central webhook credential the Maintainer role on
  the group unless its token already covers the group (platform repository
  README, "Prerequisites").
- **Step 7 holds CPU while it waits.** `register-project` creates the
  `register-project-<project>-*` PipelineRun and polls it for up to 20
  minutes; its own Pod keeps its CPU request the whole time. On a cluster
  without spare CPU the child's Pods stay Pending behind the parent (for
  example on a single node). The child has no
  ownerReference, so cancelling the parent leaves it running. Hardening: keep
  spare CPU for two onboarding Pods, or lower the step's request with
  `taskRunSpecs`; a fire-and-forget step 7 that reports the
  child's name without waiting would also need another way to surface its
  result.
- **The project boundary is a Kyverno policy.** The AppProject patch of step 7
  sets `sourceRepos` and `destinations`; the kinds a project may not deploy are
  refused by the platform policy `argocd-project-namespace-boundary` (platform
  repository README, "Operating notes and hardening").

## Assumptions to verify

These points could not be confirmed from the product documentation or the
catalog sources used for this sample. Check them in your environment before
relying on the pipeline.

1. **Cross-namespace Connector mounting.** Onboarding needs none: the
   pipeline runs in `platform-connectors` and mounts the admin Connectors of
   its own namespace. Promotion and CI do mount across namespaces (promotion in
   `shop-cd` mounts `shop-registry-readonly` / `shop-prod-registry` from
   `platform-connectors`; CI in `shop-build` mounts `shop/shop-harbor`). The CI
   mount is verification item P3-4 of `VERIFY-TODO.md` in this sample set;
   there is no dedicated check yet for the promotion mounts (P3-13 only checks
   that the two Connectors exist). Open question for onboarding: whether mounting from another
   namespace could instead be granted through an AccessPolicy, which would
   allow a separate onboarding namespace.
2. **Project-level Connectors of the project.** Step 1 labels namespace
   `<project>` with `cpaas.io/inner-namespace: <project>` so that the Connectors
   written there can be mounted from `<project>-<env>` and `<project>-build`.
   The platform itself creates namespace `<project>`
   with the platform project and sets that same label, so step 1 adopts it.
   Check whether the platform treats its inner namespace differently
   once step 1 adds `cpaas.io/project=<project>` to it.
3. **Permissions of the Connectors proxy.** `rbac/admin-connectors.yaml` grants
   `get` on the four admin Connectors and on `connectors/proxy`. Once a
   platform administrator turns on `enable-connectors-approval`, every identity
   that mounts a Connector needs `connectors/proxy` with verb `*` (RBAC) or an
   AccessPolicy grant, as well as `get` on the Connector: the CSI driver and
   the proxy review the verb `*`. `enable-connector-proxy-permissions` adds the
   same check in the proxy. In this sample set: `project-onboarding` on the
   four admin Connectors (`optional/admin-connectors-access.yaml`, needed from
   the moment the approval flag is on); ServiceAccount `default` of
   `<project>-build` on `<project>/<project>-harbor`, and on
   `<project>-sonarqube` and `<project>-nexus` when CI mounts them, and
   `<project>-delivery` on `<project>-cd/<project>-gitops-writer` (second rule
   of the platform repository templates `connector-mount-ci.yaml` and
   `connector-mount-delivery.yaml`); `<project>-release` on
   `platform-connectors/<project>-registry-readonly` (second rule of
   `sample-app/promotion/standing-access.yaml`) and on
   `<project>-prod-registry` (only after approval, through
   `sample-app/promotion/access-policy.yaml`).
4. **Permissions of the Connectors Tasks.** The documentation says the Tasks
   create and update Secrets, Connectors and image pull Secrets in the target
   namespaces; `rbac/project-namespace-clusterrole.yaml` grants
   get/create/update/patch (plus list on Connectors), and
   `rbac/release-connectors-shop.yaml` grants the same in `platform-connectors`
   limited to the two Connectors and their Secrets `<connector>-secret` (the
   default the Tasks' `secret` parameter documents). Confirm the exact verbs
   each Task calls on your version.
5. **Array results.** Step 1 passes arrays to later steps through the
   `array-result` of the catalog `kubectl` Task; this needs array results enabled
   in Tekton (beta API fields).
6. **Result paths in a Pipeline-level script.** The `kubectl` scripts write
   `$(results.string-result.path)` / `$(results.array-result.path)`; the catalog
   tests use this in TaskRuns, not in Pipelines.
7. **Tools in the catalog images.** Step 1 uses `jq` and the version-suffixed
   `yq-<version>` binary of the catalog `kubectl` image; step 6 uses `glab`,
   `git` and `jq` of the `gitlab-cli` image; step 7 runs `templates/render.sh`
   (`sh`, yq v4) in the `kubectl` image.
8. **Git access in step 6.** `seed-gitops-repo` relies on the `gitlab-cli` Task
   turning the admin Connector's `gitconfig` configuration into working
   `glab api` and `git clone` / `git push` access to `https://git.example.com`.
   The same CSI volume also carries `gitlabconfig` for the GitLab Task.
9. **Token for the PaC Repository.** `create-pac-repository` copies key `token`
   of Secret `<project>-gitlab-secret` (the default name the GitLab Task uses)
   into key `provider.token` of `<project>-gitops-auth`; confirm the source key
   name in your Connectors version.
10. **AppProject ownership.** Alauda GitOps manages one AppProject per platform
    project; the `projects` layer sets `sourceRepos` and `destinations` on it
    as a server-side-apply patch (they are merged with the platform's own) and
    no other field. The `projects` Application shows that AppProject as
    OutOfSync, which is expected, and Argo CD attempts the automated sync of
    `projects` once every five minutes: allow that long for a self-heal of
    anything under `projects/`. The kinds a project may not deploy are refused
    by the platform policy `argocd-project-namespace-boundary`. See "Operating
    notes and hardening".
11. **Argo CD repository access.** Argo CD needs read access to
    `https://git.example.com/<project>/gitops/config` (for example a repository
    credential template for `https://git.example.com`); onboarding does not
    create it.
12. **Run Template form.** In the console run form `project` is the one field
    to fill in; the other Pipeline parameters carry their defaults. This
    sample does not cover submitting the form.
13. **Cluster resolver and ScheduledTrigger controller.** The cluster resolver
    must be allowed to resolve Pipelines from `platform-connectors`, and the
    ScheduledTrigger controller must be allowed to render the TriggerTemplate
    in that namespace.
14. **Template literals.** Seeding renames the image paths `/shop/hello` and
    `/shop-prod/hello` and the `app.kubernetes.io/part-of: shop` label of the
    template to the project; a template with other project-specific literals
    needs more substitutions. For a project not named `shop`, comments and
    the README of the seeded repository still say `shop`. Seeding also
    replaces the template's registry host with `registry-host`, in the image
    references and in the README of the seeded repository.
15. **Platform project API.** `<platform-project-kind>` (Pipeline param
    `platform-project-resource`, `rbac/cluster-scope.yaml`, the platform
    AppProject whitelist) is a placeholder: confirm the kind and group of the
    platform project on your platform, and that a manifest exported without
    `status` and server-set metadata can be applied by Argo CD to initialize a
    new environment.
16. **Three runs of the Harbor Task.** `harbor-tenant`, `harbor-staging-readonly`
    and `harbor-release` are expected to create three separate robot accounts
    (one per Connector) and not to reduce the permissions another run granted
    on the same Harbor project.
17. **Two runs of the GitLab Task.** `gitlab-gitops-writer` is expected to mint
    a second group token for its own Connector instead of rotating the token of
    `<project>-gitlab`, and maintainer access is expected to allow the direct
    commit to `main` of `<project>/gitops/config` that CD to test performs.
18. **Step 7 PipelineRun.** `gitops-repo-update` 0.1 in `pr` mode is expected to
    work against the platform repository with the admin GitLab Connector
    (`gitconfig,gitlabconfig`), to run the update script at the root of the
    clone, and to expose the ConfigMap workspace as
    `$GITOPS_UPDATE_SCRIPTS_DIR`. Read the outcome of a run from its push and
    merge-request steps, not from `changed`.
19. **Where the onboarding ServiceAccount may bind roles (residual risk).**
    `rbac/cluster-scope.yaml` lets `project-onboarding` create and patch
    RoleBindings in any namespace, because the project namespaces do not exist
    before step 1 creates them. The platform policy
    `onboarding-rolebinding-scope` (platform repository,
    `policies/onboarding-rolebinding-scope.yaml`) limits this to namespaces
    labelled `cpaas.io/project` and never `platform-connectors`. What remains:
    the policy starts in Audit, so it only reports until you switch it to
    Enforce; the same ServiceAccount may `patch` namespaces, so it could label
    another namespace `cpaas.io/project` and then bind itself there (keep its
    RBAC and the PolicyReports under review, or restrict namespace patches to
    project namespaces as well); a RoleBinding written by any other identity is
    not covered. A declaration that names an existing or platform namespace is
    refused by step 1 (reserved list) and by `create-namespaces` (existing
    namespace without `cpaas.io/project=<project>`); a reviewed declaration
    remains the main control, and the reserved list must be extended with the
    namespaces of your platform.

## Replacement points

| Placeholder | Where | Meaning |
|---|---|---|
| `platform-connectors` | all files | management namespace: onboarding, declarations, admin Connectors |
| `gitlab-admin`, `harbor-admin`, `nexus-admin`, `sonarqube-admin` | `rbac/admin-connectors.yaml`, `run-template/triggertemplate.yaml`, step 7 | names of the admin Connectors |
| `argocd` | Pipeline param `argocd-namespace` | Argo CD namespace |
| `<cluster-name>` | Pipeline param `argocd-cluster` | Argo CD cluster name that Alauda GitOps registered for the target ACP cluster (`global` on the global cluster; not `in-cluster`) |
| `<platform-project-kind>`, `<platform-project-group>`, `<platform-project-resource>` | Pipeline param `platform-project-resource`, `rbac/cluster-scope.yaml` | platform project API |
| `https://git.example.com` | Pipeline param `gitlab-url` | GitLab address; also `spec.git_provider.url` of the PaC Repository and the base of `projectPath` in step 6 |
| `https://nexus.example.com` | Pipeline param `nexus-url` | Nexus address |
| `registry.example.com` | Pipeline param `registry-host` | Harbor host injected into the PaC Repository params |
| `https://git.example.com/platform/gitops-template.git` | Pipeline param `gitops-template-url` | repository holding the project GitOps template |
| `https://git.example.com/platform/platform-config.git` | Pipeline param `platform-repo-url` | platform repository (target of the step 7 merge request) |
| `registry.example.com/catalog/<tool>:<tag>` | Pipeline params `git-cli-image`, `kubectl-image`, `glab-image` | tool images of `gitops-repo-update` |
| `config` | Pipeline param `gitops-repo-name` | name of the project GitOps repository in subgroup `<project>/gitops`; not `<project>/gitops` itself, which is the subgroup |
| `"30"` | Pipeline param `token-duration` | token validity in days |
| `apps`, `gitops`; `<project>`, `<project>-prod`; `^<project>(:.*)?$` | `pipeline/project-onboarding.yaml` | naming convention of GitLab subgroups, Harbor projects and SonarQube keys |
| `repository:pull,push`, `repository:pull` | `pipeline/project-onboarding.yaml` | Harbor robot permissions per project |
| `developer`, `maintainer`; `api`, `read_repository`, `write_repository` | `pipeline/project-onboarding.yaml` | GitLab token access levels and scopes: the project token (`developer`) gets `api` + `read_repository`, the GitOps writer (`maintainer`) also `write_repository` |
| `0 2 */3 * *`, `Etc/UTC` | `triggers/shop.yaml` | rotation schedule: every third day at 02:00 UTC; the gap is one to three days, because `*/3` restarts on the first of each month |
| `shop` | `triggers/shop.yaml`, `rbac/release-connectors-shop.yaml` | project name, one file each per project |
| `samples.example.com/project` | `run-template/`, `triggers/`, `rbac/`, Pipeline | label key for your own domain |
| `project-onboarding@example.com` | `pipeline/project-onboarding.yaml` | commit author of the seed commit and of the step 7 merge request |
