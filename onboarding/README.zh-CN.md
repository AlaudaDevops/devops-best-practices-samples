# 项目开通流水线

English version：[README.md](README.md)。

这是最佳实践系列中“平台配置与项目开通”文章的参考流水线。一次运行把已经合并的项目声明变成一个隔离项目：创建命名空间，在 GitLab、Harbor、Nexus、SonarQube 中创建租户，生成项目级 Connector，创建交付和晋级身份，播种项目 GitOps 仓库，并向平台仓库提交登记这些 Application 和边界的合并请求。

本目录是示例材料，不属于产品，也不在产品支持范围内。域名、名称和凭据均为占位符。除明确写出其他目录的地方外，路径都相对于本目录。

## 流水线做什么

平台项目必须先由管理员在 ACP 上创建。流水线从 `platform-connectors` 中的项目声明开始；第 1 步导出平台项目对象，后续步骤使用它。步骤 2–5 在命名空间创建后并行执行。

| 步骤 | PipelineTask | 作用 | 使用 |
| --- | --- | --- | --- |
| 1 | `validate-declaration` | 读取 `project-<project>` ConfigMap，检查字段、命名约定，并推导 Nexus 仓库和环境列表 | catalog `kubectl` 0.1 |
| 1 | `export-platform-project` | 导出平台项目（去掉 `status`、服务端元数据和 Argo CD/GitOps tracking 标记），写入 `onboarding-<project>-register` | catalog `kubectl` 0.1 |
| 1 | `create-namespaces` | 创建 `<project>`、每个 `<project>-<env>`、`<project>-cd`、`<project>-build`；设置 `restricted`/`baseline` Pod Security 标签和 `cpaas.io/project`；创建 delivery/release ServiceAccount | catalog `kubectl` 0.1 |
| 2 | `gitlab-tenant` | 创建 GitLab 组及 `apps`、`gitops` 子组，developer group token 和 `<project>-gitlab` Connector | `gitlab-connector-automatic-creation` |
| 2 | `gitlab-gitops-writer` | 创建独立 maintainer token 和仅供 CD/晋级使用的 `<project>-gitops-writer` Connector | 同上 |
| 3 | `harbor-tenant` | 创建 `<project>`、`<project>-prod` 私有项目，CI Connector 和默认 ServiceAccount 的拉取 Secret | `harbor-connector-automatic-creation` |
| 3 | `harbor-staging-readonly`、`harbor-release` | 创建测试只读 robot，以及可拉取测试并推送生产的 release robot；写入平台 Connector | 同上 |
| 4 | `nexus-tenant` | 创建声明的 Nexus 仓库、受限用户和 Connector | `nexus-connector-automatic-creation` |
| 5 | `sonarqube-tenant` | 创建 SonarQube 用户、`^<project>(:.*)?$` 权限模板、token 和 Connector | `sonarqube-connector-automatic-creation` |
| 6 | `seed-gitops-repo`、`create-pac-repository` | 从模板播种项目 GitOps 仓库，创建 `<project>-gitops` PaC Repository 和认证 Secret | catalog `gitlab-cli`/`kubectl` 0.1 |
| 7 | `register-project` | 启动 catalog `gitops-repo-update` 0.1，在平台仓库生成 `projects/<project>/` 并提交一个合并请求 | catalog `kubectl` 0.1、`gitops-repo-update` |

第 7 步使用独立 PipelineRun，因为 Tekton Pipeline 不能直接作为另一个 Pipeline 的 task。它将项目名、GitOps URL、集群名、Argo CD 命名空间以及导出的平台项目 ConfigMap 传给 catalog Pipeline。开通流水线不会直接修改 Argo CD；管理员合并第 7 步的合并请求后，`projects` Application 才会同步对象。

## 目录结构

```text
./
├── pipeline/                 # project-onboarding 和合并触发 dispatcher
├── run-template/             # 控制台入口；只填写 project
├── triggers/                 # 每个项目一个 ScheduledTrigger
├── rbac/                     # ServiceAccount、管理员和发布 Connector 权限
├── optional/                 # 启用 Connector approval 后才应用的 AccessPolicy
└── kustomization.yaml
```

## 前置条件

- Pipelines 4.15（Triggers、ScheduledTrigger、cluster resolver、hub catalog、PaC）、Connectors 1.14（四种 Connector Task 和 CSI Driver）、Argo CD（命名空间 `argocd`）均已安装。
- 平台仓库已经创建 `platform-connectors`，发布 `project-<name>` 声明，并存在 `gitlab-admin`、`harbor-admin`、`nexus-admin`、`sonarqube-admin` Connector。
- 四个 Connector automatic-creation Task 必须安装在 `platform-connectors`，它们不在 catalog 中：

  | Task | 文档 |
  | --- | --- |
  | `gitlab-connector-automatic-creation` | <https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-gitlab/how_to/using_gitlab_connector_automatic_creation_task.html> |
  | `harbor-connector-automatic-creation` | <https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-harbor/how_to/using_harbor_connector_automatic_creation_task.html> |
  | `nexus-connector-automatic-creation` | <https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-nexus/how_to/using_nexus_connector_automatic_creation_task.html> |
  | `sonarqube-connector-automatic-creation` | <https://docs.alauda.io/alauda-devops-connectors/1.14/connectors-sonarqube/how_to/using_sonarqube_connector_automatic_creation_task.html> |

