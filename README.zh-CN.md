# Alauda DevOps 最佳实践样例（中文入口）

本仓库是 Alauda DevOps 最佳实践系列的公开样例材料，不是产品代码，也不属于产品支持范围。仓库中的域名、项目名、镜像地址和加密占位符均为虚构值，使用前必须替换；示例 YAML、Shell 和代码片段保留英文，便于直接复制和执行。

配套英文文章：

文章目前在 [Knowledge PR #859](https://github.com/alauda/knowledge/pull/859) 审核，下列 `main` 链接是合并后的发布落点；审核期间可从 PR 查看正文。

- [Alauda DevOps Best Practices: Overview and Scenario Guide](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Alauda_DevOps_Best_Practices_Overview.md)
- [From Commit to Production on ACP](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/From_Commit_to_Production_on_ACP.md)
- [Managing Platform Configuration and Onboarding Isolated Projects with Argo CD and Tekton on ACP](https://github.com/alauda/knowledge/blob/main/docs/en/solutions/Managing_Platform_Configuration_and_Onboarding_Isolated_Projects_with_Argo_CD_and_Tekton_on_ACP.md)

## 前置条件

样例按 Pipelines 4.15、Artifact Hub Shim 1.0、Connectors 1.14 和 GitOps 4.4 编写；ACP、Kyverno 及其他补丁版本请在目标平台确认兼容性。需要提前准备 GitLab、Harbor、Nexus、SonarQube、Kyverno、Sealed Secrets、Tekton Chains、Manual Approval Gate、PaC webhook 注册凭据、Argo CD 仓库凭据，以及集群内可用的任务和工具镜像。离线环境还需要本地漏洞数据库、基础镜像和依赖仓库。

## 推荐顺序

1. 将 `gitops-template/` 发布为独立的项目 GitOps 模板仓库。
2. 按 `platform-repo/README.md` 准备 `platform-connectors`、四个自动创建 Task、凭据和 Argo CD 根 Application。
3. 将 `onboarding/` 放入平台仓库，先执行一次 `kubectl apply -k platform-repo/argocd/apps/`。引导前已经存在的项目声明不会自动触发分发运行，需要按项目手动启动 onboarding Run Template。
4. 用 `sample-app/README.md` 创建应用 PaC Repository，依次运行 CI、测试 CD、晋级和生产 CD。
5. 在隔离验收项目中运行 `acceptance/`。验收脚本会访问真实工具，并且自愈检查可能暂时删除项目负责人 RoleBinding，必须准备恢复方案。

## 可本地尝试的内容

不连接集群也可以先渲染 GitOps 文件：

```bash
kustomize build platform-repo/argocd/apps
kustomize build platform-repo/components
kustomize build platform-repo/policies
for d in gitops-template/envs/*/; do kustomize build "$d"; done
```

这些命令只能检查 Kustomize 渲染。onboarding、CI/CD、Connector、Argo CD、Harbor、GitLab webhook、签名和 acceptance 脚本都需要目标集群及外部工具。

## 使用时必须确认的边界

- 生产 Harbor 项目应保持私有。Kyverno 验签私有仓库时，还要配置能读取发布镜像及签名附件的凭据；切换到 `Enforce` 前先用已签名 digest 做阳性验证。
- `enable-connectors-approval` 关闭时，能在保存生产 Connector 的命名空间创建 Pod 或 PipelineRun 的主体可以直接使用其中的凭据，ApprovalTask 不会自动形成边界。
- GitOps writer 使用 Maintainer 级 group access token 时，可以修改分支保护和代码负责人设置。生产环境应使用独立的受控分支或仓库，并改用只能提出合并请求、不能修改保护规则或直接推送/合并生产变更的 writer 身份；同步调整 CD 仓库地址和 Argo CD 来源。仅给现有仓库添加分支保护或 CODEOWNERS 不能约束同一个 Maintainer token。
- 按名称执行 `/test ci` 会绕过 PaC 事件注解，因此样例在 pre-build 中再次检查事件和分支：只接受 `main` 上的 `push`，评论触发即使在 `main` 上也会失败。发布候选 CI 通过新的已评审 push 重试，评论验证使用 `ci-merge-request`。临时镜像与发布候选仍共用项目级凭据，更强的隔离需要独立临时 Harbor 项目和受限凭据。
- 样例中的 `imagePullFrom` 只保留字段并输出警告，未实现跨项目拉取授权。
- 验收脚本要求显式设置 `PROJECT` 为独立验收项目，不能直接指向普通生产租户；脚本不会默认使用 `shop` 等生产项目。
- 平台验收还要求设置不同的 `OTHER_PROJECT`，并交换两个隔离项目和各自已有镜像再测一次，才能检查双向拉取边界。

## 开通、变更与运维

项目开通的输入是平台仓库中的项目声明。新增项目的同一个合并请求还要加入 `projects/kustomization.yaml` 的 generator、该项目的 RBAC 与 ScheduledTrigger、`onboarding/kustomization.yaml` 的资源登记，以及生产验签策略中的镜像仓库。合并后检查 dispatcher 的 `onboarding-runs` 结果和每个子运行；合并成功不等于开通成功。第一次开通还需要管理员补齐 GitLab 人员成员关系和 webhook，并合并生成的平台注册请求。

调度、合并触发和手动入口使用同一个 onboarding Pipeline。第一个任务以原子创建 ConfigMap 的方式获取项目锁，避免同项目同时轮换凭据；成功后仅释放本次运行拥有的锁。失败、取消或清理中断可能保留 `onboarding-<project>-lock`，需要管理员先检查其中记录的运行及子运行，确认停止后再删除锁并重试。不要按超时时长自动抢锁。

组件层默认 `prune: false`、`selfHeal: false`，先观察 Operator 的字段回写再决定是否打开自愈。删除项目声明不是项目下线；回退注册提交可能 prune ACP 项目及同名命名空间，外部工具租户和其他命名空间需要单独处理。保留签名密钥、Sealed Secrets 解密密钥、工具数据库和 Results 存储的独立恢复方案。

## 交付与验收

样例按 CI → 测试 CD → 审批晋级 → 生产 CD 的顺序手动衔接，各阶段传递 digest。生产 CD 提合并请求，只修改生产 overlay 的 `digest:` 行。回滚也通过同一评审路径选择生产仓库中保留且验签通过的旧 digest；数据库和数据兼容性由应用的回滚方案处理。

交付验收要在首次晋级、生产 GitOps 合并和 rollout 完成后执行。脚本核对 digest、rollout、签名/provenance、审批对象及 admission；CI 来源、扫描结果、晋级结果和 GitOps 审核记录仍需人工核对。验签检查先确认已签名镜像可通过，再检查未签名镜像；`Audit` 只说明报告生效，切换 `Enforce` 并完成相同对照后才能声称拦截生效。

`platform-connectors` 和签名密钥所在命名空间的 Pod/PipelineRun 创建权限必须由平台团队控制。样例的执行策略排除了管理命名空间，这个排除本身不提供保护。平台仓库的合并前校验也默认在此运行；接收较低信任级别的贡献前，应将校验 Repository、有限权限令牌及运行迁入无管理员 Secret 的命名空间。

## 子目录说明

- [GitOps 模板](gitops-template/README.md)
- [平台仓库](platform-repo/README.md)
- [项目开通](onboarding/README.md)
- [样例应用](sample-app/README.md)
- [验收脚本](acceptance/README.md)
