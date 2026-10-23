# 样例应用及其交付链路

English version：[README.md](README.md)。

这是一个最小 Go HTTP 服务（`/` 和 `/healthz`）及其完整交付链路，配套“从提交到上线”文章：使用平台 catalog 做 CI，以 digest 贯穿测试和生产，并在晋级前执行审批。除明确指向样例集其他目录的引用外，路径都相对于本目录，可复制为应用仓库根目录。

本目录是示例材料，不属于产品，也不在产品支持范围内；名称、域名和凭据都是占位符。

## 目录结构

```text
./
├── main.go、main_test.go、go.mod  # 无第三方依赖的服务
├── Containerfile                   # 测试、静态编译、非 root 运行
├── .tekton/
│   ├── ci.yaml                     # main push：构建、扫描、推送 shop/hello
│   └── ci-merge-request.yaml       # MR：构建、扫描、推送临时 shop/hello-mr
├── cd/
│   ├── run-template-test.yaml      # D1 写入测试 overlay，直接提交
│   └── run-template-prod.yaml      # D2 写入生产 overlay，创建 MR
├── promotion/
│   ├── pipeline.yaml               # digest 校验 → 审批 → 制品复制
│   ├── run-template.yaml           # 固定仓库、Connector、身份和超时
│   ├── access-policy.yaml          # 可选：审批后才释放生产 Connector
│   ├── optional/console-approver.yaml # 可选：控制台审批者只读角色
│   └── standing-access.yaml        # release 身份对两个晋级 Connector 的基础权限
└── chains/
    ├── verify.sh                   # 按 digest 验证签名和 provenance
    └── README.md
```

## 链路

```text
merge request
  -> ci-merge-request.yaml  shop/hello-mr:<commit>（临时仓库，不参与 CD/晋级）
push to main（合并后）
  -> ci.yaml                shop/hello:<commit>，得到 digest D1
  -> hello-cd-test           测试 overlay 写 shop/hello@D1 -> Argo CD -> shop-test
  -> hello-promote-run      校验 D1 -> release-managers 审批 -> 复制到 shop-prod，得到 D2
  -> hello-cd-prod           生产 overlay 只写 D2，创建 MR -> Argo CD -> shop-prod
```

三个 Run Template 在样例中手动启动：测试和晋级输入 D1，生产输入 D2。可渲染模板后用 `kubectl create` 创建 PipelineRun；控制台启动时按模板顶部的表单填写参数（两个 CD 模板关闭 Integrations，晋级模板没有 Integration）。文章推荐的 registry event 触发尚未在样例实现。Skopeo 按 digest 复制时 D2 应等于 D1；不一致必须先调查。

合并请求 CI 只推送 `shop/hello-mr`。`ci.yaml` 的 pre-build guard 只接受真实 `push` 事件和 `main` 分支；命名 `/test ci` 会绕过 PaC 事件注解，因此即使在 main 评论也会在 build 前拒绝。评论触发请使用 `ci-merge-request`。共享 Harbor 凭据可能同时写两个仓库，更强隔离需要独立临时项目和受限凭据。

digest 是阶段之间唯一传递的值，tag 只便于人阅读：

| 值 | 读取位置 |
| --- | --- |
| D1 | CI PipelineRun 的 `build-image` TaskRun 结果 `IMAGE_DIGEST` |
| D2 | 晋级 PipelineRun 结果 `promoted-digest` |

```bash
kubectl -n shop-build get taskrun \
  -l tekton.dev/pipelineRun=<ci-run>,tekton.dev/pipelineTask=build-image \
  -o jsonpath='{.items[0].status.results[?(@.name=="IMAGE_DIGEST")].value}'
kubectl -n shop-cd get pipelinerun <promote-run> \
  -o jsonpath='{.status.results[?(@.name=="promoted-digest")].value}'
```

## 使用的 catalog 资源

下表中的 catalog Pipeline 和 Task 通过 `resolver: hub` 和显式版本引用。项目内的 `hello-promote` Pipeline 使用 cluster resolver；其中的审批步骤按 kind 引用已安装的 `ApprovalTask` Custom Task。部署完全由 GitOps 完成，不使用教程中的 `workload-apply`：

| 类型 | 名称 | 版本 | 用途 |
| --- | --- | --- | --- |
| Pipeline | `python-image-build-scan-deploy` | 0.3 | `ci.yaml` 执行 pre-build shell guard，`ci-merge-request.yaml` 跳过 pre-build；两者均将 SonarQube 和部署输入留空以跳过这两步 |
| Pipeline | `gitops-repo-update` | 0.1 | `cd/` |
| Task | `run-script` | 0.1 | 晋级的 digest 校验 |
| Task | `skopeo-copy` | 0.1 | 晋级的 `imageMappings` |
| Custom Task | `ApprovalTask` | — | Manual Approval Gate |

