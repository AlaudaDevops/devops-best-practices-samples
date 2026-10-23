# 平台仓库骨架

English version：[README.md](README.md)。

这是最佳实践系列中“用 Argo CD 与 Tekton 管理平台配置并自动开通隔离项目”的平台 GitOps 仓库样例。复制本目录作为平台仓库根目录；除指向样例集其他目录的引用外，路径都相对于本目录。

本目录是示例材料，不属于产品，也不在产品支持范围内。

## 各目录职责

```text
./
├── argocd/apps/           # 根 Application、AppProject 和各层 Application
├── components/            # TektonConfig 片段：Pruner、Results、Chains 凭据
├── policies/              # Kyverno 平台基线和可选 resolver 约束
├── credentials/           # 管理 Connector、SealedSecret、平台仓库 PaC Repository
├── projects/              # 每个项目的声明及开通后登记对象
├── templates/             # onboarding 使用的 Application、边界和 RoleBinding 模板
├── onboarding/            # 从样例集复制的第五层 Application
└── .tekton/               # 合并校验和项目声明变更 dispatcher
```

| 目录 | 层 | Argo CD Application | 目标 |
| --- | --- | --- | --- |
| `argocd/apps/` | — | `platform-root` | Argo CD 集群的 `argocd` |
| `components/` | component | `platform-components`（`prune: false`） | 集群级 |
| `policies/` | policy | `platform-policies` | 集群级 |
| `credentials/` | credential | `platform-credentials`（`selfHeal: false`） | `platform-connectors` |
| `projects/` | project | `projects` | 声明在 `platform-connectors`，项目对象还会写入 `argocd`、项目 namespace 和平台项目 |
| `templates/` | — | 无；由 onboarding 读取 | — |
| `onboarding/` | — | `platform-onboarding` | `platform-connectors`，ClusterRole/Binding 为集群级 |

一层一个 Application，因此一层失败不会阻止其他层。设计边界如下：

- `platform-connectors` 是唯一管理 namespace，保存管理员 Connector、SealedSecret、声明、平台仓库 PaC Repository 和 onboarding 流水线；项目成员不应访问它。
- 项目应用清单放在各自 GitOps 仓库；平台仓库只保存每个项目的 Argo CD Application、AppProject patch、负责人 RoleBinding、Connector mount 授权和导出的平台项目。
- 只提交 SealedSecret，不提交明文 Secret；加密流程见[Sealed Secrets 中文说明](credentials/SEALED-SECRETS.zh-CN.md)。
- namespace 由管理员或 onboarding 创建，不由 Argo CD 创建；每个 namespace 只有一个创建者。
- 策略先用 `Audit` 观察 PolicyReport，再切换 `Enforce`。`argocd-project-namespace-boundary.yaml` 是项目边界，默认直接 `Enforce`。
- `pipelinerun-source-baseline.yaml` 是可选约束，只允许 `cluster`、`hub`、`git` resolver 并拒绝 inline `pipelineSpec`；基线还包括裸 TaskRun、验签、onboarding RoleBinding scope 和 reports 读授权策略。
- Kyverno webhook 的 failure policy 为 `Fail` 时，Kyverno 不可用会拒绝匹配写入；平台要准备高可用和恢复步骤。

## 前置条件

- Alauda GitOps 4.4/Argo CD 已安装，平台仓库以只读凭据注册；Argo CD 需要使用 GitOps 注册的 `<cluster-name>`，global 集群通常为 `global`，不要使用默认范围只有 `argocd` namespace 的 `in-cluster`。
- Kyverno、Sealed Secrets、Pipelines 4.15（PaC、Chains、Approval Gate）、Connectors 1.14 已安装，并且相关 CRD 先于第一次同步存在。
- 管理员预先创建 `platform-connectors`、四个 Connector automatic-creation Task，以及 Chains namespace `tekton-pipelines` 中的 `chains-registry-credential`。
- 每个自建 GitLab PaC Repository 都设置 `spec.git_provider.url: https://git.example.com`，否则 PaC 可能携带 Repository token 请求 `gitlab.com`。
- PaC webhook 注册控制器已有集中凭据和 controller URL；如果不用控制器，需要手工为平台仓库和项目 GitOps 仓库设置 push、tag push、MR、comment 事件。
- Argo CD 有能读取所有项目 GitOps 仓库的 `repo-creds`；Harbor 项目保持私有；Kyverno 验签发布镜像及签名附件的 pull 凭据已按加密流程配置。

