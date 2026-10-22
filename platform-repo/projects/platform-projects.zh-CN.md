# 平台项目

English version：[platform-projects.md](platform-projects.md)。

平台项目是 ACP 中的 Kubernetes 资源。首次开通时，由管理员先在平台控制台或 API 中创建项目，开通流水线要求该项目已经存在。随后流水线导出项目清单，去掉 `status`、服务端元数据和 tracking 标记，并在第 7 步登记 Argo CD Application 的同一个合并请求中加入 `<project>/platform-project.yaml`。合并后，`projects` Application 同步这份清单；重建环境时可从它初始化平台项目。`<platform-project-kind>` 是占位符，需要确认目标平台的实际 API。

首次开通还未导出清单时，下表记录合并项目声明之前必须手工创建的平台项目：

| 平台项目 | 声明 | 手工创建时机 | 导出的清单 | 说明 |
| --- | --- | --- | --- | --- |
| `shop` | `shop.yaml` | 合并声明之前 | `shop/platform-project.yaml`，由开通登记 MR 产生 | 第一个样例项目 |
| `payments` | `payments.yaml` | 合并声明之前 | `payments/platform-project.yaml`，由开通登记 MR 产生 | 第二个样例项目，用于验证跨项目镜像拉取拒绝 |

## 新增项目

1. 在平台控制台或 API 中创建平台项目。
2. 在上表增加对应记录。
3. 在 `shop.yaml` 旁添加 `<project>.yaml`，并在 `kustomization.yaml` 的 `configMapGenerator` 中登记它。
4. 在同一个 MR 中，为复制到平台仓库的 `onboarding/` 增加该项目的发布 Connector RBAC 和 ScheduledTrigger。分别复制 `onboarding/rbac/release-connectors-shop.yaml` 与 `onboarding/triggers/shop.yaml`，替换项目名，并把两个文件都加入 `onboarding/kustomization.yaml`。缺少前者时开通无法写入该项目的发布 Connector；缺少后者时项目没有定期轮换入口。`payments` 展示了完整登记结果。
5. 同一个 MR 还需在 `policies/require-signed-images.yaml` 的 `imageReferences` 中登记 `registry.example.com/<project>-prod/*`。开通不会自动修改该策略；未登记的发布仓库不在验签范围内。
6. 提交 MR，由 `../.tekton/validate.yaml` 在合并前渲染各目录。管理员还要为中央 Chains 凭据补齐该项目的写权限，为 Kyverno 的独立凭据补齐发布镜像和签名附件的读权限。

合并声明后，dispatcher 会等待精确版本的声明 ConfigMap，以及同名的项目发布 Connector Role 和 RoleBinding，再创建子运行。检查 dispatcher 的 `onboarding-runs` 结果和每个子运行，不能仅凭合并成功认定开通完成。首次引导前已经存在的声明仍需按[平台仓库引导步骤](../README.zh-CN.md#引导)手工启动一次。
