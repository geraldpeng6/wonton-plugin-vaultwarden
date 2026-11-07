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

# URL 只留路径和参数名：参数值里有 code、state、回跳地址和令牌，不能进日志。
vw_url_trace() {
  python3 -c '
import sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1])
def names(q):
    return ",".join(dict.fromkeys(k for k, _ in urllib.parse.parse_qsl(q, keep_blank_values=True)))
print(u.netloc + u.path + (("?" + names(u.query)) if u.query else "") + (("#" + names(u.fragment)) if u.fragment else ""))
' "$1"
}

# 授权链逐跳跟踪：跟着 30x 重定向走，落在只含隐藏字段的自动提交表单就替浏览器 POST（同套件
# sso_form_login 的走法，ASP.NET 式同名字段按 name 去重）。每跳往 stderr 打一行
# 「状态码 方法 域名/路径?参数名」，REPLY 带回落点 URL；重定向断头、HTTP 错误、要人填的表单、
# 超过 16 跳都算走不完，返回 1。
vw_chain_trace() {
  local url="$1" method="GET" data="" hop out status redirect body form action
  for hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    body="$(mktemp)"
    if [[ "$method" == GET ]]; then
      if ! out="$(curl -sS --noproxy '*' -o "$body" -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
        --max-time 15 -w 'status=%{http_code} redir=%{redirect_url}' "$url")"; then
        printf '%s 第 %d 跳请求失败：' "$method" "$hop"; vw_url_trace "$url" >&2
        rm -f "$body"; return 1
      fi
    else
      if ! out="$(curl -sS --noproxy '*' -o "$body" -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
        --max-time 15 -w 'status=%{http_code} redir=%{redirect_url}' --data "$data" "$url")"; then
        printf '%s 第 %d 跳请求失败：' "$method" "$hop"; vw_url_trace "$url" >&2
        rm -f "$body"; return 1
      fi
    fi
    status="${out%% *}"; status="${status#status=}"
    redirect="${out#*redir=}"
    printf '%s %s ' "$status" "$method"; vw_url_trace "$url" >&2
    case "$status" in
      30[1278])
        if [[ -z "$redirect" ]]; then echo "重定向缺 Location，链断了"; rm -f "$body"; return 1; fi
        url="$redirect"; rm -f "$body"; continue ;;
      2*) ;;
      *) rm -f "$body"; return 1 ;;
    esac
    form="$(python3 - "$body" "$url" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urlencode, urljoin
import sys

class Forms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.forms = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form" and self.current is None:
            self.current = {"action": a.get("action", ""),
                            "method": a.get("method", "post").lower(),
                            "fields": []}
        elif tag == "input" and self.current is not None:
            name = a.get("name")
            if name:
                self.current["fields"].append((name, a.get("value", ""), a.get("type", "text").lower()))

    def handle_endtag(self, tag):
        if tag == "form" and self.current is not None:
            self.forms.append(self.current)
            self.current = None

parser = Forms()
with open(sys.argv[1], encoding="utf-8", errors="replace") as page:
    parser.feed(page.read())
for form in parser.forms:
    if form["method"] != "post":
        continue
    hidden, visible = [], []
    seen = set()
    for name, value, typ in form["fields"]:
        (hidden if typ == "hidden" else visible).append((name, value))
        if name not in seen:
            seen.add(name)
    if visible:
        print("INPUT:" + ",".join(dict.fromkeys(n for n, _ in visible)))
        break
    if hidden:
        # noscript 兜底块会把同名字段重复一遍：按 name 去重，取第一次出现的
        print(urljoin(sys.argv[2], form["action"]))
        print(urlencode(dict.fromkeys(hidden)))
        break
PY
)"
    rm -f "$body"
    case "$form" in
      "") REPLY="$url"; return 0 ;;
      "INPUT:"*) echo "落在要人填的表单（字段：${form#INPUT:}），链走不下去"; return 1 ;;
      *)
        action="${form%%$'\n'*}"
        data="${form#*$'\n'}"
        printf 'POST '; vw_url_trace "$action" >&2
        method="POST"; url="$action" ;;
    esac
  done
  echo "重定向超过 16 跳，链走不完"; return 1
}