查看 GitOps 注册的集群名：

```bash
kubectl -n argocd get secret \
  -l argocd.argoproj.io/secret-type=cluster,cpaas.io/managed-by=acp \
  -o go-template='{{range .items}}{{index .data "name" | base64decode}}{{"\n"}}{{end}}'
```

## 引导

1. 替换所有占位符，并将样例集的 `onboarding/` 复制到平台仓库。
2. 渲染每一层：

   ```bash
   for d in argocd/apps components policies credentials projects onboarding; do
     kustomize build "$d" >/dev/null && echo "PASS $d" || echo "FAIL $d"
   done
   ```

3. 只执行一次 `kubectl apply -k argocd/apps/` 创建根 Application 和平台 AppProject；之后所有变化走合并请求。
4. 引导前已在 `projects/` 的声明（样例的 `shop`、`payments`）不会被合并触发器补跑，因为当时 PaC Repository 尚不存在；分别从 `onboarding/run-template/` 手动启动一次。

## 合并前校验

`.tekton/validate.yaml` 在每个合并请求中渲染 `paths` 参数列出的目录。Repository 使用 `pipelinerun_provenance: default_branch`，因此运行的 `.tekton/` 来自 `main`，提 MR 的人不能在审核前改变校验定义。render Task 的镜像必须替换为目标 registry 中带 `sh`、`kubectl` 的工具镜像。需要重跑时，在合并请求中评论 `/test validate branch:<branch>`，将 `<branch>` 替换为源分支。

当前 PipelineRun 通过 hub resolver 内联组合 `git-clone` 和 `run-script`。如果把 resolver 约束扩展到 `platform-connectors`，需将两个 Task 发布为 catalog Pipeline，并改用 hub `pipelineRef`。新增 Application 目录时同步添加到 `paths`。

## 合并触发开通

`.tekton/onboard-changed-projects.yaml` 监听 `main` 上 `projects/<project>.yaml` 的变更，计算提交与第一个 parent 的差异。每个项目都要等到 Argo CD 发布内容完全匹配的 `project-<name>` ConfigMap，并能读取 `project-onboarding-release-connectors-<name>` Role 和 RoleBinding，才会启动 `onboard-<name>-*`。第 7 步生成的 `projects/<project>/` 文件合并后，`projects` Application 才会应用它们。

路径触发在 Pipelines 4.15 中属于 Technology Preview。平台仓库应使用 merge commit 或 squash 合并；多提交 fast-forward 只比较最后一个提交，可能漏掉更早提交中的声明。新增项目需要同一个 MR 登记声明 generator、发布 Connector RBAC、ScheduledTrigger、Kustomize 资源和验签仓库，详见[平台项目说明](projects/platform-projects.zh-CN.md)。

重复运行没有变化的声明不会产生新的合并请求；是否有变化应检查子运行的 push 和 MR 步骤，而不是只看 `changed` result。

## onboarding 写回的文件

| 文件 | 来源 | 作用 |
| --- | --- | --- |
| `platform-project.yaml` | onboarding 导出的平台项目 | 去掉 status、服务端元数据和 tracking 标记，可在新环境初始化 |
| `appproject-patch.yaml` | `templates/appproject-patch.yaml` | 每个环境的 source repo 和 destination |
| `application-<env>.yaml` | `templates/application.yaml` | 每个环境一个 Argo CD Application |
| `rolebinding-owners.yaml` | `templates/rolebinding-owners.yaml` | 项目 owners 的 `admin` 权限 |
| `rolebinding-self-healing-probe.yaml` | `templates/rolebinding-self-healing-probe.yaml` | 无 subject、不向任何人授权的专用自愈验收对象 |
| `connector-mount-ci.yaml` | `templates/connector-mount-ci.yaml` | build namespace 的 CI Connector 读取和 proxy 权限 |
| `connector-mount-delivery.yaml` | `templates/connector-mount-delivery.yaml` | CD namespace 的 GitOps writer 权限 |
| `kustomization.yaml` | `render.sh` | 列出以上文件并加入 `projects/kustomization.yaml` |

## 新集群恢复

恢复顺序：

