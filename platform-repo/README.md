# Platform repository skeleton

Sample platform GitOps repository for the Alauda DevOps best-practice series,
article 02 ("Manage platform configuration with Argo CD and Tekton and onboard
isolated projects automatically"), chapters 5–7. Copy this directory as the root
of your own platform repository; every path below is relative to this directory,
except references to other directories of this sample set (`onboarding/`,
`gitops-template/`, `VERIFY-TODO.md`), which point into the full sample set.

This is sample material, not part of the product and not covered by product
support.

## What each directory holds

```text
./
├── argocd/apps/           # root Application points here: AppProject + the four layer Applications + the onboarding Application
├── components/            # component layer: TektonConfig fragments (Pruner, Results retention, Chains registry credential)
├── policies/              # policy layer: platform baseline Kyverno ClusterPolicies + the optional resolver constraint (Audit)
├── credentials/           # credential layer: admin-level Connectors + SealedSecrets (no plaintext), PaC Repository of this repository
├── projects/              # project layer: one declaration per project + what onboarding registers for it
├── templates/             # project-boundary generation templates (Application, AppProject patch, RoleBinding) + render.sh
├── onboarding/            # NOT in this directory: copy the onboarding/ directory of this sample set here (fifth Application)
└── .tekton/
    ├── validate.yaml                  # merge request check: kustomize build of every directory an Application renders
    └── onboard-changed-projects.yaml  # push to main changing projects/*.yaml: onboards every changed project (one file for all)
```

| Directory | Layer (series 02 §5) | Argo CD Application | Destination |
|---|---|---|---|
| `argocd/apps/` | — | `platform-root` | `argocd` on the Argo CD cluster |
| `components/` | component | `platform-components` (`prune: false`) | cluster-scoped |
| `policies/` | policy | `platform-policies` | cluster-scoped |
| `credentials/` | credential | `platform-credentials` (`selfHeal: false`) | `platform-connectors` |
| `projects/` | project | `projects` | `platform-connectors` (declarations); per project also `argocd`, the project namespace and the cluster-scoped platform project |
| `templates/` | — | none: read by the onboarding pipeline, not applied | — |
| `onboarding/` | — | `platform-onboarding` | `platform-connectors`; its ClusterRole and ClusterRoleBinding are cluster-scoped |

One Application per layer means a failing layer does not stop the others.
Rules the skeleton follows:

- **One management namespace.** `platform-connectors` holds the admin-level
  Connectors and their SealedSecrets, the published project declarations, the
  PaC Repository of this repository and the onboarding pipeline. Project members
  get no access to it.
- **No project application manifests here.** They live in each project's GitOps
  repository (see the `gitops-template/` directory of this sample set). What
  this repository holds per project is its boundary: the Argo CD Applications,
  the AppProject patch, the owners' RoleBinding, the Connector-mount grants
  and the exported platform project, all proposed by the onboarding pipeline as a merge request.
- **No plaintext credentials.** Only `SealedSecret` objects; see
  [`credentials/SEALED-SECRETS.md`](credentials/SEALED-SECRETS.md).
- **Namespaces are not created by Argo CD.** `platform-connectors` is created by
  the administrator and project namespaces by the onboarding pipeline, so no
  Application enables `CreateNamespace` and there is only one creator per
  namespace.
- **Policies start in Audit.** Read the PolicyReports, then switch
  `failureAction` to `Enforce`. The exception is
  `argocd-project-namespace-boundary.yaml`, Enforce from the start: it is the
  project boundary of series 02 §6.
- **The resolver rule is optional.** `policies/pipelinerun-source-baseline.yaml`
  (only the `cluster`, `hub` and `git` resolvers, no inline `pipelineSpec`) is
  a constraint the platform administrator enables per scenario, not part of the
  baseline. To turn it off, remove its line from `policies/kustomization.yaml`;
  the other policies stay in force. The baseline is `no-bare-taskrun.yaml`,
  `require-signed-images.yaml` and `onboarding-rolebinding-scope.yaml`
  (reports, and once switched to Enforce refuses, a RoleBinding the onboarding
  ServiceAccount writes outside namespaces labelled `cpaas.io/project`), plus
  `kyverno-reports-rolebindings.yaml`, the read access to RoleBindings and
  Roles the Kyverno reports controller needs: without it that policy cannot
  report anything, and applying `argocd-project-namespace-boundary.yaml`
  warns that the controller cannot read Roles.
  `argocd-project-namespace-boundary.yaml` belongs to the baseline as well:
  it refuses Role, RoleBinding, ResourceQuota, LimitRange and NetworkPolicy
  that Argo CD writes into project namespaces for project Applications
  ("Operating notes and hardening").
- **Keep Kyverno available.** A registered admission webhook with failure
  policy `Fail` refuses matching requests when it cannot reach Kyverno,
  including requests covered by Audit policies. Check webhook registration
  during maintenance: an absent webhook provides no enforcement, and an
  orderly scale-to-zero can remove Kyverno's resource webhooks. Run Kyverno
  highly available and prepare an emergency procedure to restore the service
  or remove and subsequently restore its resource webhook configurations.

## Prerequisites

- Argo CD (Alauda Container Platform GitOps 4.4) in namespace `argocd`, with
  this repository registered with a read-only credential. The `projects` layer
  writes Argo CD objects into `argocd` of `<cluster-name>`, so the sample
  assumes Argo CD manages the cluster it runs in.
- `<cluster-name>` is the name under which Alauda GitOps registered this ACP
  cluster in Argo CD: the ACP cluster name, `global` on the global cluster.
  Before the bootstrap, print it (no output means the cluster is not
  registered yet):
  `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster,cpaas.io/managed-by=acp -o go-template='{{range .items}}{{index .data "name" | base64decode}}{{"\n"}}{{end}}'`.
  Do not use `in-cluster`: in the default install the scope of that entry is
  namespace `argocd`, and the layers below the root Application deploy to other
  namespaces. What an Application may deploy is bounded by the destinations of
  its AppProject and by `policies/argocd-project-namespace-boundary.yaml`.
- Kyverno, the sealed-secrets controller, Alauda DevOps Pipelines 4.15 (Tekton
  Operator with Pipelines-as-Code, Tekton Chains, Manual Approval Gate) and
  Alauda DevOps Connectors 1.14 with the GitLab, Harbor, Nexus and SonarQube
  connector classes. The first `kubectl apply -k argocd/apps/` syncs
  ClusterPolicies and SealedSecrets, so their CRDs must exist before it.
- Namespace `platform-connectors`, created by the administrator before the
  bootstrap (no Application creates namespaces).
- The four Connectors automatic-creation Tasks installed into
  `platform-connectors` (they are neither in the catalog nor in this
  repository; see the onboarding README).
- The Chains registry credential: Secret `chains-registry-credential` (type
  `kubernetes.io/dockerconfigjson`) in the Chains namespace
  `tekton-pipelines`, created by the platform administrator before the first
  sync of `components/` (command in the header of
  `components/chains-registry-credential.yaml`). The platform team owns its
  Harbor robot, which has pull and push on `<project>` and `<project>-prod`
  of every onboarded project.
- Every PaC `Repository` of a self-hosted GitLab sets
  `spec.git_provider.url` (`https://git.example.com` here; done in
  `credentials/` and by onboarding). Without it Pipelines-as-Code v0.48.1
  sends commit status and comments, with the Repository's token, to
  `https://gitlab.com`.
- The PaC webhook registration controller configured for `git.example.com`,
  with its central webhook credential. This is a manual prerequisite: the
  credential is not a file of this repository. The controller uses the token
  in the Repository's own Secret first, and the central credential when that
  token is missing or refused. The developer token that onboarding puts into
  `<project>-gitops-auth` cannot manage webhooks, so the webhook of every
  project GitOps repository is created and removed with the central
  credential. The central credential is a Secret in the controller's
  namespace (`tekton-pipelines`), of any name, with key `provider.token`,
  labels `pac.tekton.alauda.io/provider-credential: "true"` and
  `pac.tekton.alauda.io/provider-type: gitlab`, and annotation
  `pac.tekton.alauda.io/provider-url: https://git.example.com`; exactly one
  such Secret may match a GitLab URL, and it serves every Repository of that
  URL. Its token needs scope `api` and the Maintainer role on the GitLab
  group of every project; a group access token covers only its own group.
  The controller also needs the address of Pipelines-as-Code: configure the
  platform's webhook URL, so that `controller-url` in ConfigMap
  `pipelines-as-code-info` is set. A Repository
  annotated `pac.tekton.alauda.io/webhook-registration-status: Failed` with
  reason `WebhookURLUnavailable` says that this address is missing. Where the
  controller is not used, add the webhooks of this repository and of each
  project GitOps repository in GitLab by hand, with three values:
  - URL: the address at which GitLab reaches the Pipelines-as-Code
    controller (Service `pipelines-as-code-controller`, port 8080, when
    GitLab runs in the same cluster and allows hooks to local addresses);
  - secret token: key `webhook.secret` of the Repository's Secret
    (`<project>-gitops-auth` for a project GitOps repository);
  - events: push, tag push, merge request and comments.
- An Argo CD repository credential template (`repo-creds`) for
  `https://git.example.com` that can read every project GitOps repository;
  onboarding registers the Applications, not the credential.
- The Harbor projects that onboarding creates must stay private; a public
  project would make the pull boundary between projects meaningless.
- The five credentials in `credentials/` sealed for your cluster.

## Bootstrap

1. Replace the placeholders (table below) in every file, and copy the
   `onboarding/` directory of this sample set to `onboarding/` here.
2. Check that each directory renders:

   ```bash
   for d in argocd/apps components policies credentials projects onboarding; do
     kustomize build "$d" >/dev/null && echo "PASS $d" || echo "FAIL $d"
   done
   ```

3. Create the root Application and the AppProject once:

   ```bash
   kubectl apply -k argocd/apps/
   ```

   From then on the root Application manages itself, the four layer
   Applications and `platform-onboarding`; every change goes through a merge
   request. `platform-onboarding` renders the `onboarding/` copied in step 1.

4. Onboard the declarations that were already in `projects/` before the
   bootstrap (`shop` and `payments` in this sample).
   `.tekton/onboard-changed-projects.yaml` starts only for a push to `main`
   made after this repository's PaC `Repository` (in `credentials/`) exists,
   so it never picks them up. Start the onboarding Run Template
   (`onboarding/run-template/`) once for each of them.

## Pre-merge validation with Pipelines-as-Code

`.tekton/validate.yaml` runs on every merge request to `main` and renders every
directory listed in its `paths` parameter. The PaC `Repository` of this
repository is a manifest of the credential layer,
[`credentials/pac-repository-platform-config.yaml`](credentials/pac-repository-platform-config.yaml),
in `platform-connectors`, next to its sealed token and webhook secret; the
webhook is created by the PaC webhook registration controller when the central
webhook credentials are configured (series 02 §5 and §11).

The Repository sets `spec.settings.pipelinerun_provenance: "default_branch"`:
PaC takes `.tekton/` from `main`, not from the merge request's source branch,
so a merge request cannot change what runs before it is reviewed (the runs
execute in `platform-connectors`, next to the admin Secrets; see "Operating
notes and hardening"). A change to `.tekton/` itself takes effect only after
it is merged.

The PipelineRun carries its definition inline: a `pipelineSpec` with the
catalog Tasks `git-clone` (clone) and `run-script` (one `kubectl kustomize`
per path), both taken through the hub resolver. Before the first merge
request, set the `image` of the render task
(`registry.example.com/catalog/kubectl:<tag>`) to an image of your registry
with `sh` and `kubectl`.

The optional resolver constraint (`policies/pipelinerun-source-baseline.yaml`)
does not accept an inline `pipelineSpec`. As this sample ships the policy, it
excludes `platform-connectors`, where these runs execute, so it does not
judge them. If you extend the constraint to that namespace, publish the two
tasks as a Pipeline in the catalog and replace the `pipelineSpec` with a hub
`pipelineRef` to it.

Re-run the check from a merge request with `/test validate`. See
[Trigger PAC Pipelines](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html)
for complete trigger syntax.

When adding a directory with its own Application, also add it to the `paths`
parameter in `.tekton/validate.yaml`.

## Onboarding on merge

`.tekton/onboard-changed-projects.yaml` runs when a push to `main` (a merged
request) adds or changes a declaration `projects/<project>.yaml`
(`on-path-change: "[projects/*.yaml]"`, Technology Preview in Pipelines 4.15).
The pattern also matches files below `projects/<project>/`, so the merge of a
registration (onboarding step 7) starts one run too; that run finds no changed
declaration and starts no onboarding.
It is one file for every project: it starts the Pipeline
`onboard-changed-projects` of `platform-connectors` (cluster resolver; shipped
in the onboarding directory), which

1. clones the pushed commit with its first parent (catalog `git-clone` 0.10),
2. lists the declarations the commit added, changed or renamed with
   `git diff --name-only HEAD~1 HEAD` (catalog `git-cli` 0.5; every
   declaration on the first commit of the repository; `projects/kustomization.yaml`
   and deleted declarations are left out),
3. for each of them reads the `name` field, waits until the `projects`
   Application has published that revision as ConfigMap `project-<name>`
   (param `sync-timeout`, 600 seconds), and creates one onboarding PipelineRun
   `onboard-<name>-*` with the same spec as the onboarding Run Template
   (catalog `kubectl` 0.1). The created names are the run's result
   `onboarding-runs`. The run succeeds once those runs are created; it does
   not wait for them, so whether each project is onboarded is the status of
   each PipelineRun listed in `onboarding-runs`.

A new project therefore needs one merge request that changes four places:
its declaration, its `configMapGenerator` entry in `projects/kustomization.yaml`,
its two files in `onboarding/` (the release-Connector RBAC and the
ScheduledTrigger, each listed with one line in `onboarding/kustomization.yaml`:
a file that is not listed there is not rendered; see
[`projects/platform-projects.md`](projects/platform-projects.md)),
and one more `imageReferences` entry `registry.example.com/<project>-prod/*` in
`policies/require-signed-images.yaml` (onboarding does not edit that policy, so
without it the project's release images are not verified);
no PipelineRun file is added. Outside this repository, the platform team
adds the project's Harbor projects `<project>` and `<project>-prod` to the
robot of the Chains registry credential (pull and push, Prerequisites);
without them Chains cannot store the signatures of the project's release
images. Every onboarding step except the GitOps
repository seed is create-or-reconcile, so a declaration change onboards
again without harm. The seed (step 6) copies the template only into an empty
repository, so a new environment also needs a merge request to the project's
GitOps repository that adds `envs/<env>/` and lists it in its
`.tekton/validate.yaml`; step 1 accepts only the GitLab subgroups
`apps gitops`, so adding a subgroup means changing the Pipeline first. The run fails for a declaration whose
`name` is not a DNS label or whose ConfigMap did not show the merged revision
in time; the runs for the other projects are still created. Fix the cause and
re-run it with a comment on the merge commit while that commit is still the
HEAD of `main` (Pipelines-as-Code requires the commented commit to be the
branch HEAD); otherwise start the onboarding Run Template for the project:

```text
/test onboard-changed-projects branch:main
```

The diff is taken against the pushed commit's first parent: a merge commit (or
a squashed merge) covers the whole merge request, while a direct push of
several commits covers only the last one; start a run for any other project
from the onboarding Run Template.

## What onboarding adds to this repository

Step 7 of the onboarding pipeline (series 02 §9) opens one merge request per
project against this repository through the catalog Pipeline
`gitops-repo-update` (`submitMode: pr`). Its update script is
[`templates/render.sh`](templates/render.sh), run inside the clone of this
repository; it reads `projects/<project>.yaml` and writes:

| File | From | What |
|---|---|---|
| `projects/<project>/platform-project.yaml` | the platform, exported by onboarding step 1 | the manually created platform project, without `status`, server-set metadata and the tracking markers Argo CD and the GitOps plugin add, so a new environment is initialized from the same manifest |
| `projects/<project>/appproject-patch.yaml` | `templates/appproject-patch.yaml` | source repository and one destination per environment |
| `projects/<project>/application-<env>.yaml` | `templates/application.yaml` | one Argo CD Application per environment |
| `projects/<project>/rolebinding-owners.yaml` | `templates/rolebinding-owners.yaml` | `admin` in namespace `<project>` for the `owners` groups |
| `projects/<project>/connector-mount-ci.yaml` | `templates/connector-mount-ci.yaml` | Role and RoleBinding `<project>-ci-mount` in `<project>`: `get` and `connectors/proxy` `*` on the Connectors `<project>-harbor`, `<project>-sonarqube` and `<project>-nexus` for ServiceAccount `default` in `<project>-build`, so the application CI can mount it |
| `projects/<project>/connector-mount-delivery.yaml` | `templates/connector-mount-delivery.yaml` | Role and RoleBinding `<project>-delivery-mount` in `<project>-cd`: `get` and `connectors/proxy` `*` on Connector `<project>-gitops-writer` for `<project>-delivery`, so CD can mount it |
| `projects/<project>/kustomization.yaml` | render.sh | lists the files above |

and adds `<project>` to `resources` in `projects/kustomization.yaml`. A re-run
with an unchanged declaration renders the same files, so no merge request is
opened. After the merge the `projects` Application applies them.

## Rebuild on a new cluster

The repository describes the platform, but five things are not in it and must
be brought back first, in this order:

1. Kyverno, the sealed-secrets controller and the Pipelines and Connectors
   components (Prerequisites).
2. The sealing key of the old sealed-secrets controller, or new ciphertext for
   every file in `credentials/` sealed against the new controller
   ([`credentials/SEALED-SECRETS.md`](credentials/SEALED-SECRETS.md), "Back up
   the sealing key").
3. The Chains signing key (`signing-secrets` in the Chains namespace) from its
   offline backup. With a new key instead, replace `<cosign-public-key-pem>` in
   `policies/require-signed-images.yaml` in the same change, or every release
   image fails verification. Create the Chains registry credential
   `chains-registry-credential` as well (Prerequisites) before `components/`
   is synced.
4. Namespace `platform-connectors` and the four Connectors automatic-creation
   Tasks in it.
5. Access to the Git hosting (Prerequisites): the read-only credential of
   this repository in Argo CD, the `repo-creds` template for
   `https://git.example.com`, and the central webhook credentials of the PaC
   webhook registration controller (or webhooks added by hand). Without the
   `repo-creds` template the project Applications cannot read their GitOps
   repositories and fail to compare with `authentication required`.

Then `kubectl apply -k argocd/apps/` and run onboarding for every declaration
in `projects/`. Until onboarding has created a project's namespaces, the
`projects` Application cannot apply the Roles and RoleBindings of
`projects/<project>/` (namespace not found) and reports a sync error; it
retries (`syncPolicy.retry` in `argocd/apps/projects.yaml`). Everything else
of the same sync is applied: the declaration ConfigMaps (so onboarding can
read them), the platform project, the AppProject patch and the Applications.
The platform project makes the platform create namespace `<project>` at
once, so the next retry applies the objects there; the first retry after
onboarding has created the other namespaces converges without a manual sync
(Argo CD v3.1.27, ServerSideApply). Re-running onboarding for a registered
project opens no
merge request; to confirm, look for a merge request, not at the `changed`
result. This relies on the declarations not sitting in a later sync wave than
the per-project objects; the sample sets no sync waves.

Git restoration does not recover external tool databases or registry contents.
Keep separate backups for any historical tool data you need. Before workload
Applications sync against a fresh registry, restore the images and their
`sha256-<digest>.sig` and `sha256-<digest>.att` artifacts from offline backups,
preserving their original manifest digests and discovery tags. Harbor can hide
Cosign signatures from the main artifact list: include its signature accessories
when building the backup inventory, or enumerate the signature tags explicitly.
Verify both signatures and provenance with the restored Chains public key and
normal registry TLS validation. Recreate identity-provider memberships separately;
source-cluster user IDs are not portable project configuration.

## Operating notes and hardening

What this sample leaves open, who can hit it, and the recommended hardening.

- **Pre-merge validation runs in the admin namespace.** The PaC `Repository`
  of this repository is in `platform-connectors`, so its runs could mount the
  admin Secrets and use the onboarding ServiceAccount. `default_branch`
  provenance limits that to `.tekton/` as merged, i.e. to people who can merge
  to `main` (who already control the platform through Argo CD). Stronger:
  register the Repository, with its own token Secret, in a separate namespace
  that holds no admin Secret (for example `platform-validation`, created by
  the administrator next to `platform-connectors`), and let the merge-triggered
  dispatcher create the onboarding runs in `platform-connectors` through a
  ServiceAccount that may only create PipelineRuns there (tektoncd-operator,
  *Advanced Repository Configuration*).
- **The onboarding ServiceAccount can use the admin Secrets.** RBAC gives it
  no Secret API access in `platform-connectors`, but it may create
  PipelineRuns there, and a run's Pods can mount any Secret of the namespace.
  Anyone who can create Pods or PipelineRuns in `platform-connectors`, or run
  as that ServiceAccount, has the admin credentials. Keep that namespace to
  platform administrators; optionally add a Kyverno rule that lets
  `project-onboarding` create only PipelineRuns of `project-onboarding` and
  `gitops-repo-update` with no inline spec and no `secret` workspaces (not
  enabled in this sample).
- **The projects layer shares the platform AppProject.** Files under
  `projects/<project>/` are rendered by onboarding and merged by review, but
  are applied with the `platform` AppProject, which allows ClusterRole,
  ClusterRoleBinding, RoleBinding and Connectors AccessPolicy in any
  namespace. A reviewer who misses
  an extra file in an onboarding merge request grants it. Hardening: a
  separate AppProject for the `projects` Application that allows only
  Application, AppProject, ConfigMap, RoleBinding and the platform project.
- **Promotion guardrails are not in the baseline.** `policies/` has no
  promotion rules. Wherever a production Connector exists, rules 1–3 of the
  Catalog page *Constrain Artifact Promotion with Kyverno*
  (`promotion-runs-use-a-template`, `no-taskrun-outside-a-template`,
  `no-pod-outside-a-template`), and rule 4
  (`template-changes-by-maintainers-only`) when promotion templates live in
  the project namespace, belong in the baseline; rules 5–11 stay optional.
  Follow that page for the exact policies.
- **The central Chains registry credential.** Secret
  `chains-registry-credential` in `tekton-pipelines` is a standing credential
  with push on every Harbor project whose images Chains signs, every
  `<project>-prod` included, outside the promotion's approval. This follows
  from storing signatures beside the image. Only platform administrators may
  read Secrets or create Pods in `tekton-pipelines`; check it like
  `signing-secrets` (`sample-app/chains/README.md`), and rotate the robot's
  token on a schedule like the other long-lived platform credentials.
- **Production images.** `require-signed-images` selects Pods by image
  reference; add a rule that admits only
  `registry.example.com/<project>-prod/*@sha256:*` in the `*-prod` namespaces,
  and consider the optional provenance conditions in that file.
- **Policy exceptions.** Where exceptions are in effect, Kyverno
  `PolicyException` objects can exempt resources from any policy rule they
  name, in any of these policies;
  restrict who may create them when the policies are meant as a baseline.
  Before you plan a break-glass path on PolicyExceptions, check the exception
  settings of your Kyverno installation (whether exceptions are enabled, and
  the exception namespace): an exception takes effect only in the namespace
  configured there.
- **The project boundary is a Kyverno policy.** On ACP, Alauda GitOps manages
  the AppProject named after each platform project, with `sourceRepos` and
  `destinations` (destinations merged with all namespaces of the project).
  `templates/appproject-patch.yaml` therefore sets only those two fields; put
  any further restriction into the Kyverno policy, not into that AppProject.
  The `projects` Application shows that AppProject as OutOfSync, which is
  expected, and Argo CD attempts the automated sync of `projects` once every
  five minutes, so allow that long for a self-heal of that Application
  (`onboarding/README.md`, assumption 10). The boundary of series 02 §6 (no
  Role, RoleBinding, ResourceQuota, LimitRange or NetworkPolicy from the
  project GitOps repository) is enforced by
  `policies/argocd-project-namespace-boundary.yaml` (Kyverno, Enforce,
  `allowExistingViolations: false`; with Kyverno's default an UPDATE of an
  existing RoleBinding passes). It refuses those kinds when Argo CD writes them
  for any Application other than `projects` in a namespace labelled
  `cpaas.io/project` (except `cpaas-system`); onboarding and platform
  administrators are not affected while Kyverno runs. Limits: the Kyverno
  registered webhook fails closed (failure policy `Fail`): when it cannot
  reach Kyverno, matching writes (the five kinds in project namespaces, by
  any identity, onboarding and administrators included) are refused. Restore
  Kyverno first, or follow the platform emergency procedure to remove and
  restore the resource webhook configurations. The refusal comes at apply
  time, so the sync shows the Kyverno message and keeps retrying; only labelled
  project namespaces are covered; a PolicyException break-glass depends on the
  exception settings ("Policy exceptions" above); Kyverno and the policy must
  run on every cluster Argo CD deploys to, with that cluster's Argo CD
  identity; the exemption reads the annotation tracking id. This sample does
  not define the platform's Kyverno maintenance procedure or cover a second cluster, `label`
  tracking, and a `projects` sync under the policy. Alternative: point the
  project Applications at an
  AppProject of another name, e.g. `<project>-deploy`, that holds the
  `namespaceResourceBlacklist`; Argo CD then refuses those kinds itself. The
  GitOps Applications page of a project in the ACP console lists the
  Applications whose `spec.project` is the project name; find the others in the
  Argo CD UI or CLI.
- **The pre-merge check is defined inline.** `.tekton/validate.yaml` of this
  repository and of every project GitOps repository composes two catalog
  Tasks in a `pipelineSpec`; set the tool image of the render task before the
  first merge request ("Pre-merge validation with Pipelines-as-Code"). The
  optional resolver constraint does not accept an inline `pipelineSpec`: in
  the project namespaces each validation run is reported while the policy is
  in Audit, and is not created once it is in Enforce. Before that switch,
  publish the two tasks as a Pipeline in the catalog and put a hub
  `pipelineRef` into the template of the project GitOps repositories and
  into the repositories already seeded.
- **PaC Repository without the GitLab URL leaks the token (product
  behaviour).** A `Repository` without `spec.git_provider.url` makes
  Pipelines-as-Code v0.48.1 send status and comment calls, with the
  Repository's GitLab token, to `https://gitlab.com`. Every Repository of
  this sample set sets it;
  check Repositories created by hand, and rotate a token that was sent.
- **Removing a registration removes the platform project.** Reverting the
  registration commit, deleting `projects/<project>/` or dropping it from
  `projects/kustomization.yaml` makes the `projects` Application prune the
  platform project, and with it namespace `<project>` and what it holds
  (Connectors, PaC Repository, Secrets). Do it only to offboard a project; then
  delete the other project namespaces and the AppProject by hand.
- **Keep the central webhook credential while Repositories depend on it.**
  When a PaC Repository is deleted, also with its namespace when a project
  is offboarded, the webhook registration controller removes its webhook with
  the same credentials it creates webhooks with. The deletion does not wait
  for that: when the webhook cannot be removed, for example because the
  central credential was deleted first and the Repository's own token is a
  developer token, the Repository is deleted anyway, the controller records a
  Warning event, and the webhook stays in GitLab; delete it there by hand.
  Remove managed webhooks through the controller rather than in GitLab: when
  a webhook was already deleted in GitLab, opting the Repository out with the
  label `pac.tekton.alauda.io/webhook-registration-disabled: "true"`
  completes only while the central credential is configured; until then the
  Repository keeps its finalizer and its registration status stays `Failed`.
- **Declarations that name platform namespaces.** Onboarding refuses derived
  namespaces from a fixed list (`kube-*`, `argocd`, `tekton-*`, `*-system`,
  `platform-*`, ...) and any existing namespace that is not labelled
  `cpaas.io/project=<project>`. Extend the list with your platform's
  namespaces; the review of the declaration remains the main control.

## Replacement points

| Placeholder | Where | Meaning |
|---|---|---|
| `https://git.example.com/platform/platform-config.git` | `argocd/apps/*.yaml`, `credentials/pac-repository-platform-config.yaml` | URL of this repository (with `.git` for Argo CD) |
| `https://git.example.com` | `credentials/pac-repository-platform-config.yaml` (`spec.git_provider.url`) | GitLab API base URL for Pipelines-as-Code |
| `<cluster-name>` | `argocd/apps/*.yaml`, `templates/*.yaml` | Argo CD cluster name that Alauda GitOps registered for this ACP cluster (the ACP cluster name, `global` on the global cluster; not `in-cluster`) |
| `argocd` | `argocd/apps/*.yaml`, `templates/*.yaml` | Argo CD namespace |
| `platform-connectors` | `argocd/apps/`, `policies/`, `credentials/`, `projects/` | management namespace |
| `<platform-project-group>`, `<platform-project-kind>` | `argocd/apps/appproject-platform.yaml` | API group and kind of the platform project resource |
| `https://git.example.com`, `https://registry.example.com`, `https://nexus.example.com`, `https://sonar.example.com` | `credentials/connector-*.yaml` | tool addresses |
| `<encrypted>` | `credentials/sealedsecret-*.yaml` | kubeseal output for your cluster |
| `tekton-pipelines` | `policies/no-bare-taskrun.yaml` | namespace of the Tekton controller ServiceAccount |
| `registry.example.com/shop-prod/*`, `registry.example.com/payments-prod/*`, `<cosign-public-key-pem>` | `policies/require-signed-images.yaml` | release repositories (one entry per project; onboarding does not add them) and the Chains public key |
| `registry.example.com/catalog/kubectl:<tag>` | `.tekton/validate.yaml` (`image` of the render task) | an image of your registry with `sh` and `kubectl` |
| `onboard-changed-projects` | `.tekton/onboard-changed-projects.yaml` | merge-triggered PipelineRun; its Pipeline name must match the one deployed from the onboarding directory |
| `system:serviceaccount:platform-connectors:project-onboarding` | `policies/onboarding-rolebinding-scope.yaml` | the onboarding ServiceAccount |
| `system:serviceaccount:cpaas-system:argocd-manager`, `system:serviceaccount:argocd:argocd-gitops-argocd-application-controller` | `policies/argocd-project-namespace-boundary.yaml` | identities Argo CD writes with: the ServiceAccount of the cluster Secret Alauda GitOps registered (`kubectl -n argocd get secret -l cpaas.io/managed-by=acp`, then a TokenReview of its token) and the application controller's own ServiceAccount (`in-cluster`). Required check after applying the policy, as a cluster administrator, once per identity: `kubectl -n <project>-test create rolebinding boundary-probe --clusterrole=view --group=nobody --dry-run=server --as=<identity>` in a namespace labelled `cpaas.io/project` must be refused with this policy's message (`Argo CD (<identity>) may not CREATE RoleBinding ...`); if it is created, the identities do not match your cluster and the boundary is absent (`VERIFY-TODO.md` R3-8) |
| `projects` | `policies/argocd-project-namespace-boundary.yaml` | name of the Application that applies `projects/` (`argocd/apps/projects.yaml`) |
| `cpaas-system` | `policies/argocd-project-namespace-boundary.yaml` | `cpaas.io/project` value of the platform's system namespaces |
| `shop`, `shop-platform-owners`, `group:release-managers` | `projects/`, `templates/` | project names, owner group and approver group |
| `admin` | `templates/rolebinding-owners.yaml` | ClusterRole granted to the owners in the project namespace |
| `default` | `templates/connector-mount-ci.yaml` | ServiceAccount the application CI runs as in `<project>-build`: the TektonConfig `default-service-account`, `default` when that is empty |
| retention / pruning values | `components/*.yaml` | your platform defaults |
| `chains-registry-credential`, `/etc/chains-registry`, `tekton-chains-controller` | `components/chains-registry-credential.yaml` | Secret of the Chains registry credential in the Chains namespace (`tekton-pipelines`), its mount path, and the name of the Chains controller Deployment and container |
