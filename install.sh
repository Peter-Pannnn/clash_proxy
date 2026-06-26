#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_BIN="$PROJECT_DIR/clash"
SUB_FILE="$PROJECT_DIR/subscription.url"
CONFIG_FILE="$PROJECT_DIR/config.yaml"
TMP_ARCHIVE="$PROJECT_DIR/mihomo.gz"
GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
CURL_CONNECT_TIMEOUT="${CLASH_CONNECT_TIMEOUT:-15}"
CURL_MAX_TIME="${CLASH_MAX_TIME:-120}"
DEFAULT_GITHUB_MIRROR="https://gh.llkk.cc/"

usage() {
  cat <<EOF
用法:
  ./install.sh '<订阅链接>' [--no-start]

示例:
  ./install.sh 'https://example.com/subscription'
  ./install.sh 'https://example.com/subscription' --no-start

所有文件都会放在:
  $PROJECT_DIR
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
    curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --retry 2 --retry-delay 2 --proxy "$CLASH_DOWNLOAD_PROXY" "$@"
  else
    env \
      -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" --retry 2 --retry-delay 2 --proxy "" --noproxy "*" "$@"
  fi
}

download_with_mirror() {
  local url="$1"
  local output="$2"
  local label="$3"
  local mirror_url

  echo "下载${label}: $url"
  if curl_direct -fL "$url" -o "$output"; then
    return 0
  fi

  mirror_url="${CLASH_GITHUB_MIRROR:-$DEFAULT_GITHUB_MIRROR}$url"
  echo "${label}官方下载失败，尝试镜像: $mirror_url" >&2
  curl_direct -fL "$mirror_url" -o "$output"
}

detect_asset_keyword() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os:$arch" in
    Linux:x86_64|Linux:amd64)
      echo "linux-amd64"
      ;;
    Linux:aarch64|Linux:arm64)
      echo "linux-arm64"
      ;;
    Linux:armv7l|Linux:armv7)
      echo "linux-armv7"
      ;;
    *)
      echo "Unsupported platform: $os $arch" >&2
      exit 1
      ;;
  esac
}

fetch_latest_asset_url() {
  local keyword="$1"
  local release_json

  if ! release_json="$(curl_direct -fsSL "$GITHUB_API")"; then
    echo "无法获取 Mihomo 最新版本信息。" >&2
    echo "如果服务器无法直连 GitHub，请使用:" >&2
    echo "  CLASH_DOWNLOAD_PROXY=http://代理地址:端口 ./install.sh '<订阅链接>'" >&2
    exit 1
  fi

  printf '%s\n' "$release_json" |
    awk -v keyword="$keyword" '
      /"browser_download_url":/ {
        gsub(/[",]/, "", $2)
        if (!found && $2 ~ keyword && $2 ~ /\.gz$/ && $2 !~ /compatible/) {
          print $2
          found = 1
        }
      }
    '
}

install_core() {
  local keyword asset_url archive

  keyword="$(detect_asset_keyword)"
  echo "当前平台: $keyword"

  if [[ -n "${CLASH_CORE_URL:-}" ]]; then
    asset_url="$CLASH_CORE_URL"
    echo "使用指定内核下载地址。"
  else
    echo "获取 Mihomo 最新版本信息..."
    asset_url="$(fetch_latest_asset_url "$keyword")"
  fi

  if [[ -z "$asset_url" ]]; then
    echo "Could not find a release asset for $keyword." >&2
    exit 1
  fi

  archive="$TMP_ARCHIVE"
  if ! download_with_mirror "$asset_url" "$archive" "Mihomo 内核"; then
    echo "Mihomo 内核下载失败。" >&2
    echo "如果服务器需要通过代理访问 GitHub，请使用:" >&2
    echo "  CLASH_DOWNLOAD_PROXY=http://代理地址:端口 ./install.sh '<订阅链接>'" >&2
    echo "也可以手动指定内核下载地址:" >&2
    echo "  CLASH_CORE_URL=https://.../mihomo-linux-amd64-xxx.gz ./install.sh '<订阅链接>'" >&2
    exit 1
  fi

  rm -f "$CORE_BIN"
  gzip -dc "$archive" > "$CORE_BIN"
  rm -f "$archive"
  chmod +x "$CORE_BIN"

  echo "内核已安装:"
  "$CORE_BIN" -v | head -n 1 || true
}

install_geodata() {
  echo "下载运行所需 Geo 数据..."

  if ! download_with_mirror "$GEOIP_URL" "$PROJECT_DIR/geoip.metadb" "GeoIP 数据"; then
    echo "GeoIP 数据下载失败。" >&2
    exit 1
  fi

  if ! download_with_mirror "$GEOSITE_URL" "$PROJECT_DIR/geosite.dat" "GeoSite 数据"; then
    echo "GeoSite 数据下载失败。" >&2
    exit 1
  fi
}

main() {
  local subscription_url=""
  local no_start=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --no-start)
        no_start=1
        shift
        ;;
      *)
        if [[ -n "$subscription_url" ]]; then
          echo "多余参数: $1" >&2
          usage
          exit 1
        fi
        subscription_url="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$subscription_url" ]]; then
    echo "必须提供订阅链接。" >&2
    usage
    exit 1
  fi

  need_cmd curl
  need_cmd awk
  need_cmd gzip

  printf '%s\n' "$subscription_url" > "$SUB_FILE"
  chmod 600 "$SUB_FILE"

  install_core
  install_geodata
  "$PROJECT_DIR/update-config.sh" "$subscription_url"

  if [[ "$no_start" -eq 0 ]]; then
    "$PROJECT_DIR/start.sh"
  else
    echo "安装完成。稍后可启动:"
    echo "  $PROJECT_DIR/start.sh"
  fi
}

main "$@"