1. 安装 Kyverno、Sealed Secrets、Pipelines 和 Connectors。
2. 恢复旧 Sealed Secrets 密钥，或为 `credentials/` 中每个文件重新生成 ciphertext。
3. 恢复 Chains `signing-secrets`；若换新 key，同一提交必须更新 `require-signed-images.yaml` 的公钥，并创建 `chains-registry-credential`。
4. 创建 `platform-connectors` 和四个 Connector Task。
5. 配置 Argo CD 的平台仓库只读凭据、`repo-creds` 和 PaC webhook 凭据。

然后执行 `kubectl apply -k argocd/apps/`，再逐个运行 `projects/` 中的 onboarding。首次同步时，项目 namespace 尚未存在会使 `projects` Application 的 Role/RoleBinding 暂时失败；声明和平台项目仍会同步，onboarding 创建 namespace 后依靠 retry 收敛。

Git 恢复不包含外部工具数据库、registry 镜像和历史身份提供者成员。离线备份必须同时保留镜像 manifest digest 以及 `sha256-<digest>.sig`、`.att` 附件，并用恢复后的公钥验证。

## 运维和安全边界

- 平台仓库的 PaC 校验运行在 `platform-connectors`，可能挂载管理员 Secret；更强的做法是在没有管理员 Secret 的独立 namespace 注册 Repository，并只允许 dispatcher 创建指定 PipelineRun。
- `projects` Application 使用平台 AppProject；onboarding 合并请求新增的 ClusterRole、ClusterRoleBinding、RoleBinding、AccessPolicy 必须人工审阅。更严格时为 `projects` 创建独立 AppProject，仅允许 Application、AppProject、ConfigMap、Role、RoleBinding 和平台项目。生成的 Connector mount 授权也包含 Role，不能在收紧白名单时遗漏。
- 样例没有部署制品晋级 Kyverno 规则 1–3（模板变更保护规则 4 也未部署）；生产项目应按产品文档补齐。
- Chains 中央 registry credential 对所有被签名项目有 push 权限，必须只允许平台管理员读取/创建 Pod，并定期轮换 robot token。
- 生产 namespace 应限制只接受 `<project>-prod/*@sha256:*`；PolicyException 的创建权限和 Kyverno exception namespace 也要单独收紧。
- `argocd-project-namespace-boundary` 在项目 namespace 拒绝项目 GitOps Application 创建/更新/删除 Role、RoleBinding、ResourceQuota、LimitRange、NetworkPolicy、PolicyException 和 AccessPolicy。它依赖正确的 Argo CD 写入身份、tracking annotation、每个目标集群的 Kyverno 和 webhook；切换策略前必须用真实身份做正反测试。
- 仅删除项目声明不会自动下线项目；同时需要移除对应 `configMapGenerator` 条目，否则声明层无法渲染。删除注册目录及其 resources 条目，或回滚注册提交，才可能让 `projects` Application prune 平台项目及同名 namespace。下线项目时还要单独清理工具租户、AppProject 和其他 namespace。

## 替换项

| 占位符 | 位置 | 含义 |
| --- | --- | --- |
| `https://git.example.com/platform/platform-config.git` | `argocd/apps/`、credentials | 平台仓库 URL（Argo CD 保留 `.git`） |
| `https://git.example.com` | PaC Repository | GitLab API 地址 |
| `<cluster-name>` | Application、模板 | Alauda GitOps 注册的 ACP 集群名 |
| `argocd`、`platform-connectors` | Application、策略、凭据 | Argo CD 和管理 namespace |
| `<platform-project-group>`、`<platform-project-kind>` | `appproject-platform.yaml` | 平台项目 API |
| 工具 URL、`<encrypted>` | Connector、SealedSecret | 目标环境服务地址和 kubeseal 输出 |
| release 仓库和 `<cosign-public-key-pem>` | `require-signed-images.yaml` | 验签范围和 Chains 公钥 |
| `registry.example.com/catalog/kubectl:<tag>` | `.tekton/validate.yaml` | 合并前 render 工具镜像 |
| `onboard-changed-projects` | `.tekton/onboard-changed-projects.yaml` | 与 onboarding 目录中的 Pipeline 名称保持一致 |
| `shop`、owners、release-managers、保留 namespace | `projects/`、`templates/`、policies | 项目、负责人、审批组和平台边界 |

This is sample material, not part of the product.
