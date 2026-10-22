# Verify Chains signatures and provenance

中文版本：[README.zh-CN.md](README.zh-CN.md)。

This directory accompanies the "From Commit to Production on ACP" article.
The platform signs images with Tekton Chains (a platform-wide configuration
described in the platform configuration article). It shows how a project
checks the result before promotion or before a release is approved.

| File | What it does |
|---|---|
| `verify.sh` | `cosign verify` (signature) and `cosign verify-attestation --type slsaprovenance` (provenance) of one image by digest, with the platform public key `cosign.pub` |

```bash
IMAGE=registry.example.com/shop/hello@sha256:<digest> COSIGN_PUB=./cosign.pub IGNORE_TLOG=true ./verify.sh
```

- Get `cosign.pub` from the platform team. It is the `cosign.pub` entry of the
  Chains `signing-secrets` Secret; the export command is in the header of
  `verify.sh`. Do not ask for read access to that Secret: it also holds the
  private key `cosign.key` and its password, so `get` on it must stay with
  platform administrators. The platform can publish `cosign.pub` in a
  ConfigMap or a public repository instead (this sample does not).
- Before enabling signing, a platform administrator confirms that only
  platform administrators can read `signing-secrets`: check the
  ServiceAccounts of each project namespace with
  `kubectl auth can-i get secret/signing-secrets -n tekton-pipelines --as=system:serviceaccount:<namespace>:<serviceaccount>`
  and review the ClusterRoleBindings that grant read access to Secrets
  cluster-wide.
- Check the central Chains registry credential the same way (Secret
  `chains-registry-credential` in `tekton-pipelines`, see "Where signatures
  are stored"): it is a standing credential with push on every Harbor project
  whose images Chains signs, `shop-prod` included, outside the promotion's
  approval. Only platform administrators may read it or create Pods in
  `tekton-pipelines`:
  `kubectl auth can-i get secret/chains-registry-credential -n tekton-pipelines --as=system:serviceaccount:<namespace>:<serviceaccount>`.
- A valid signature and provenance prove that the image was signed with the
  platform's Chains key (a TaskRun reported the image), not which cluster or
  which Pipeline produced it. The same key can be restored on another cluster
  (`platform-repo/README.md`, "Rebuild on a new cluster"), so cluster origin
  depends on who holds the key. Chains signs every TaskRun that reports an
  image, merge-request builds in `hello-mr` included. Before a promotion,
  check that the CI run that reported the digest ended `Succeeded`.
  Checking the Pipeline name in the provenance predicate (optional
  `attestations` block in the platform repository's
  `policies/require-signed-images.yaml`) narrows mistakes, such as a CI image
  sent to production. It does not tie a release to the platform's promotion
  Pipeline: the name is only the Pipeline's name, any namespace can run a
  Pipeline of that name. The sample expects Chains
  `artifacts.taskrun.format: slsa/v1`, which emits SLSA provenance v0.2 and
  carries no namespace of the run. Its verification command therefore uses
  cosign `--type slsaprovenance`; a different format requires a matching type
  and policy field paths.
- Verify by digest only. The digest of a CI build is the `IMAGE_DIGEST` result
  of the `build-image` task; the digest of a release image is the
  `promoted-digest` result of the promotion run (`../promotion/`).
- On an air-gapped platform without a transparency log, set `IGNORE_TLOG=true`
  (without it the checks fail on every image).
- To see what is stored, use `cosign tree` or `verify.sh`, not the artifact
  list of the Harbor UI: that list does not show the signature tags.
- Do not take the TaskRun annotation `chains.tekton.dev/signed: "true"` as
  proof of a signature: Chains sets it on every
  TaskRun even while it has no signing key (`signing-secrets` empty, controller
  log `No signer x509 configured`) and pushes no `.sig` / `.att`. Only
  `verify.sh` (or `cosign tree` showing the signature and attestation of the
  digest) tells. With a key, `true` also marks TaskRuns and PipelineRuns that
  produced no image, and `failed` means the signature could not be pushed
  (no usable registry credential, see "Where signatures are stored").
- Deploy-time verification is a platform baseline and is not part of this
  directory: the platform repository ships the Kyverno `verifyImages` policy
  `require-signed-images` (its `policies/require-signed-images.yaml`) for the
  release repositories, with the same `cosign.pub`.

## Where signatures are stored, and with which credential

Chains stores the signature and the attestation of an image beside the image,
as the tags `sha256-<digest>.sig` and `sha256-<digest>.att` of the same
repository. The platform sets no storage location. Verify without
`COSIGN_REPOSITORY`; the attestor entry of the platform policy
`require-signed-images` has no `repository` attribute.

- **The run identity's credential first.** Chains first tries the registry
  credentials of the run's ServiceAccount (`secrets` and
  `imagePullSecrets`). A credential there whose registry matches the image is
  used first, so it must be able to push to the image's Harbor project. In
  this sample, CI builds sign this way: onboarding binds a registry credential
  of the project to `default` in `shop-build`, and Chains stores the CI
  signature beside the image with it. Where a credential on that identity
  cannot push to the image's project, remove it from the identity; the central
  credential below then signs the CI build.
