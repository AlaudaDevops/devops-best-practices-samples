# 项目 GitOps 仓库模板

English version：[README.md](README.md)。

这是最佳实践系列中“平台配置与项目开通”文章使用的项目 GitOps 仓库模板。开通流水线会把本目录复制到每个项目的新仓库（例如 `shop/gitops/config`），按项目声明生成环境目录，并创建 PaC `Repository` `<project>-gitops`。Argo CD 通过项目 Application 读取该仓库；Argo CD 的只读仓库凭据是平台前置条件，不由开通流水线创建。所有路径都相对于本目录，可直接复制到独立仓库。

本目录是示例材料，不属于产品，也不在产品支持范围内。

## 目录结构

```text
./
├── base/                 # Deployment 和 Service 的应用骨架
├── envs/
│   ├── _env/             # 播种时复制为每个普通环境的 envs/<env>
│   └── _prod/            # 播种时复制为 envs/prod，镜像指向发布项目
├── .tekton/
│   └── validate.yaml     # 合并请求检查，渲染所有 overlay
└── README.md             # 平台约定
```

Argo CD 为每个 `envs/<env>/` 目录渲染一个 Application。

## 平台约定

### 使用 `/test` 触发或重跑校验

在项目 GitOps 仓库的合并请求中执行：

```text
/test validate branch:<branch>
```

完整语法见 [Trigger PAC Pipelines](https://docs.alauda.io/alauda-devops-pipelines/4.15/pac/how_to/trigger_pipeline.html)。合并请求校验使用模板仓库当前的 `.tekton/validate.yaml`；只有合并后定义才会改变后续运行。

### 镜像只使用 digest

Manifest 使用 `registry.example.com/<project>/<image>@sha256:<digest>`，不使用 tag。晋级流水线只修改 `envs/<env>/kustomization.yaml` 中 `images` 条目的 `digest`。播种时 `_prod` 已将 `newName` 指到 `<project>-prod`，所以生产流水线只写 digest。第一次晋级前生产 overlay 保留 `<digest>` 占位符，Application 不会启动 Pod。

### 合并请求校验使用平台任务库

`.tekton/validate.yaml` 在内联 `pipelineSpec` 中组合 catalog 的 `git-clone` 和 `run-script` Task，通过 `resolver: hub` 和固定版本执行。播种前必须把 render Task 的 `image` 改成目标镜像仓库中带 `sh`、`kubectl` 的镜像。

平台可以启用 `platform-repo/policies/pipelinerun-source-baseline.yaml`，只允许 `cluster`、`hub`、`git` resolver，同时拒绝内联 `pipelineSpec`。Audit 模式会在 PolicyReport 中记录，Enforce 模式会拒绝创建运行。启用后应把两个 Task 发布为 catalog Pipeline，并改为 hub `pipelineRef`；未启用时可以保留当前内联形式。

### 谁能改 `main`，尤其是 `envs/prod`

Argo CD 部署 `main` 上的内容，因此 `main` 是项目的部署边界：

- 开通使用项目的 developer group token，并设置 `pipelinerun_provenance: default_branch`，所以 `.tekton/` 按已合并定义运行。
- CD 使用独立的 `<project>-gitops-writer` maintainer token：测试环境直接提交到 `main`，生产环境提交合并请求。
- 示例不会自动配置 GitLab 分支保护和 CODEOWNERS。持有该 Maintainer token 的人仍能直接修改 `envs/prod`、分支保护和 code owner 设置。生产环境应使用只能创建合并请求、不能修改保护或直接合并的项目级 writer，并将生产仓库或分支与测试写入路径分开。

如果 GitLab 版本支持强制 Code Owner 审批，可在受保护生产路径加入：

```text
/envs/prod/ @<release-managers-group-path>
```

必须用实际 writer 验证直接推送被拒、规则不能被删除，同时测试路径仍可正常更新。验证通过前，生产审核只是操作约定。

## 本地检查

```bash
for d in envs/*/; do
  kustomize build "$d" >/dev/null && echo "PASS $d" || echo "FAIL $d"
done
```

这只检查 Kustomize 组合，不检查 CRD、凭据或 Application 健康状态。

## 替换项

| 占位符 | 文件 | 含义 |
| --- | --- | --- |
| `registry.example.com/shop/hello` | `base/deployment.yaml`、两个 overlay | 测试镜像仓库；替换 registry、项目和镜像名 |
| `registry.example.com/shop-prod/hello` | `envs/_prod/kustomization.yaml` | 发布镜像仓库的 `newName` |
| `<digest>` | 两个 overlay | 交付流水线写入的镜像 digest |
| `shop-test` / `shop-prod` | 两个 overlay | 目标环境命名空间 |
| `envs/<environment>` | `.tekton/validate.yaml` 的 `paths` | 播种生成的所有 overlay |
| `<registry>/<catalog-project>/kubectl:<tag>` | `.tekton/validate.yaml` | air-gap 可用、带 `sh` 和 `kubectl` 的工具镜像 |

This is sample material, not part of the product.
