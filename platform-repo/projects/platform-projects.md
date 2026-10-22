# Platform projects

A platform project is a Kubernetes resource on the platform, but it is **created
manually on the platform first** (the "Managing Platform Configuration and Onboarding Isolated Projects" article, step 1). Onboarding does not
block on it: the administrator creates the project in the platform console, then
the onboarding pipeline exports its manifest (`kubectl get <platform-project-kind>
<name> -o yaml` without `status` and server-set metadata) and proposes it as
`<project>/platform-project.yaml` in the same merge request that registers the
project's Argo CD Applications (step 7). Once merged, the `projects` Application
applies it, so a new environment is initialized from the same manifest. The
platform project API kind `<platform-project-kind>` is a placeholder; confirm it
on your platform.

Until the onboarding pipeline has exported a manifest, this list is the record
of which platform projects must exist before a declaration is merged.

| Platform project | Declaration | Created manually | Manifest exported | Notes |
|---|---|---|---|---|
| `shop` | `shop.yaml` | required before merging `shop.yaml` | `shop/platform-project.yaml`, by the onboarding merge request | first sample project |
| `payments` | `payments.yaml` (minimal declaration) | required before merging `payments.yaml` | `payments/platform-project.yaml`, by the onboarding merge request | second sample project, used to prove that cross-project image pulls are denied |

## Adding a project

1. Create the platform project on the platform (console or API).
2. Add a row to the table above.
3. Add `<project>.yaml` next to `shop.yaml` and a matching `configMapGenerator`
   entry in `kustomization.yaml`.
4. In the same merge request, add the project's two files to `onboarding/`
   (the copy of the onboarding directory in this repository): copy
   `rbac/release-connectors-shop.yaml` and `triggers/shop.yaml`, change the
   project name in them, and list both in `onboarding/kustomization.yaml`.
   Without the first, step 3 of onboarding cannot write the project's
   promotion Connectors into `platform-connectors`; without the second, the
   project gets no scheduled rotation. `payments` in this sample shows the
   result.
5. In the same merge request, add the project's release registry project
   `registry.example.com/<project>-prod/*` to the `imageReferences` of
   `policies/require-signed-images.yaml`. Onboarding does not edit that
   policy; without the entry, the project's release images are not verified.
6. Open a merge request; the validation pipeline (`../.tekton/validate.yaml`)
   renders every directory before merge.
