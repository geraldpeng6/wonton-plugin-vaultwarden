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

## Bitwarden 客户端直连

浏览器扩展和手机上的 Bitwarden 客户端不经云吞网关，直连时用邮箱加主密码登录。入口是插件详情页的
“局域网端口”开关（默认关）：打开后 vaultwarden 的 8222 端口开在局域网地址上，客户端把服务器地址填成
`http://<局域网地址>:8222` 即可；要经公网接入时，在路由器或自己的反代上把这个端口发出去。

两条路的取舍：

- 网页 vault 的 SSO 回调地址由 `DOMAIN` 生成，装好时指向云吞网关的插件地址；客户端直连用的是邮箱加主密码，
  不依赖这个地址，所以直连不需要改任何配置。
- 若将来把直连地址固定成公网域名并想让客户端也走 SSO，得把 `DOMAIN` 改成公网地址——那会同时改变网页 vault
  的 SSO 回调，网关这条路的单点登录就对不上了。两个地址一次只能选一个生效，本版本选网页 SSO；公网接入先用
  邮箱加主密码，足够客户端同步。

## 图标

`icon.svg` 取自 Vaultwarden 官方仓库的 `resources/vaultwarden-icon.svg`，来源和许可见 [NOTICE](NOTICE)。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件清单和 vaultwarden 服务 |
| `icon.svg`、`NOTICE` | 上游标志及其来源与许可 |
| `screenshots/` | 商店详情页的截图（手机竖屏） |
| `scripts/smoke-probes.sh` | 插件探针：真实页面、完整 OIDC 流程断言身份 |