catalog 暂无 Go image Pipeline，因此样例借用 Python Pipeline 的 clone、buildah 构建和 Trivy 扫描部分；Go 编译和单元测试在多阶段 `Containerfile` 中执行。若目标 catalog 有 Go Pipeline，应同步替换两个 `.tekton/` 文件并按其结果读取 digest。

扫描镜像运行时需要 Trivy DB。两个 CI 文件指向 `registry.example.com/mirror/trivy-db:2`，离线环境必须替换为内部镜像。catalog 版本内容是否可变要向 catalog 管理员确认，不能仅把版本号当作不可变内容。

## 使用 SonarQube 和 Nexus Connector

开通会在 `shop` 写入 `shop-sonarqube` 和 `shop-nexus`，但默认 Go CI 不挂载它们。要启用 SonarQube，把 `sonarURL`、`sonarProjectKey` 和 `sonar-credentials` workspace 加入 CI；项目 key 必须符合 onboarding 授予的 `^shop(:.*)?$`。Connector mount 需要 CI ServiceAccount 对 Connector 有 `get`，启用 approval 后还需要 `connectors/proxy` `*`。

Maven、npm、pip 构建以同样方式挂载 `shop-nexus`，并把同一个 Connector 绑定到 `ca-bundle` workspace。npm 必须检查 `.npmrc` 存在，否则会退回公共 registry。样例没有实际的 Nexus 构建。

## 应用仓库和 PaC Repository

把本目录推送为 `shop/apps/hello`（`https://git.example.com/shop/apps/hello.git`）。开发者成员关系由管理员加入 GitLab `shop` 组；onboarding 只创建项目 GitOps Repository，不会创建应用 PaC Repository。应用 PaC Repository 必须在 `shop-build`，因为 buildah 不能在 `restricted` namespace 中运行：

```yaml
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: hello
  namespace: shop-build
spec:
  url: https://git.example.com/shop/apps/hello
  git_provider:
    type: gitlab
    url: https://git.example.com
    secret:
      name: hello-pac-auth
    webhook_secret:
      name: hello-pac-auth
  settings:
    pipelinerun_provenance: "default_branch"
```

`hello-pac-auth` 只在集群里创建，包含 `provider.token`（GitLab `api`、`read_repository`）和随机 `webhook.secret`，不能提交到 Git。自建 GitLab 必须填写 `git_provider.url`，否则 PaC 可能把状态和评论 token 发往 `https://gitlab.com`。受保护 main 上，GitLab 还要求 token 的角色足以写 commit status；实际应使用受控 writer 并验证 403/成功路径。`api` scope 也允许通过 GitLab API 修改未保护分支；缺少 `write_repository` 只表示不能用 HTTPS Git push，不等于只读。必须先配置并验证 main 保护，才能把它当作评审边界。

CI mount 需要 `shop-harbor` 的 `get`，启用 approval 后还需要 proxy 权限；CD mount 需要 `shop-gitops-writer`。所有 registry mount 都绑定 Connector proxy CA。Argo CD 的 `repo-creds`、PaC webhook 和 GitLab 组成员是平台前置条件。

## 谁执行什么

应用开发者维护 CD 和 promotion 文件，但样例只在 `shop` 授予项目 owners 写权限；平台管理员通常执行以下动作：

| 对象/动作 | namespace | 执行者 | 最小权限 |
| --- | --- | --- | --- |
| 应用 PaC `Repository` 和 Secret | `shop-build` | 平台管理员或被额外授权的 owners | 创建/更新 Repository 和 Secret |
| 读取 D1 | `shop-build` | 平台管理员或被额外授权的 owners | `view` |
| 应用 CD、promotion Pipeline/Template | `shop-cd` | 平台管理员或被额外授权的 owners | 创建/更新对应 Tekton 对象 |
| 启动 Run Template、读取 D2 | `shop-cd` | 平台管理员或被额外授权的 owners | 创建/读取 PipelineRun |
| 审批晋级 | `shop-cd` | `release-managers` 成员 | patch 自己的 ApprovalTask 输入；实际版本必须验证不能越权修改其他审批项 |
| `standing-access.yaml`、console approver、AccessPolicy | 管理 namespace/集群级 | 平台管理员 | — |
| Chains registry credential | `tekton-pipelines` | 平台管理员 | Secret 通过 kubectl 创建，项目不需要签名 Secret |

不要给项目 owners 在 `shop-cd` 授予 `edit`：它包含创建 Pod 的权限，Pod 可以直接挂载 `shop-gitops-writer` Secret，并绕过 Connector approval。