# 完整 OIDC 授权码流程，标准输出 vaultwarden 的 access_token。
vw_sso_login() {
  local verifier challenge state_raw state enc_redirect final code state_check at dweb_err tok_body tok_code
  read -r verifier challenge state_raw <<<"$(python3 - <<'PY'
import base64, hashlib, secrets
verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b'=').decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
print(verifier, challenge, "probe-" + secrets.token_hex(9))
PY
)"
  [[ -n "$verifier" && -n "$challenge" && -n "$state_raw" ]] || { echo "生成 PKCE/state 失败"; return 1; }
  local web="${SMOKE_WEB_URL%/}"
  # 发给 vaultwarden 的 state 要能过它的标准 base64 解码（identity.rs oidcsignin 的 decode_state），
  # 不能换成 urlsafe；回调把解码后的原始值放回 query，所以编码着发、对着原始值比。
  # 标准 base64 里的 + / = 直接放 query 会被当成空格和分隔符，authorize 参数要先 percent-encode。
  read -r state enc_redirect <<<"$(python3 -c '
import base64, sys, urllib.parse
print(urllib.parse.quote(base64.b64encode(sys.argv[1].encode()).decode(), safe=""),
      urllib.parse.quote(sys.argv[2] + "/sso-connector.html", safe=""))
' "$state_raw" "$web")"

  # 先经套件入口走一遍网关的 SSO 跳板（fresh 才会真的走）：核心会话 → 身份方会话，
  # 后面的 hydra authorize 才不会停在身份方登录页。
  dweb_err="$(dweb --fresh --sso / 2>&1 >/dev/null)" || { echo "SSO 跳板走不通：$dweb_err"; return 1; }

  # 起点必须是 vaultwarden 自己的 authorize：它种下浏览器绑定 Cookie，回调时校验。
  # 同一个 cookie jar（SMOKE_JAR）带上身份方会话和这个绑定 Cookie，逐跳走完（轨迹见上面）。
  REPLY=""
  vw_chain_trace "$web/identity/connect/authorize?client_id=web&redirect_uri=$enc_redirect&state=$state&code_challenge=$challenge&code_challenge_method=S256" ||
    { echo "authorize 链没走完（逐跳轨迹见上）"; return 1; }
  final="$REPLY"
  read -r code state_check <<<"$(python3 -c '
import sys, urllib.parse
p = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
print((p.get("code") or [""])[0], (p.get("state") or [""])[0])
' "$final")"
  [[ -n "$code" ]] || { printf '回调里没有授权码，落点：'; vw_url_trace "$final"; return 1; }
  # 回调的 state 是解码后的原始值；两种形态都认，都是本次授权的证明
  [[ "$state_check" == "$state_raw" || "$state_check" == "$state" ]] ||
    { echo "state 对不上（编码前后都不是本次生成的）"; return 1; }

  tok_body="$(mktemp)"
  tok_code="$(curl -sS --noproxy '*' --max-time 60 -o "$tok_body" -w '%{http_code}' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "client_id=web" \
    --data-urlencode "code=$code" \
    --data-urlencode "code_verifier=$verifier" \
    --data-urlencode "device_identifier=$(python3 -c 'import uuid;print(uuid.uuid4())')" \
    --data-urlencode "device_name=wonton-probe" \
    --data-urlencode "device_type=14" \
    "$web/identity/connect/token")" || { echo "换会话请求失败"; rm -f "$tok_body"; return 1; }
  printf 'token %s ' "$tok_code"; vw_url_trace "$web/identity/connect/token" >&2
  at="$(jq -r '.access_token // empty' "$tok_body" 2>/dev/null)"
  [[ -n "$at" ]] || { echo "token 响应（HTTP $tok_code）没有 access_token，字段：$(jq -r 'keys | join(",")' "$tok_body" 2>/dev/null)"; rm -f "$tok_body"; return 1; }
  rm -f "$tok_body"
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
