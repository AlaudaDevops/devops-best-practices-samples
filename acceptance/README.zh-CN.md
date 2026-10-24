# 验收脚本

English version：[README.md](README.md)。

本目录对应知识库文章[《从提交到上线》](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/From_Commit_to_Production_on_ACP.md)
和[《用 Argo CD 与 Tekton 管理平台配置并自动开通隔离项目》](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Managing_Platform_Configuration_and_Onboarding_Isolated_Projects_with_Argo_CD_and_Tekton_on_ACP.md)。脚本读取目标集群中的真实 GitLab、Harbor 和 Kyverno 状态，帮助核对文章中的交付链路和项目边界。

脚本只覆盖表中列出的自动检查。CI 来源、扫描证据、晋级结果之间的关联、GitOps 合并审核以及 dispatcher 的子运行完成情况，仍需按英文 README 和文章人工核对。

> **看到 FAIL 时先调查原因。** 两个脚本会创建短生命周期探针并访问真实工具，执行前必须替换环境变量和占位符。`onboarding-validation` 还要求先为被播种的 `.tekton/validate.yaml` 设置可用工具镜像。

| 脚本 | 检查内容 |
| --- | --- |
| `01-commit-to-production.sh` | 测试环境运行 CI 产出的 digest；发布 tag 与该 digest 一致；生产 Application 为 `Synced`、`Healthy`；生产 Deployment 使用发布仓库中 tag 对应的精确 digest 且 rollout 完成；签名阳性镜像能通过 `require-signed-images`，未签名镜像在 `Enforce` 下被拒绝或在 `Audit` 下产生报告；`PROMOTION_RUN` 所属的 ApprovalTask 有审批记录；发布镜像的签名和 provenance 可用。 |
| `02-platform-and-onboarding.sh` | 工作负载命名空间为 `restricted`、构建命名空间为 `baseline`；四个项目 Connector 就绪；测试 Application 已同步；`/test validate` 启动并成功完成正确的 PaC 运行；跨项目拉取因授权失败而不是因镜像不存在；被删除的 RoleBinding 由 GitOps 以新 UID 恢复；再次开通成功并按设计轮换 Harbor robot token。 |

每项检查只输出一行 `PASS <label>` 或 `FAIL <label>`，脚本末尾输出 `== result: X pass / Y fail ==`，有失败时以非零状态退出。`delivery-signature`、`onboarding-application` 等 label 是脚本内部稳定的检查 ID，不是英文文章的章节编号。

如果平台安装了 `policies/no-bare-taskrun.yaml`，要注意它是全集群生效的 `ClusterPolicy`：修改 `failureAction` 会影响所有命名空间，Argo CD 自愈还可能把手工修改恢复。该检查只能在专用验收集群执行。通过平台仓库的合并请求修改策略并等待 Argo CD 同步，不要直接编辑 live 对象，也不要在项目命名空间复制一份策略。`Audit` 模式下，用项目身份创建最小裸 TaskRun，确认请求放行并产生 PolicyReport；再通过平台仓库合并请求切到 `Enforce`，重新发起真实请求并确认准入拒绝；检查结束后仍通过合并请求恢复 `Audit`。两次观察后删除探针。server-side dry run 不会创建 Audit 检查所需的 PolicyReport。

## 运行

两个脚本顶部列出全部环境变量。`PROJECT` 必须显式设置为独立的验收项目，脚本不会默认使用生产租户；第二个脚本还必须设置不同的 `OTHER_PROJECT`。先完成首次晋级、生产 GitOps 合并和 rollout，再运行交付脚本。

```bash
export KUBE_CONTEXT=<context>          # 可选；默认使用当前 kubectl context
export PROJECT=<isolated-acceptance-project>
BUILD_DIGEST=sha256:<digest> RELEASE_LABEL=release-001 PROMOTION_RUN=<pipelinerun> \
UNSIGNED_IMAGE=registry.example.com/"$PROJECT"-prod/acceptance-unsigned@sha256:<digest> \
COSIGN_PUB=./cosign.pub ./01-commit-to-production.sh

# ALLOW_MUTATING=true 会让自愈检查删除专用的 <project>-self-healing-probe，等待 GitOps 重建；
# 不设置时该项为 FAIL skipped，整次运行不会全通过。
OTHER_PROJECT=<second-isolated-acceptance-project> \
PROJECT_IMAGE=registry.example.com/"$PROJECT"/hello@sha256:<digest> \
TEST_COMMENT_TIME=<RFC 3339 UTC，发送评论前立即记录> \
ONBOARDING_RERUN=<pipelinerun> ALLOW_MUTATING=true ./02-platform-and-onboarding.sh
```