- **Central credential (fallback).** Where the run identity holds no
  credential that matches the image, Chains pushes with one registry
  credential of the Chains controller, which the platform team configures
  once: `components/chains-registry-credential.yaml` of the platform
  repository (`platform-repo/` in this sample set) mounts Secret
  `chains-registry-credential` into the controller.
  Its Harbor robot has pull and push on every Harbor project whose images
  Chains signs (here `shop` and `shop-prod`), and the platform team extends it
  when a project is onboarded. Chains does not use a Connector.
  In this sample the promotion signs this way. The promotion does push to
  `shop-prod`, but with the production registry Connector
  `shop-prod-registry`, mounted through a `connectors-csi` workspace (with
  `../promotion/access-policy.yaml` applied, released only after approval).
  That credential is not on the release identity `shop-release`'s
  ServiceAccount, and Chains reads only the ServiceAccount's `secrets` and
  `imagePullSecrets`, never a Connector. So Chains finds no matching
  credential there and stores the promotion run's signature and attestation
  beside the release image in `shop-prod` with the central credential. Keep
  it that way: a credential for the same registry on the ServiceAccount of
  `shop-release` would be used first and would need push on `shop-prod`.
- **With a signing key configured, a signature that is not stored does not
  fail the run.** The TaskRun and
  the PipelineRun succeed and the commit status stays green. It shows in the
  TaskRun annotation `chains.tekton.dev/signed: failed`, in a `Warning` event
  on the TaskRun and in the Chains log. Run `verify.sh` before a promotion and
  on the release image.
- **Promotion.** The release image verifies with the promotion run's own
  signature and provenance. The Run Template ships with the image mapping
  only. Optionally, the CI build's signature and attestation can be copied to
  the release repository as well: add the `.sig` and `.att` tags of the digest
  to `imageMappings`, after the image mapping (`promoted-digest` is the digest
  of the first destination). The sample promotion Pipeline's `validate-digest`
  accepts them after the image mapping, and only as the `.sig` / `.att` tags of
  the same digest with the same tag in the staging and release repositories;
  any other extra mapping (another digest, a plain tag, another repository, or
  the image not first) stops the run before the approval (the "From Commit to Production on ACP" article).
  The copy task uses `multiArch: all`: for a single-platform image the explicit
  mappings copy that image and its attachments; for an image index the setting
  preserves the index and all platforms. It does not discover `.sig` or `.att`
  tags; keep those mappings explicit. With another Chains storage format or
  attachment layout, adapt the mappings and validate the copied evidence.

## Optional hardening: a separate signature repository

Not used by this sample. A platform can keep all signatures in one Harbor
project of their own: Chains `storage.oci.repository` in TektonConfig
`spec.chain`, a setting for the whole cluster. Then:

- the robot of the central credential also needs push on that project, and
  the precondition above applies to that repository as well;
- export `COSIGN_REPOSITORY=<that repository>` before `verify.sh` and
  `cosign tree`, and give the attestor entry of the platform policy the same
  `repository`; Kyverno must be able to read that repository;
- the CI image and the release image have the same digest, so they share one
  `sha256-<digest>.sig` / `.att` tag there, and the promotion's signature and
  provenance replace the CI build's: verify the CI build before promotion, and
  do not add the `.sig` / `.att` mappings to the promotion run.

This is sample material, not part of the product.
