#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_FILE="$PROJECT_DIR/subscription.url"
CONFIG_FILE="$PROJECT_DIR/config.yaml"
TUN_CONFIG_FILE="$PROJECT_DIR/config-tun.yaml"
TMP_CONFIG="$PROJECT_DIR/config.yaml.download"
CURL_CONNECT_TIMEOUT="${CLASH_CONNECT_TIMEOUT:-15}"
CURL_MAX_TIME="${CLASH_SUB_MAX_TIME:-30}"

usage() {
  cat <<EOF
用法:
  ./update-config.sh ['订阅链接']

不传订阅链接时，会读取:
  $SUB_FILE

更新后会生成:
  $CONFIG_FILE
  $TUN_CONFIG_FILE
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

curl_direct() {
  if [[ -n "${CLASH_DOWNLOAD_PROXY:-}" ]]; then
    curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --speed-limit 1 --speed-time 8 --proxy "$CLASH_DOWNLOAD_PROXY" "$@"
  else
    env \
      -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --speed-limit 1 --speed-time 8 --proxy "" --noproxy "*" "$@"
  fi
}

normalize_config() {
  local input_file="$1"
  local output_file="$2"
  local tun_enabled="$3"

  python3 - "$input_file" "$output_file" "$tun_enabled" <<'PY'
import base64
import json
import re
import sys
import urllib.parse

input_file, output_file, tun_enabled_arg = sys.argv[1], sys.argv[2], sys.argv[3]
tun_enabled = tun_enabled_arg == "1"

with open(input_file, "rb") as f:
    raw = f.read()

text = raw.decode("utf-8", "ignore").strip()


def looks_like_yaml(value):
    head = "\n".join(value.splitlines()[:200])
    return any(key in head for key in ("mixed-port:", "port:", "proxies:", "proxy-groups:", "rules:"))


def is_placeholder_config(value):
    return any(
        marker in value
        for marker in (
            "不支持您的代理软件",
            "请换用支持的代理软件",
            "server: 127.0.0.1, port: 6666",
            "127.0.0.1:6666",
        )
    )

def remove_top_level_tun(value):
    lines = value.splitlines()
    output = []
    index = 0

    while index < len(lines):
        line = lines[index]
        if re.match(r"^tun\s*:", line):
            index += 1
            while index < len(lines):
                next_line = lines[index]
                if next_line and not next_line.startswith((" ", "\t")):
                    break
                index += 1
            continue

        output.append(line)
        index += 1

    return "\n".join(output).rstrip() + "\n"


def apply_tun_to_yaml(value):
    value = remove_top_level_tun(value)
    if not tun_enabled:
        return value
    if re.search(r"(?m)^tun:\s*$", value):
        return value
    tun_block = """
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: false
  dns-hijack:
    - any:53
""".strip()
    return value.rstrip() + "\n" + tun_block + "\n"


def decode_base64_subscription(value):
    compact = re.sub(r"\s+", "", value)
    if not compact:
        return ""

    for candidate in (compact, compact.replace("-", "+").replace("_", "/")):
        padded = candidate + ("=" * ((4 - len(candidate) % 4) % 4))
        try:
            decoded = base64.b64decode(padded, validate=False)
            result = decoded.decode("utf-8")
        except Exception:
            continue
        if "://" in result or looks_like_yaml(result):
            return result.strip()
    return ""


def first(query, *names, default=""):
    for name in names:
        values = query.get(name)
        if values:
            return values[0]
    return default


def truthy(value):
    return str(value).lower() in ("1", "true", "yes")


def unique_name(name, used):
    base = name or "node"
    candidate = base
    index = 2
    while candidate in used:
        candidate = f"{base} {index}"
        index += 1
    used.add(candidate)
    return candidate


def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if value is None:
        return "null"
    return json.dumps(str(value), ensure_ascii=False)


def dump_yaml(value, indent=0):
    spaces = " " * indent
    lines = []
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                lines.append(f"{spaces}{key}:")
                lines.extend(dump_yaml(item, indent + 2))
            else:
                lines.append(f"{spaces}{key}: {scalar(item)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                lines.append(f"{spaces}-")
                lines.extend(dump_yaml(item, indent + 2))
            else:
                lines.append(f"{spaces}- {scalar(item)}")
    return lines


def parse_vless(line, name, used):
    parsed = urllib.parse.urlsplit(line)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    server = parsed.hostname
    try:
        port = parsed.port or 443
    except ValueError:
        return None
    uuid = urllib.parse.unquote(parsed.username or "")
    if not server or not uuid:
        return None

    network = first(query, "type", default="tcp")
    security = first(query, "security", default="none")
    sni = first(query, "sni", "servername")
    fingerprint = first(query, "fp", "fingerprint")
    host = first(query, "host")
    path = first(query, "path", default="/")
    flow = first(query, "flow")

    proxy = {
        "name": unique_name(name, used),
        "type": "vless",
        "server": server,
        "port": port,
        "uuid": uuid,
        "udp": True,
    }

    if security in ("tls", "reality"):
        proxy["tls"] = True
    if sni:
        proxy["servername"] = sni
    if fingerprint:
        proxy["client-fingerprint"] = fingerprint
    if flow:
        proxy["flow"] = flow
    if truthy(first(query, "insecure")):
        proxy["skip-cert-verify"] = True

    if network and network != "tcp":
        proxy["network"] = network
    if network == "ws":
        ws_opts = {"path": path or "/"}
        if host:
            ws_opts["headers"] = {"Host": host}
        proxy["ws-opts"] = ws_opts
    elif network == "grpc":
        service_name = first(query, "serviceName", "service_name")
        if service_name:
            proxy["grpc-opts"] = {"grpc-service-name": service_name}

    if security == "reality":
        reality_opts = {}
        public_key = first(query, "pbk", "public-key", "publicKey")
        short_id = first(query, "sid", "short-id", "shortId")
        if public_key:
            reality_opts["public-key"] = public_key
        if short_id:
            reality_opts["short-id"] = short_id
        if reality_opts:
            proxy["reality-opts"] = reality_opts

    return proxy


def parse_hysteria2(line, name, used):
    parsed = urllib.parse.urlsplit(line)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    server = parsed.hostname
    try:
        port = parsed.port or 443
    except ValueError:
        return None
    password = urllib.parse.unquote(parsed.username or "")
    if not server or not password:
        return None

    proxy = {
        "name": unique_name(name, used),
        "type": "hysteria2",
        "server": server,
        "port": port,
        "password": password,
        "udp": True,
    }
    sni = first(query, "sni")
    ports = first(query, "mport", "ports")
    if sni:
        proxy["sni"] = sni
    if ports:
        proxy["ports"] = ports
    if truthy(first(query, "insecure")):
        proxy["skip-cert-verify"] = True
    return proxy


def parse_trojan(line, name, used):
    parsed = urllib.parse.urlsplit(line)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    server = parsed.hostname
    try:
        port = parsed.port or 443
    except ValueError:
        return None
    password = urllib.parse.unquote(parsed.username or "")
    if not server or not password:
        return None

    proxy = {
        "name": unique_name(name, used),
        "type": "trojan",
        "server": server,
        "port": port,
        "password": password,
        "udp": True,
    }
    sni = first(query, "sni", "peer")
    if sni:
        proxy["sni"] = sni
    if truthy(first(query, "allowInsecure", "insecure")):
        proxy["skip-cert-verify"] = True
    return proxy


def parse_node(line, used):
    line = line.strip()
    if not line or "://" not in line:
        return None

    parsed = urllib.parse.urlsplit(line)
    scheme = parsed.scheme.lower()
    name = urllib.parse.unquote(parsed.fragment or "").strip()

    if any(marker in name for marker in ("剩余流量", "套餐到期", "官网地址", "STATUS")):
        return None

    if scheme == "vless":
        return parse_vless(line, name, used)
    if scheme in ("hysteria2", "hy2"):
        return parse_hysteria2(line, name, used)
    if scheme == "trojan":
        return parse_trojan(line, name, used)
    return None


if looks_like_yaml(text):
    if is_placeholder_config(text):
        print("订阅服务返回了不支持当前客户端的占位配置。请使用 CLASH_SUB_USER_AGENT=mihomo 重新更新。", file=sys.stderr)
        sys.exit(1)
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(apply_tun_to_yaml(text))
    sys.exit(0)

decoded = decode_base64_subscription(text)
content = decoded or text

if looks_like_yaml(content):
    if is_placeholder_config(content):
        print("订阅服务返回了不支持当前客户端的占位配置。", file=sys.stderr)
        sys.exit(1)
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(apply_tun_to_yaml(content))
    sys.exit(0)

used_names = set()
proxies = []
for line in content.replace("\r", "\n").split("\n"):
    proxy = parse_node(line, used_names)
    if proxy:
        proxies.append(proxy)

if not proxies:
    print("无法从订阅内容中解析出 Mihomo 支持的节点。", file=sys.stderr)
    sys.exit(1)

names = [proxy["name"] for proxy in proxies]
config = {
    "mixed-port": 7890,
    "allow-lan": False,
    "bind-address": "127.0.0.1",
    "mode": "rule",
    "log-level": "info",
    "external-controller": "127.0.0.1:9090",
    "unified-delay": True,
    "tcp-concurrent": True,
    "dns": {
        "enable": True,
        "ipv6": False,
        "default-nameserver": ["223.5.5.5", "119.29.29.29", "114.114.114.114"],
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        "nameserver": ["223.5.5.5", "119.29.29.29", "114.114.114.114"],
        "fallback": ["1.1.1.1", "8.8.8.8"],
    },
    "proxies": proxies,
    "proxy-groups": [
        {
            "name": "🚀 节点选择",
            "type": "select",
            "proxies": ["♻️ 自动选择"] + names + ["DIRECT"],
        },
        {
            "name": "♻️ 自动选择",
            "type": "url-test",
            "url": "http://www.gstatic.com/generate_204",
            "interval": 300,
            "tolerance": 50,
            "proxies": names,
        },
    ],
    "rules": [
        "GEOIP,CN,DIRECT",
        "MATCH,🚀 节点选择",
    ],
}

if tun_enabled:
    config["tun"] = {
        "enable": True,
        "stack": "mixed",
        "auto-route": True,
        "auto-detect-interface": True,
        "strict-route": False,
        "dns-hijack": ["any:53"],
    }

with open(output_file, "w", encoding="utf-8") as f:
    f.write("\n".join(dump_yaml(config)) + "\n")
PY
}

main() {
  local subscription_url="${1:-}"
  local sub_user_agent="${CLASH_SUB_USER_AGENT:-mihomo}"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  need_cmd curl
  need_cmd python3

  if [[ -z "$subscription_url" ]]; then
    if [[ ! -s "$SUB_FILE" ]]; then
      echo "未提供订阅链接，并且 $SUB_FILE 不存在。" >&2
      usage
      exit 1
    fi
    subscription_url="$(head -n 1 "$SUB_FILE")"
  else
    printf '%s\n' "$subscription_url" > "$SUB_FILE"
    chmod 600 "$SUB_FILE"
  fi

  echo "下载订阅配置..."
  if ! curl_direct -fL \
    -H "User-Agent: $sub_user_agent" \
    -H "Accept: text/plain, application/yaml, application/x-yaml, */*" \
    "$subscription_url" \
    -o "$TMP_CONFIG"; then
    if [[ -s "$TMP_CONFIG" ]]; then
      echo "下载连接提前结束或超时，但已收到配置内容，继续处理。"
    else
      echo "订阅配置下载失败。" >&2
      echo "如果这个订阅地址必须通过代理访问，请使用:" >&2
      echo "  CLASH_DOWNLOAD_PROXY=http://代理地址:端口 ./update-config.sh" >&2
      exit 1
    fi
  fi

  if [[ ! -s "$TMP_CONFIG" ]]; then
    echo "订阅配置下载失败。" >&2
    exit 1
  fi

  normalize_config "$TMP_CONFIG" "$CONFIG_FILE" 0
  normalize_config "$TMP_CONFIG" "$TUN_CONFIG_FILE" 1
  rm -f "$TMP_CONFIG"
  chmod 600 "$CONFIG_FILE" "$TUN_CONFIG_FILE"
  echo "普通配置已更新: $CONFIG_FILE"
  echo "TUN 配置已更新: $TUN_CONFIG_FILE"
}

main "$@"
