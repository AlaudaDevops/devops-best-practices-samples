# 凭据层中的 Sealed Secrets

English version：[SEALED-SECRETS.md](SEALED-SECRETS.md)。

本目录保存开通流水线使用的管理员 Connector，用于在 GitLab、Harbor、Nexus 和 SonarQube 创建项目、账号与令牌。Connector 引用的凭据只以 [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) 密文进入 Git：Argo CD 同步 `SealedSecret`，目标集群的 sealed-secrets controller 将它解密为 `platform-connectors` 中的普通 `Secret`，供同名 Connector 使用。

不要把明文 Secret、`.env`、令牌、密码、私钥、证书或 kubeconfig 提交到仓库，也不要临时提交。如果无法连接 controller 获取密封证书，应先联系平台管理员。

## 同步与密封范围

- `sealedsecret-<tool>-admin.yaml` 中的 `<encrypted>` 是占位符，不能解密。首次同步前，必须为目标集群重新生成所有密文。
- 默认的 strict scope 同时绑定 Secret 的 namespace 和名称；重命名或迁移 namespace 后需要重新密封。
- `platform-credentials` Application 设置 `selfHeal: false`，以便协调 controller 回写和凭据轮换；配置见 `../argocd/apps/platform-credentials.yaml`。

## 各工具的 Secret 类型

| 文件 | Secret 类型 | 键 | Connector 认证方式 |
| --- | --- | --- | --- |
| `sealedsecret-gitlab-admin.yaml` | `connectors.cpaas.io/gitlab-pat-auth` | `token` | `patAuth` |
| `sealedsecret-harbor-admin.yaml` | `kubernetes.io/basic-auth` | `username`、`password` | `basicAuth` |
| `sealedsecret-nexus-admin.yaml` | `kubernetes.io/basic-auth` | `username`、`password` | `basicAuth` |
| `sealedsecret-sonarqube-admin.yaml` | `connectors.cpaas.io/bearer-token` | `token` | `tokenAuth` |
| `sealedsecret-platform-config-auth.yaml` | `Opaque` | `provider.token`、`webhook.secret` | 由 `pac-repository-platform-config.yaml` 中的 PaC Repository 使用 |

每份管理员凭据在对应工具中必须具有创建群组、项目、仓库或用户所需的权限。准确要求见 Connectors 文档中对应工具的 automatic-creation Task 页面。

## 密封一份凭据

1. 使用 `kubeseal --fetch-cert` 获取目标 controller 的公钥证书，明确指定 kubeconfig context、controller namespace 和名称。公钥证书可以共享；私钥不能进入仓库。
2. 在内存中生成符合上表类型的 Secret，将 `kubectl create secret ... --dry-run=client -o yaml` 的输出直接管道传给 `kubeseal --cert ... --format yaml`。只保存最终的 SealedSecret 密文，不保存或 apply 中间的明文。
3. 检查密文对象及 `spec.template.metadata` 中的 namespace、名称和 Secret 类型，保留文件顶部的 Series 注释，再通过合并请求提交。合并前的校验会渲染该目录。

完整命令和 YAML 形状见[英文版操作片段](SEALED-SECRETS.md#seal-a-credential)。`<kube-context>` 指目标集群的 kubeconfig context，与其他样例中的 Argo CD 注册集群名 `<cluster-name>` 不同。

## 备份解密密钥

SealedSecret 只能由持有对应密钥的 controller 解密。重建集群时，新 controller 生成的新密钥不能解密旧文件；管理员 Connector 因而没有 Secret，开通流程也无法继续。平台应明确选择并演练以下一种方式：

- 把 controller namespace 中带有 `sealedsecrets.bitnami.com/sealed-secrets-key` 标签的密钥 Secret 备份到仓库以外的离线受控存储，在首次同步 `platform-credentials` 前恢复。
- 或者获取新 controller 的公钥证书，从工具或受控凭据库取得凭据明文，重新密封本目录的每一份凭据，并在首次同步前合并新密文。Git 中没有可供恢复的明文。

解密密钥备份本身是敏感凭据；持有者可以解密本目录中相应的密文。

## 轮换凭据

按相同流程密封新值并提交新密文，Git 历史保留变更记录。controller 原地更新 Secret，Connector 使用更新后的内容。automatic-creation Task 写出的项目级凭据不存放在本目录，它们通过重新执行开通 Task 轮换；详见[开通说明](../../onboarding/README.zh-CN.md)。