在没有透明日志的 air-gapped 环境中给第一个命令增加 `IGNORE_TLOG=true`。如果签名保存在独立仓库，再设置 `COSIGN_REPOSITORY=<signature repository>`；否则 `delivery-signature` 会报找不到签名。

跨项目拉取每次只验证一个方向。交换 `PROJECT`、`OTHER_PROJECT` 和 `PROJECT_IMAGE`，再用对应的 onboarding 和 validation 运行重做另一方向。两个项目都必须是可丢弃的验收项目。自愈检查前，先合并并同步包含专用 `<project>-self-healing-probe` RoleBinding 的登记 MR；已有项目需要通过登记更新补入该对象。

## 结果判定要点

- 交付脚本先用 cosign 验证签名和 provenance，再要求签名阳性 Pod 的 PolicyReport 包含 `verified image signatures for <image>` 或 `verified from cache`。两种结果都必须属于本次 Pod 的精确 UID 和验签策略，且查回的 Pod 仍然只包含独立验证过的同一镜像。泛化的 `pass`、旧报告、认证失败都不能算验签成功。
- 未签名检查在 Kyverno `Audit` 模式下等待属于本次探针 UID 的报告；报告可能先为 `pass (image verified)`，约 40 秒后才变为 `fail (no signatures found)`，脚本最多等待 `WAIT_SECONDS`（默认 120 秒）。在 `Enforce` 模式应看到准入拒绝。
- 正向跨项目拉取必须先证明镜像确实存在；两个私有项目的“镜像不存在”和“无权拉取”事件可能相同。探针使用 `imagePullPolicy: Always`，因此验证的是 registry 授权边界。默认 kubelet 可能直接使用节点已有镜像，脚本不覆盖 `AlwaysPullImages` 或其他重新校验凭据的集群设置。
- Harbor 私有项目的客户端登录（`skopeo login`、`cosign login` 或 `REGISTRY_AUTH_FILE`）只供脚本使用，不会成为 Kyverno 的凭据。切换 `require-signed-images` 到 `Enforce` 前，必须另行给 Kyverno 配置读取发布镜像及签名附件的凭据。

## 前置输入

- `BUILD_DIGEST`：`main` push 触发的 CI PipelineRun 中 `build-image` TaskRun 的 `IMAGE_DIGEST`；合并请求只写入 `shop/hello-mr`，不能拿来晋级。样例需要手动用 `hello-cd-test` Run Template 部署测试环境。
- `RELEASE_LABEL`：晋级运行写入发布仓库的 tag。脚本将它解析出的 digest 与生产 Deployment 比对。
- `PROMOTION_RUN`：创建该 tag 的 `shop-cd` PipelineRun 名称。ApprovalTask 必须仍存在且归属于该运行，验收完成前不要清理它。
- `UNSIGNED_IMAGE`：样例默认只有签名的晋级写入路径，因此需要平台管理员用临时 Harbor 凭据推送一个一次性未签名镜像，验收后删除 tag。
- `PROJECT_IMAGE`：CI 已推送到构建项目的镜像；onboarding 本身不推送镜像。
- GitOps 模板中的 validation 工具镜像：必须带 `sh` 和 `kubectl`，且在首次播种前设置。启用 resolver 约束时，还要把两个 Task 发布成 catalog Pipeline。

## 脚本会修改什么

- 交付探针使用 `acceptance-delivery-*` 唯一名称，平台探针使用 `acceptance-onboarding-*`，退出时只清理本次成功创建的对象。
- `onboarding-self-healing` 使用 `templates/rolebinding-self-healing-probe.yaml` 渲染的专用 `<project>-self-healing-probe` RoleBinding，不删除项目负责人授权。该对象没有 subjects，删除它不会移除任何人的权限。脚本要求 `samples.example.com/acceptance-probe: self-healing` 标签且没有 subjects；对象缺失或改用真正的权限绑定时，会在删除前失败。保存原对象和 UID 后，脚本等待 Argo CD 以新 UID 重建；超时会尝试从副本恢复，并保持 FAIL。只有设置 `ALLOW_MUTATING=true` 才会执行删除。
- `/test validate branch:<source-branch>` 评论和 onboarding 重跑仍需人工先触发，再把时间和 PipelineRun 名称传给脚本。轮换检查按 `tekton.dev/pipelineTask` 读取三个 Harbor Task 的 `robot-token-rotated` 结果，预期为 `true`。

脚本输出只能说明当前集群的这些检查结果，不能替代人工审核，也不能把离线 fixture、Kustomize 渲染或 server-side dry-run 记录成集群验收通过。

This is sample material, not part of the product.