组审批需要在同一个 JSON patch 中设置该组的 `input: approve`，并把实际审批人加入该项的 `users`。需要多票时，后续成员向 `users/-` 追加自己的单个对象，不能覆盖前一位；每位组成员计一票。具体 patch 形状见[英文权限表](README.md#who-applies-what)。样例不直接授予 kubectl 审批角色，控制台审批还需要可选的 ACP 只读角色。必须用两个真实用户验证本人允许、越权修改他人被拒，不能仅看 `status.approversResponse` 就认定身份已经可靠绑定。

## 运维和硬化

- GitOps writer 位于 CD namespace；能创建 Pod 或 PipelineRun 的主体可能直接取得生产写权限。生产环境应把 writer 放到没有流水线运行的管理 namespace，并通过跨 namespace Connector mount 授权。
- 样例没有自动部署晋级护栏规则；生产环境按产品文档部署 `promotion-runs-use-a-template`、`no-taskrun-outside-a-template`、`no-pod-outside-a-template`，并限制模板修改者。
- Chains 中央凭据对所有签名项目有 push 权限，只允许平台管理员读取或在 `tekton-pipelines` 创建 Pod，并按策略轮换。
- 审批只有在管理员启用 `enable-connectors-approval`、应用匹配的生产 AccessPolicy，再启用 `enable-connector-proxy-permissions` 后，才能限制生产 Connector 挂载；按 `promotion/access-policy.yaml` 中的顺序配置并验收。默认两个开关均关闭时，单独的 ApprovalTask 不会拦截挂载。审批前不得给 release 身份直接的生产 Connector proxy 权限。
- `approvers.prod` 只是项目声明中的记录；实际生效的审批名单分别位于 `promotion/pipeline.yaml` 和 `promotion/access-policy.yaml`，样例不会自动复制或比较它们。三处必须在同一评审变更中保持一致。
- 生产 GitOps 路径必须使用受控 writer 和独立的保护规则；代码平台支持时，再要求 Code Owner 审批。也可以使用独立保护的生产分支或仓库。同一个 Maintainer token 能修改保护规则的事实不能被分支保护掩盖。
- `promotion/validate-digest` 检查输入镜像、tag、签名附件的映射；只允许同一 digest 的显式 `.sig`/`.att` 映射，其他仓库、plain tag 或第二个 digest 都会在审批前拒绝。
- 晋级的生产 robot 需要读取 staging 项目并读写 `<project>-prod`，onboarding 授予这三项权限，不授予 staging push。copy 的两个配置共用代理环境，目标配置覆盖源配置，因此两端实际使用生产 Connector 的代理凭据；源只读挂载提供 CA，不构成独立的只读认证路径。
- 每次晋级使用新的 release label，并由管理员为 `<project>-prod` 配置 Harbor tag immutability。Pipeline 只检查格式，不查询标签是否已存在；重复标签应让晋级失败，不能移动已有发布标签。
- `require-signed-images` 只检查匹配发布仓库的镜像，生产 Pod 若使用其他仓库便不在这条规则范围内。生产环境还需限制只接受 `<project>-prod/*@sha256:*`。provenance 中的 Pipeline 名称也不单独证明构建身份，因为其他 namespace 可以创建同名 Pipeline。
- 在晋级被清理前单独导出 ApprovalTask；Tekton Results 保存 PipelineRun、TaskRun 和日志，不代替审批对象的归档。使用审批记录时还要结合前述真实身份验收结果。

## 触发与重跑

```text
/test ci-merge-request branch:<source-branch>
```

在合并请求中发送这条评论。PaC 使用该合并请求的源分支，`branch:` 保留统一的调用形式。生产候选 CI 必须使用新的、已评审的 `main` push；命名 `/test ci` 即使在 `main` 上也会被 pre-build 检查拒绝。完整语法见 [Trigger PAC Pipelines](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html)。

## 替换项

| 占位符 | 位置 | 含义 |
| --- | --- | --- |
| `registry.example.com/shop/hello`、`hello-mr`、`shop-prod/hello` | CI、CD、promotion | 测试、MR 临时和发布仓库 |
| `registry.example.com/base/*:<tag>` | `Containerfile` | 经过 air-gap 镜像仓库的构建/运行时基础镜像，尽量按 digest 固定 |
| `registry.example.com/catalog/<tool>:<tag>` | CD、promotion | Git、Kustomize、glab、run-script、skopeo 工具镜像 |
| `registry.example.com/mirror/trivy-db:2` | CI | Trivy DB 内部镜像 |
| `https://git.example.com` | PaC Repository | GitLab API 地址 |
| `https://git.example.com/shop/gitops/config.git` | CD | onboarding 播种的 GitOps 仓库 |
| `shop-build`、`shop-cd`、`shop-delivery`、`shop-release` | 全部 | CI/CD namespace 和 ServiceAccount |
| `shop-harbor`、`shop-gitops-writer` | CI、CD | onboarding 创建的 Connector |
| `shop-registry-readonly`、`shop-prod-registry` | promotion | 测试只读和生产晋级 Connector |
| `group:release-managers`、`<cluster-name>` | promotion | ACP 审批组和集群名 |

This is sample material, not part of the product.
