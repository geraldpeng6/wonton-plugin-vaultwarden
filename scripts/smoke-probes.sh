# shellcheck shell=bash
# Vaultwarden：sso=oidc。只用套件允许的变量（SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、
# SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE）和助手（web_get、dweb），不用套件内部函数。
#
# 页面：web_assert 从标准输入读页面，命中的是 vaultwarden 网页 vault 的外壳（不是网关错误页）。
# 身份：identity_check 走完整的 OIDC 授权码流程（PKCE）——从 vaultwarden 的 /identity/connect/authorize
#       起（vaultwarden 种下浏览器绑定 Cookie），经核心身份方（SMOKE_JAR 里的核心会话自动登录）回到
#       /identity/connect/oidc-signin，再用授权码换 vaultwarden 会话，断言 /api/accounts/profile 的
#       name 就是 SMOKE_OWNER（SSO 建号时取 preferred_username=云吞用户名）。
#       第一次跑会在 vaultwarden 里建出这个账号（账号本来就是 SSO 首登创建的），可重复跑。
# 数据：data_write 用 PUT /api/accounts/avatar 把头像色改成随机 #RRGGBB 标记（明文用户数据；不碰
#       profile.name，identity 的断言不受影响），标记文件放 $SMOKE_STATE；data_check 在升级/重装后
#       断言头像色还是标记。密文条目要主密码派生的密钥，脚本写不了；头像色过重装即证明数据目录没丢。
# 工具：清单没有 mcp，保持不写。

web_assert() { grep -qi 'vaultwarden'; }

# 完整 OIDC 授权码流程，标准输出 vaultwarden 的 access_token。
vw_sso_login() {
  local verifier challenge state enc_redirect final code at
  read -r verifier challenge state <<<"$(python3 - <<'PY'
import base64, hashlib, secrets
verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b'=').decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
# state 要能过 vaultwarden 的 base64 解码（标准字母表，见 sso.rs decode_state），不能换成 urlsafe。
state = base64.b64encode(("probe-" + secrets.token_hex(9)).encode()).decode()
print(verifier, challenge, state)
PY
)"
  [[ -n "$verifier" && -n "$challenge" && -n "$state" ]] || { echo "生成 PKCE/state 失败"; return 1; }
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$SMOKE_WEB_URL/sso-connector.html")"

  # 先经套件入口走一遍网关的 SSO 跳板（fresh 才会真的走）：核心会话 → 身份方会话，
  # 后面的 hydra authorize 才不会停在身份方登录页。
  dweb --fresh --sso / >/dev/null 2>&1 || { echo "SSO 跳板走不通"; return 1; }

  # 起点必须是 vaultwarden 自己的 authorize：它种下浏览器绑定 Cookie（VW_SSO_BINDING），回调时校验。
  # 同一个 cookie jar（SMOKE_JAR）带上身份方会话和这个绑定 Cookie，全程 -L。
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    --max-time 90 -w '%{url_effective}' \
    "$SMOKE_WEB_URL/identity/connect/authorize?client_id=web&redirect_uri=$enc_redirect&state=$state&code_challenge=$challenge&code_challenge_method=S256")" ||
    { echo "authorize 链失败：$final"; return 1; }
  read -r code state_check <<<"$(python3 -c '
import sys, urllib.parse
p = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
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
    --data-urlencode "device_name=wonton-probe" \
    --data-urlencode "device_type=14" \
    "$SMOKE_WEB_URL/identity/connect/token")" || { echo "换会话失败：$at"; return 1; }
  at="$(jq -r '.access_token // empty' <<<"$at" 2>/dev/null)"
  [[ -n "$at" ]] || { echo "token 响应里没有 access_token"; return 1; }
  printf '%s' "$at"
}

identity_check() {
  local at profile
  at="$(vw_sso_login)" || { echo "$at"; return 1; }
  profile="$(web_get /api/accounts/profile -H "Authorization: Bearer $at")" ||
    { echo "profile 失败：$profile"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.name == $u and (.id | length > 0)' <<<"$profile" >/dev/null ||
    { echo "认出的不是云吞用户 $SMOKE_OWNER：$profile"; return 1; }
}

data_write() {
  local at marker
  at="$(vw_sso_login)" || { echo "SSO 登录失败：$at"; return 1; }
  marker="#$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  web_get /api/accounts/avatar -X PUT -H "Authorization: Bearer $at" -H 'Content-Type: application/json' \
    -d "{\"avatarColor\":\"$marker\"}" | jq -e --arg c "$marker" '.avatarColor == $c' >/dev/null ||
    { echo "头像色没写成 $marker"; return 1; }
  printf '%s' "$marker" > "$SMOKE_STATE/vw-data-marker"
}

data_check() {
  local marker at
  marker="$(cat "$SMOKE_STATE/vw-data-marker" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有标记：$SMOKE_STATE/vw-data-marker"; return 1; }
  at="$(vw_sso_login)" || { echo "SSO 登录失败：$at"; return 1; }
  web_get /api/accounts/profile -H "Authorization: Bearer $at" |
    jq -e --arg c "$marker" '.avatarColor == $c' >/dev/null ||
    { echo "头像色对不上（期望 $marker）"; return 1; }
}
