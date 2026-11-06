# shellcheck shell=bash
# Vaultwarden：sso=oidc。
#
# 页面：web_assert 从标准输入读页面，命中的是 vaultwarden 网页 vault 的外壳（不是网关错误页）。
# 身份：identity_check 走完整的 OIDC 授权码流程——从 vaultwarden 的 /identity/connect/authorize 起
#       （PKCE），经核心身份方（核心会话自动登录）回到 /identity/connect/oidc-signin，再用授权码换
#       vaultwarden 的会话，断言 /api/accounts/profile 认出的邮箱就是云吞用户的邮箱。
#       第一次跑会在 vaultwarden 里建出这个账号（账号本来就是 SSO 首登创建的），可重复跑。
# 数据：data_write 登录后把用户资料名（/api/accounts/profile 的 name，明文存储的用户数据）改成随机
#       标记，标记存 $SMOKE_STATE/vw-data-marker；data_check 在升级/重装后重新登录断言标记还在。
#       密文条目要主密码派生的密钥，脚本写不了；资料名过得了重装就证明插件数据目录没丢。
# 工具：清单没有 mcp，保持不写。

web_assert() { grep -qi 'vaultwarden'; }

# 完整 OIDC 授权码流程，标准输出 access_token（失败时输出空并已写原因到 stdout）。
# 单独跑 identity 探针时 probes_web 没跑过，会话可能没建；session_into 已有会话时直接返回。
vw_sso_login() {
  local redirect="$SMOKE_WEB_URL/sso-connector.html" verifier challenge state enc_redirect
  local final code at
  # 单独跑 data 探针时前面的探针没跑过，SMOKE_WEB_URL 可能没设；probes_web_url 从核心列表取并 export。
  [[ -n "${SMOKE_WEB_URL:-}" ]] || { probes_web_url 数据探针 || return 1; redirect="$SMOKE_WEB_URL/sso-connector.html"; }
  probes_dev session >/dev/null 2>&1 || { echo "核心会话建立失败"; return 1; }
  read -r verifier challenge state <<<"$(python3 - <<'PY'
import base64, hashlib, secrets
verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b'=').decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
# state 要能过 vaultwarden 的 base64 解码（标准字母表）：24 字节输入没有补位，URL 里不用带 =。
state = base64.b64encode(("probe-" + secrets.token_hex(9)).encode()).decode()
print(verifier, challenge, state)
PY
)"
  [[ -n "$verifier" && -n "$challenge" && -n "$state" ]] || { echo "生成 PKCE/state 失败"; return 1; }
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"

  # 起点必须是 vaultwarden 自己的 authorize：它种下浏览器绑定 Cookie（VW_SSO_BINDING），回调时校验。
  # 同一个 cookie jar 带上核心会话（Hydra 自动登录）和这个绑定 Cookie，全程 -L。
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    --max-time 90 -w '%{url_effective}' \
    "$SMOKE_WEB_URL/identity/connect/authorize?client_id=web&redirect_uri=$enc_redirect&state=$state&code_challenge=$challenge&code_challenge_method=S256")" ||
    { echo "authorize 链失败：$final"; return 1; }
  read -r code state_check <<<"$(python3 -c '
import sys, urllib.parse
q = urllib.parse.urlparse(sys.argv[1]).query
p = urllib.parse.parse_qs(q)
print((p.get("code") or [""])[0], (p.get("state") or [""])[0])
' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有授权码：$final"; return 1; }
  [[ "$state_check" == "$state" ]] || { echo "state 对不上：$state_check"; return 1; }

  at="$(curl -sS --noproxy '*' --max-time 60 -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "client_id=web" \
    --data-urlencode "code=$code" \
    --data-urlencode "code_verifier=$verifier" \
    --data-urlencode "device_identifier=$(python3 -c 'import uuid;print(uuid.uuid4())')" \
    --data-urlencode "device_name=wonton-smoke" \
    --data-urlencode "device_type=14" \
    "$SMOKE_WEB_URL/identity/connect/token")" || { echo "换会话失败：$at"; return 1; }
  at="$(jq -r '.access_token // empty' <<<"$at" 2>/dev/null)"
  [[ -n "$at" ]] || { echo "token 响应里没有 access_token"; return 1; }
  printf '%s' "$at"
}

identity_check() {
  local at email
  at="$(vw_sso_login)" || { echo "$at"; return 1; }
  email="$(curl -sS --noproxy '*' --max-time 60 -H "Authorization: Bearer $at" \
    "$SMOKE_WEB_URL/api/accounts/profile")" || { echo "profile 失败：$email"; return 1; }
  jq -e --arg u "${SMOKE_OWNER_EMAIL,,}" '.email == $u and (.id | length > 0)' <<<"$email" >/dev/null ||
    { echo "认出的不是云吞用户 $SMOKE_OWNER_EMAIL：$email"; return 1; }
}

data_write() {
  local at marker
  at="$(vw_sso_login)" || { echo "SSO 登录失败：$at"; return 1; }
  marker="wonton-$(date +%s)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  curl -sS --noproxy '*' --max-time 60 -H "Authorization: Bearer $at" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$marker\"}" "$SMOKE_WEB_URL/api/accounts/profile" |
    jq -e --arg m "$marker" '.name == $m' >/dev/null ||
    { echo "资料名没写成 $marker"; return 1; }
  printf '%s' "$marker" > "$SMOKE_STATE/vw-data-marker"
}

data_check() {
  local marker at
  marker="$(cat "$SMOKE_STATE/vw-data-marker" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有标记：$SMOKE_STATE/vw-data-marker"; return 1; }
  at="$(vw_sso_login)" || { echo "SSO 登录失败：$at"; return 1; }
  curl -sS --noproxy '*' --max-time 60 -H "Authorization: Bearer $at" \
    "$SMOKE_WEB_URL/api/accounts/profile" |
    jq -e --arg m "$marker" '.name == $m' >/dev/null ||
    { echo "资料名对不上（期望 $marker）"; return 1; }
}