- GitOps 模板已发布到独立仓库；平台项目（例如 `shop`）已创建；PaC webhook 注册控制器已配置集中凭据和 controller URL；Argo CD 已有能读取所有项目 GitOps 仓库的 `repo-creds`。
- Harbor 项目必须保持私有。准备启用 Connector 审批时，先备齐所有非审批 Connector 的 proxy 授权，再按顺序启用 `enable-connectors-approval`、应用 `optional/admin-connectors-access.yaml`，最后启用 proxy-permissions flag；开关与授权尚未齐备的窗口内暂停 onboarding。

安装 Task 后检查：

```bash
kubectl -n platform-connectors get tasks.tekton.dev \
  gitlab-connector-automatic-creation harbor-connector-automatic-creation \
  nexus-connector-automatic-creation sonarqube-connector-automatic-creation
```

安装流水线：

```bash
kustomize build . >/dev/null && echo "PASS render"
kubectl apply -k .
```

GitOps 场景应将本目录复制到平台仓库的 `onboarding/`，由 `argocd/apps/platform-onboarding.yaml` 管理。

## 项目声明

流水线只读取 `platform-connectors` 中 `project-<project>` ConfigMap 的 `<project>.yaml`。第 1 步会拒绝以下情况：名称与参数不一致、平台项目或环境为空、owners 不是裸组名、tools 不是四项 `gitlab/harbor/nexus/sonarqube`、命名空间推导不符合约定、GitLab 子组不是 `apps/gitops`、Harbor 项目不是 `<project>` 和 `<project>-prod`、Nexus 条目缺少 format/type、审批人不是 `group:<name>`，以及推导出的命名空间属于 `kube-*`、`argocd*`、`tekton-*`、`*-system`、`platform-*` 等保留名称。

项目名最多 32 个字符，环境名和组合后的 namespace 必须满足 Kubernetes DNS label 的 63 字符限制。已存在但没有 `cpaas.io/project=<project>` 的命名空间不会被接管；平台创建的、带 `cpaas.io/inner-namespace=<project>` 的同名 namespace 是唯一例外，会被流水线采用并补齐标签。

声明里的 `approvers` 只是经过评审的记录，流水线不会把它自动写入晋级 Pipeline 或 AccessPolicy；三处审批人必须人工保持一致。`imagePullFrom` 目前只输出警告，样例没有实现跨项目拉取授权。

## 运行方式

**控制台 Run Template。** 在 `run-template/triggertemplate.yaml` 中启动 `project-onboarding`，只填写 `project`，其他参数使用默认值。

**合并触发。** 平台仓库的 `.tekton/onboard-changed-projects.yaml` 监听 `main` 上改变 `projects/*.yaml` 的合并提交，为每个变更声明等待 Argo CD 发布 ConfigMap 后启动一次 onboarding。失败时可以在仍为 `main` HEAD 的合并提交上评论：

```text
/test onboard-changed-projects branch:main
```

**手动 PipelineRun。** 也可以使用 Run Template 等价的 `PipelineRun`，核心字段如下；管理员 Connector 的 CSI workspace 和 `token.expiration: 45m` 需要照英文 README 的完整示例配置：

```yaml
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
```

45 分钟的 token 有效期覆盖每个 onboarding Task 的 30 分钟超时；不设置时 CSI 默认只有 30 分钟。

**定时重跑。** 每个项目复制一个 `triggers/shop.yaml` 和 `rbac/release-connectors-shop.yaml`，在 kustomization 中登记。样例每三天 `02:00 UTC` 重跑：轮换工具凭据、对账 namespace/ServiceAccount/RoleBinding/PaC Repository，并在生成内容变化时向平台仓库提交合并请求。不要按 PipelineRun 的 `changed` result 判断是否有变化，应检查是否真的产生合并请求。

首次运行创建的 GitLab group token 有效期 30 天，重跑轮换后的 token 有效期 7 天；定时周期必须明显短于 7 天并监控失败。Harbor/Nexus 的有效期由平台策略决定，应单独轮换。

三种入口共用同一个项目锁。第一步原子创建 `onboarding-<project>-lock`；竞争运行在修改租户前失败；成功运行只删除自己 UID 持有的锁。失败、取消或清理中断可能留下锁：读取 ConfigMap 中的 `pipelineRun` 和 `pipelineRunUID`，确认父运行及独立创建的子运行都停止后，管理员才可以删除锁并重试。不要按时间自动抢锁。新增项目时同步添加发布 Connector RBAC 的锁删除和 Role/RoleBinding 读取权限。

