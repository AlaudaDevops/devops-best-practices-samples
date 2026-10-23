# 验证 Chains 签名和 provenance

English version：[README.md](README.md)。

本目录配套“从提交到上线”文章。平台通过 Tekton Chains 签名镜像；项目在晋级或发布审批前按 digest 验证签名和 SLSA provenance。

| 文件 | 作用 |
| --- | --- |
| `verify.sh` | 使用平台公钥 `cosign.pub`，按 digest 执行 `cosign verify` 和 `cosign verify-attestation --type slsaprovenance` |

```bash
IMAGE=registry.example.com/shop/hello@sha256:<digest> \
COSIGN_PUB=./cosign.pub IGNORE_TLOG=true ./verify.sh
```

## 使用前必须确认

- `cosign.pub` 由平台团队从 Chains `signing-secrets` Secret 导出。不要申请读取该 Secret：它同时包含私钥 `cosign.key` 及密码；平台也可以把公钥发布到 ConfigMap 或公开仓库。
- 平台管理员要用真实项目 ServiceAccount 检查不能读取 `signing-secrets`，并检查 `chains-registry-credential` 的读取范围。只有平台管理员应能在 `tekton-pipelines` 创建 Pod。
- 如果平台为 Secret 启用不可变设置，应将 `signing-secrets` 视为不可原地修改的密钥对象。轮换时在维护窗口创建并验证新 Secret，再同步更新公钥和验签策略；不要直接改原 Secret 的密钥数据。
- 签名和 provenance 只能证明使用了平台 Chains key，不能自动证明镜像来自哪一个集群或 Pipeline。晋级前仍需核对 CI PipelineRun 成功、事件为 main push，且 digest 正确。
- 只按 digest 验证：CI digest 来自 `build-image` TaskRun 的 `IMAGE_DIGEST`，发布 digest 来自 promotion 的 `promoted-digest`。
- air-gapped 环境没有透明日志时设置 `IGNORE_TLOG=true`。签名若放在独立仓库，设置 `COSIGN_REPOSITORY=<signature repository>`。
- 用 `cosign tree` 或本脚本查看附件，不要只看 Harbor UI 的普通 artifact 列表。

不要把 TaskRun 注解 `chains.tekton.dev/signed: "true"` 当成签名证据。没有 signing key 时 Chains 也可能设置该注解但不推送 `.sig`/`.att`；只有 `verify.sh` 或 `cosign tree` 显示指定 digest 的签名和 attestation 才能证明签名存在。`signed: failed` 表示附件推送失败，需要检查 registry credential 和 Chains 日志。

## 签名存储和使用的凭据

默认情况下签名与 attestation 存在镜像所在的同一个 registry 仓库，标签为 `sha256-<digest>.sig` 和 `sha256-<digest>.att`。本样例不设置 `COSIGN_REPOSITORY`，平台策略的 attestor 也不设置独立 repository。

1. **优先使用运行身份凭据。** Chains 先检查 TaskRun ServiceAccount 的 `secrets` 和 `imagePullSecrets`。CI 的 `default` ServiceAccount 由 onboarding 绑定项目 Harbor credential，因此 CI 签名使用项目凭据；该凭据必须能向镜像所在项目 push。
2. **没有匹配凭据时使用中央凭据。** `platform-repo/components/chains-registry-credential.yaml` 将 `chains-registry-credential` 挂载到 Chains controller。它的 Harbor robot 对所有被签名项目有 pull/push。promotion 的生产 Connector 通过 CSI workspace 挂载到 `shop-release`，但不会出现在 ServiceAccount Secret 中，所以 promotion 签名使用中央凭据。不要把同一 registry 的生产 push 凭据加到 `shop-release`，否则 Chains 会优先使用它。
3. **签名写入失败不一定让运行失败。** PipelineRun 可能仍为成功，只有 TaskRun 注解、Warning event 和 Chains 日志显示失败；因此晋级前必须运行本脚本。
4. **晋级附件。** 默认 promotion 只复制镜像；如需同时复制 CI 的 `.sig`/`.att`，在 `imageMappings` 中显式加入同一 digest 的附件，并保持镜像映射为第一项。`multiArch: all` 会保留镜像 index，但不会自动发现附件。

发布镜像必须用 promotion 自己的签名和 provenance 验证；签名通过不等于已经完成 ApprovalTask、GitOps 审核或生产 rollout。

## 可选：独立签名仓库

样例未启用。平台可以在 TektonConfig 的 `spec.chain.storage.oci.repository` 设置一个专用 Harbor 项目。此时：

- 中央 robot 需要对该项目有 push；Kyverno 和 cosign 都必须能读取它。
- 运行脚本前设置 `COSIGN_REPOSITORY=<repository>`，并让 `require-signed-images` 的 attestor 使用同一 repository。
- CI 和发布镜像 digest 相同，因此共享一个 `.sig`/`.att` 标签；promotion 的签名会覆盖 CI 签名。应在 promotion 前验证 CI，且不要再复制 `.sig`/`.att` 映射。

This is sample material, not part of the product.
