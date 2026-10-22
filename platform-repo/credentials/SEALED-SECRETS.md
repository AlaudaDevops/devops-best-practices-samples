# Sealed Secrets in the credential layer

中文版本：[SEALED-SECRETS.zh-CN.md](SEALED-SECRETS.zh-CN.md)。

This directory holds the **admin-level Connectors** that the onboarding pipeline
uses to create projects, accounts and tokens in GitLab, Harbor, Nexus and
SonarQube. Each Connector needs a credential. Those credentials are stored in git
**only** as [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets):
you commit a `SealedSecret` (ciphertext), Argo CD applies it, and the
sealed-secrets controller in the cluster decrypts it into a normal `Secret` in
`platform-connectors`.

**Never commit a plaintext `Secret`, `.env` file, token, password, PEM or
kubeconfig to this repository — not even "temporarily".** If you cannot reach
the controller to seal a value, stop and ask the platform administrator.

## Flow

```text
credentials/sealedsecret-<tool>-admin.yaml  (ciphertext, in git)
        |  Argo CD sync (Application platform-credentials)
        v
SealedSecret/<tool>-admin   in platform-connectors
        |  sealed-secrets controller decrypts
        v
Secret/<tool>-admin         in platform-connectors  <- referenced by Connector/<tool>-admin
```

- The files in this directory contain `<encrypted>` **placeholders**. They do
  not decrypt anywhere; regenerate each of them for your cluster before the
  first sync.
- Sealing is **strict** by default: the ciphertext is bound to both the
  namespace (`platform-connectors`) and the Secret name. Renaming or moving a
  Secret means sealing it again.
- The `platform-credentials` Application syncs with `selfHeal: false`, because
  the controller writes status back onto its objects (see `../argocd/apps/platform-credentials.yaml`).

## Secret types per tool

| File | Secret type | Keys | Connector auth |
|---|---|---|---|
| `sealedsecret-gitlab-admin.yaml` | `connectors.cpaas.io/gitlab-pat-auth` | `token` | `patAuth` |
| `sealedsecret-harbor-admin.yaml` | `kubernetes.io/basic-auth` | `username`, `password` | `basicAuth` |
| `sealedsecret-nexus-admin.yaml` | `kubernetes.io/basic-auth` | `username`, `password` | `basicAuth` |
| `sealedsecret-sonarqube-admin.yaml` | `connectors.cpaas.io/bearer-token` | `token` | `tokenAuth` |
| `sealedsecret-platform-config-auth.yaml` | `Opaque` | `provider.token`, `webhook.secret` | none: read by the PaC `Repository` in `pac-repository-platform-config.yaml` |

The account behind each credential must be allowed to create groups / projects /
repositories / users in that tool; see the auto-creation task page of each tool
in the Alauda DevOps Connectors documentation for the exact permissions.

## Seal a credential

Fetch the controller's **public** certificate once (it is safe to share):

```bash
kubeseal --context <kube-context> \
  --controller-namespace <sealed-secrets-namespace> \
  --controller-name <sealed-secrets-controller> \
  --fetch-cert > sealing-cert.pem
```

Build the plaintext Secret in memory and pipe it straight into `kubeseal`; never
apply or save the plaintext:

```bash
kubectl create secret generic gitlab-admin -n platform-connectors \
  --type=connectors.cpaas.io/gitlab-pat-auth \
  --from-literal=token=<placeholder> \
  --dry-run=client -o yaml \
  | kubeseal --cert sealing-cert.pem --format yaml \
  > sealedsecret-gitlab-admin.yaml
```

The result has this shape (ciphertext shortened to a placeholder):

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: gitlab-admin
  namespace: platform-connectors
spec:
  encryptedData:
    token: <encrypted>
  template:
    metadata:
      name: gitlab-admin
      namespace: platform-connectors
    type: connectors.cpaas.io/gitlab-pat-auth
```

Keep the Series header comment at the top of the file, open a merge request, and
the validation pipeline renders the directory before merge.

`<kube-context>` is the kubeconfig context of the target cluster (not the
Argo CD cluster name `<cluster-name>` used elsewhere in this repository).

## Back up the sealing key

A `SealedSecret` can only be decrypted by the controller whose key sealed it.
When the platform is rebuilt from this repository on a new cluster (the "Managing Platform Configuration and Onboarding Isolated Projects" article), a new controller generates a new key and none of the files here
decrypts: the admin Connectors have no Secret and onboarding steps 2–5 fail.
Do one of the following, and write down which one your platform uses:

- Back up the controller's sealing keys (the Secrets labelled
  `sealedsecrets.bitnami.com/sealed-secrets-key` in
  `<sealed-secrets-namespace>`) to an offline store outside this repository,
  and restore them into the new cluster **before** the first sync of
  `platform-credentials`.
- Or, on the new cluster, fetch the new certificate and seal every credential
  of this directory again (the plaintext comes from the tools, never from
  git), then merge the new ciphertext before the first sync.

The key backup is itself a credential: whoever holds it can decrypt every
file here.

## Rotate a credential

Seal the new value the same way and commit the new ciphertext; git history is
the audit trail. The controller updates the `Secret` in place and the Connector
picks it up. Project-level credentials written by the auto-creation tasks are
**not** stored here — they are rotated by re-running the tasks (the "Managing Platform Configuration and Onboarding Isolated Projects" article).
