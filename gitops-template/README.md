# Project GitOps repository template

中文版本：[README.zh-CN.md](README.zh-CN.md)。

Template for a project's GitOps repository, from the Alauda DevOps best-practice
series, the platform configuration article. The onboarding pipeline copies this directory
into a new repository for each project (for example `shop/gitops/config`, that
is repository `config` in the project's GitLab subgroup `gitops`), creates one
environment directory per environment in the project declaration, and registers
the repository with Pipelines-as-Code (PaC `Repository` `<project>-gitops`).
Argo CD reads it through the project's Applications; the read credential is a
platform prerequisite, not created by onboarding: one Argo CD repository
credential template (`repo-creds`) for `https://git.example.com` covers every
project GitOps repository. The repository cannot be
`shop/gitops` itself: that path is the subgroup `gitops` the declaration asks
for, and a GitLab project and a subgroup cannot share a path. Every path below
is relative to this directory, so it can be copied elsewhere as is.

This is sample material, not part of the product and not covered by product
support.

## Layout

```text
./
├── base/                 # application manifest skeleton (Deployment + Service)
├── envs/
│   ├── _env/             # copied at seeding to envs/<env>/ for every environment without its own template (envs/test/)
│   │   └── kustomization.yaml
│   └── _prod/            # copied at seeding to envs/prod/: pulls from the release project (newName)
│       └── kustomization.yaml
├── .tekton/
│   └── validate.yaml     # merge request check: render every overlay; two Tasks from the platform catalog
└── README.md             # platform conventions (below)
```

Argo CD renders one Application per environment from `envs/<env>/`.

## Platform conventions

### Trigger and re-run pipelines with `/test`

Re-run the validation pipeline from a merge request with:

```text
/test validate branch:<branch>
```

See [Trigger PAC Pipelines](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html)
for complete trigger syntax.

### Images by digest only

Manifests reference images as `registry.example.com/<project>/<image>@sha256:<digest>`,
never by tag. Promotion changes the `digest` of the `images` entry in
`envs/<env>/kustomization.yaml`; nothing else in the overlay changes. For
production that holds from the first update on: seeding creates `envs/prod`
from `envs/_prod`, whose `newName` already points at the release project
(`registry.example.com/<project>-prod/<image>`), so the delivery pipeline only
ever writes the digest there.

The first production deployment waits for the first promoted image: until a
promotion's digest is merged into `envs/prod`, the prod overlay carries the
`<digest>` placeholder and its Application cannot start a Pod.

### The merge request check uses Tasks from the platform catalog

`.tekton/validate.yaml` composes two Tasks of the platform catalog in an
inline `pipelineSpec`: `git-clone` clones the merge request's revision, and
`run-script` renders every listed path with `kubectl kustomize`. Both are
taken through the hub resolver (`resolver: hub`) with a pinned version, so
the check needs no Pipeline of its own in the catalog. Set the `image` of the
render task in the template repository before the first onboarding (an image
of your registry with `sh` and `kubectl`): seeding does not change it.

The platform may enable an optional constraint
(`policies/pipelinerun-source-baseline.yaml` of the platform repository) that
accepts only PipelineRuns whose `pipelineRef` uses the `cluster`, `hub` or
`git` resolver. It does not accept an inline `pipelineSpec`: while the policy
is in Audit, each run of this check is reported in the PolicyReport of the
project namespace; in Enforce the run is not created. Where that constraint
is on, publish the two tasks as a Pipeline in the catalog and replace the
`pipelineSpec` with a hub `pipelineRef` to it. Keep the inline form where the
constraint is off.

### Who may change `main`, and `envs/prod` in particular

Argo CD deploys whatever is on `main`, so `main` of this repository is the
deployment boundary of the project. What the sample sets up and what it
leaves to you:

- Onboarding registers the repository with PaC using the project's
  `developer` group token and `pipelinerun_provenance: default_branch`, so
  `.tekton/` runs as merged, never as proposed by a merge request.
  A merge request that changes `.tekton/validate.yaml` therefore continues to
  use the current `main` definition until that merge request is merged.
- The Developer token includes the `api` scope. GitLab can use that scope to
  modify an unprotected branch through its API even when the token lacks
  `write_repository`; treat it as write-capable until `main` is protected and
  the protection is verified.
- CD writes with the separate `maintainer` token of Connector
  `<project>-gitops-writer`: `envs/test` by direct commit to `main`,
  `envs/prod` by merge request.
- **Not set up by the sample:** protection of `main` and approval of
  `envs/prod` changes. Onboarding does not configure the GitLab project
  (branch protection, code owners), so until you do, anyone holding the
  writer token, or maintainer rights in the group, can push `envs/prod`
  straight to `main` and skip the promotion approval. A Maintainer token can
  also change branch protection and code-owner settings, so protection of
  `main` does not constrain that same token. For production, separate the
  production branch or repository and use a project-scoped writer that may
  propose a merge request but cannot change its protection or push/merge it.
  Keep direct test writes on their own path and configure a separate reviewer.
  This requires adapting the sample CD repository URL and Argo CD source.

  Where the GitLab tier supports enforced code-owner approval, require it on
  the protected production path and add a rule such as:

  ```text
  /envs/prod/ @<release-managers-group-path>
  ```

  Verify the actual writer is refused a direct production push and cannot
  remove the rule, while a reviewed merge and test update still work. A
  reviewed server-side hook is another option on self-managed GitLab. Until
  the selected control passes those checks, production review is an operating
  convention in this sample.

## Check locally

```bash
for d in envs/*/; do
  kustomize build "$d" >/dev/null && echo "PASS $d" || echo "FAIL $d"
done
```

## Replacement points

| Placeholder | Where | Meaning |
|---|---|---|
| `registry.example.com/shop/hello` | `base/deployment.yaml`, `envs/_env/kustomization.yaml`, `envs/_prod/kustomization.yaml` | staging image repository; replace the literal registry, project and image values |
| `registry.example.com/shop-prod/hello` | `envs/_prod/kustomization.yaml` (`newName`) | release image repository; replace the literal registry, project and image values |
| `<digest>` | `envs/_env/kustomization.yaml`, `envs/_prod/kustomization.yaml` | image digest written by the delivery pipeline |
| `shop-test` / `shop-prod` | `envs/_env/kustomization.yaml`, `envs/_prod/kustomization.yaml` | environment namespaces; replace the literal values during seeding |
| `envs/<environment>` (generated from `envs/_env` or `envs/_prod`) | `.tekton/validate.yaml` (`paths`) | the generated environment directories; list every seeded overlay |
| `<registry>/<catalog-project>/kubectl:<tag>` | `.tekton/validate.yaml` (`image` of the render task) | an air-gapped image of your registry with `sh` and `kubectl`; set host, project and tag in the template repository |