## 开通后检查

第 7 步合并请求合并后，可执行：

```bash
kubectl get ns shop -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'   # restricted
kubectl get ns shop-build -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'   # baseline
kubectl -n shop get connectors
kubectl -n shop-cd get sa shop-delivery shop-release
kubectl -n argocd get application shop-test -o jsonpath='{.status.sync.status} {.status.health.status}'
```

重复运行应报告对象已存在且不改动配置，只有凭据按设计轮换。

## 安全边界和硬化

- `<project>-gitops-writer` Secret 位于 CD namespace；能在那里创建 Pod 的主体可能直接挂载它。生产环境应将 Connector 放在没有流水线运行的管理 namespace，并通过跨 namespace 的 `get`/`connectors/proxy` 授权挂载。
- onboarding ServiceAccount 虽然没有直接读取管理员 Secret 的授权，但能在 `platform-connectors` 创建 PipelineRun，运行 Pod 可以挂载该 namespace 的 Secret；项目发布 Connector 的具名 Secret 另有直接读写授权。应限制该 namespace 的 Pod/PipelineRun 创建者，并考虑 Kyverno 只允许它创建指定的两种 PipelineRun。
- `approvers` 不会和晋级 Pipeline、AccessPolicy 自动比对；生产环境应增加一致性检查。
- 开通不会配置 GitOps 仓库的分支保护和 CODEOWNERS；生产路径必须按 [GitOps 模板说明](../gitops-template/README.zh-CN.md)另行保护。
- 第 7 步会等待子 PipelineRun 最多 20 分钟并持续占用 CPU；单节点集群要预留两个 Pod 的资源，并在取消父运行后检查无 ownerReference 的子运行。
- 项目能否部署哪些对象由平台的 Kyverno `argocd-project-namespace-boundary` 策略限制；AppProject patch 只写 `sourceRepos` 和 `destinations`。

## 目标环境必须核对的契约

1. 跨 namespace Connector 挂载同时需要 `get` 和（启用 approval 后）`connectors/proxy` `*`。
2. 项目同名 namespace 应同时具有平台创建的 `cpaas.io/inner-namespace` 和流水线补上的 `cpaas.io/project` 标签。
3. 四个 admin Connector、CI 的项目 Connector、CD 的 GitOps writer、晋级的两个 registry Connector 都要按实际 ServiceAccount 验证有效权限。
4. 确认 catalog `kubectl` 的 array result、result path、`jq`/版本化 `yq`，以及 `gitlab-cli` 的 `glab`/`git` 工具版本。
5. 确认 `<platform-project-kind>`、Argo CD cluster name、GitLab URL、仓库模板中的项目字面量和三次 Harbor Task 的权限。
6. 确认 `create-pac-repository` 读取的源 Secret key、Argo CD `repo-creds`、cluster resolver 和 ScheduledTrigger RBAC。
7. 检查 `projects` Application 的 server-side apply 与预期 OutOfSync 状态，不能把这视为错误。
8. `onboarding-rolebinding-scope` 默认从 Audit 开始；切换 Enforce 前确认 namespace patch 不能被用来伪造项目标签，且其他身份写入的 RoleBinding 仍由独立控制保护。

## 替换项

| 占位符 | 位置 | 含义 |
| --- | --- | --- |
| `platform-connectors` | 全部文件 | 管理 namespace |
| `gitlab-admin`、`harbor-admin`、`nexus-admin`、`sonarqube-admin` | RBAC、Run Template、step 7 | 管理 Connector 名称 |
| `argocd`、`<cluster-name>` | Pipeline 参数 | Argo CD namespace 和 GitOps 注册的集群名，global 集群通常为 `global`，不是 `in-cluster` |
| `<platform-project-kind>`、`<platform-project-group>`、`<platform-project-resource>` | Pipeline 参数、RBAC | 平台项目 API |
| `https://git.example.com`、`https://nexus.example.com`、`registry.example.com` | Pipeline 参数 | 工具地址和 Harbor 主机 |
| `https://git.example.com/platform/gitops-template.git` | `gitops-template-url` | 项目模板仓库 |
| `https://git.example.com/platform/platform-config.git` | `platform-repo-url` | 平台仓库（第 7 步 MR 目标） |
| `registry.example.com/catalog/<tool>:<tag>` | tool image 参数 | `gitops-repo-update` 使用的工具镜像 |
| `config`、`30` | `gitops-repo-name`、`token-duration` | 项目 GitOps 仓库名和初次 token 有效天数 |
| `shop`、`samples.example.com/project`、`project-onboarding@example.com` | triggers、RBAC、Pipeline | 项目名、自有 label 域和提交作者 |

This is sample material, not part of the product.
