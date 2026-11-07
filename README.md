# 云吞插件：Vaultwarden

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

Vaultwarden（[github.com/dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden)，AGPL-3.0-only）是
自托管的密码管理服务，兼容 Bitwarden 客户端。这个插件把它装进云吞：网页经核心网关打开，登录走核心的身份提供方
（`sso: oidc`，Vaultwarden 1.37 起的 `SSO_*` 变量），数据（SQLite、附件、图标缓存）在插件自己的数据目录里。

## 插件行为

- 唯一的账号由本人第一次经 SSO 登录网页 vault 时创建（邮箱来自云吞的身份，`SIGNUPS_ALLOWED=false` 关掉邮箱注册）。
  第一次登录后网页 vault 会提示设置主密码：主密码是密码库的加密密钥，由用户自己定，插件不代设。
- 网页 vault 经网关时用的是 SSO；vaultwarden 自己的登录页仍在（浏览器里点一次“Use single sign-on”），
  这页同时是 Bitwarden 客户端直连时邮箱加主密码登录的入口。
- 图标：插件申请了 `network.egress`，vaultwarden 的 `/icons` 端点替客户端抓条目网站的图标；密码库数据本身不出网，
  SMTP 等别的出网功能没开。
- 管理面板（`/admin`）保持关闭：没设 `ADMIN_TOKEN` 时上游默认禁用，插件也不开。

## 网页密码库和 Bitwarden 客户端：要等 https

Vaultwarden 自带的网页密码库和 Bitwarden 官方客户端（浏览器扩展、桌面版、命令行从 2025.11 起，Android 从 2025.8 起）
只接受 `https://` 的服务器地址，`localhost` 也不例外（[bitwarden/clients#17095](https://github.com/bitwarden/clients/pull/17095)、[#17409](https://github.com/bitwarden/clients/issues/17409)）。
云吞的隧道里是 http，所以：

- 网页密码库在 App 的 WebView 里打得开，但登录时被拒；
- 官方客户端填 `http://<局域网地址>:8222` 也连不上（iOS App 有人说 http 还能用，没核实）。

能用的只有云吞单点登录这一段（OIDC 授权码流程走通）。网页密码库和客户端要等云吞的公网入口（https 域名加公共证书），
那时客户端填公网地址即可，手机上不用装证书。商店说明照实写了这一句。

局域网端口开关（默认关）留着：公网入口之前它只对还接受 http 的客户端有用；打开后 8222 开在局域网地址上，
客户端用邮箱加主密码登录，不依赖网关的 SSO 回调地址。

## 图标

`icon.svg` 取自 Vaultwarden 官方仓库的 `resources/vaultwarden-icon.svg`，来源和许可见 [NOTICE](NOTICE)。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件清单和 vaultwarden 服务 |
| `icon.svg`、`NOTICE` | 上游标志及其来源与许可 |
| `screenshots/` | 商店详情页的截图（手机竖屏） |
| `scripts/smoke-probes.sh` | 插件探针：真实页面、完整 OIDC 流程断言身份 |
