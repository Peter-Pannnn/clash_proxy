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
WGET_CONNECT_TIMEOUT="${CLASH_CONNECT_TIMEOUT:-15}"
WGET_READ_TIMEOUT="${CLASH_MAX_TIME:-120}"
DEFAULT_GITHUB_MIRROR="https://gh.llkk.cc/"

usage() {
  cat <<EOF
用法:
  ./install.sh '<订阅链接>' [--core <本地内核文件>] [--no-start]

示例:
  ./install.sh 'https://example.com/subscription'
  ./install.sh 'https://example.com/subscription' --core ./mihomo-linux-amd64
  ./install.sh 'https://example.com/subscription' --no-start

未指定 --core 时，会先在项目目录中查找 clash* 或 mihomo* 本地内核；
只有找不到可用的本地内核时才会下载。

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

wget_direct() {
  if [[ -n "${CLASH_DOWNLOAD_PROXY:-}" ]]; then
    env \
      http_proxy="$CLASH_DOWNLOAD_PROXY" https_proxy="$CLASH_DOWNLOAD_PROXY" \
      HTTP_PROXY="$CLASH_DOWNLOAD_PROXY" HTTPS_PROXY="$CLASH_DOWNLOAD_PROXY" \
      wget --connect-timeout="$WGET_CONNECT_TIMEOUT" --read-timeout="$WGET_READ_TIMEOUT" \
        --tries=3 --waitretry=2 --max-redirect=20 "$@"
  else
    env \
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
      wget --no-proxy --connect-timeout="$WGET_CONNECT_TIMEOUT" --read-timeout="$WGET_READ_TIMEOUT" \
        --tries=3 --waitretry=2 --max-redirect=20 "$@"
  fi
}

download_with_mirror() {
  local url="$1"
  local output="$2"
  local label="$3"
  local mirror_url

  echo "下载${label}: $url"
  if wget_direct -O "$output" "$url"; then
    return 0
  fi

  mirror_url="${CLASH_GITHUB_MIRROR:-$DEFAULT_GITHUB_MIRROR}$url"
  echo "${label}官方下载失败，尝试镜像: $mirror_url" >&2
  wget_direct -O "$output" "$mirror_url"
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

  if ! release_json="$(wget_direct -qO- "$GITHUB_API")"; then
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

core_version() {
  local core_file="$1"
  local version

  if ! version="$("$core_file" -v 2>&1)"; then
    return 1
  fi

  if ! grep -Eiq 'clash|mihomo' <<<"$version"; then
    return 1
  fi

  printf '%s\n' "$version" | head -n 1
}

install_local_core() {
  local source_file="$1"
  local source_dir source_abs staging version

  if [[ ! -f "$source_file" ]]; then
    echo "本地内核文件不存在: $source_file" >&2
    return 1
  fi

  source_dir="$(cd "$(dirname "$source_file")" && pwd)"
  source_abs="$source_dir/$(basename "$source_file")"

  if [[ "$source_abs" == "$CORE_BIN" ]]; then
    chmod +x "$CORE_BIN"
    if ! version="$(core_version "$CORE_BIN")"; then
      echo "文件不是可用的 Clash/Mihomo 内核: $source_file" >&2
      return 1
    fi
  else
    staging="$PROJECT_DIR/.clash.install.$$"
    rm -f "$staging"
    if ! cp -- "$source_abs" "$staging"; then
      rm -f "$staging"
      return 1
    fi
    chmod +x "$staging"

    if ! version="$(core_version "$staging")"; then
      echo "文件不是可用的 Clash/Mihomo 内核: $source_file" >&2
      rm -f "$staging"
      return 1
    fi

    mv -f "$staging" "$CORE_BIN"
  fi

  echo "已使用本地内核: $source_abs"
  echo "内核已安装: $version"
}

find_local_core() {
  local candidate
  local candidates=()

  if [[ -f "$CORE_BIN" ]]; then
    candidates+=("$CORE_BIN")
  fi

  shopt -s nullglob
  candidates+=(
    "$PROJECT_DIR"/mihomo
    "$PROJECT_DIR"/mihomo-*
    "$PROJECT_DIR"/mihomo_*
    "$PROJECT_DIR"/clash-*
    "$PROJECT_DIR"/clash_*
  )
  shopt -u nullglob

  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    case "$candidate" in
      *.gz|*.zip|*.tar|*.tgz|*.xz|*.bz2|*.download)
        continue
        ;;
    esac

    if install_local_core "$candidate"; then
      return 0
    fi
    echo "跳过无效的本地内核候选: $candidate" >&2
  done

  return 1
}

download_core() {
  local keyword asset_url archive staging version

  need_cmd awk
  need_cmd gzip

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

  staging="$PROJECT_DIR/.clash.install.$$"
  rm -f "$staging"
  if ! gzip -dc "$archive" > "$staging"; then
    rm -f "$archive" "$staging"
    echo "Mihomo 内核解压失败。" >&2
    exit 1
  fi
  rm -f "$archive"
  chmod +x "$staging"

  if ! version="$(core_version "$staging")"; then
    rm -f "$staging"
    echo "下载的文件不是可用的 Clash/Mihomo 内核。" >&2
    exit 1
  fi

  mv -f "$staging" "$CORE_BIN"

  echo "内核已安装: $version"
}

install_core() {
  local local_core="${1:-}"

  if [[ -n "$local_core" ]]; then
    echo "使用指定的本地内核。"
    if ! install_local_core "$local_core"; then
      exit 1
    fi
    return 0
  fi

  if [[ -n "${CLASH_CORE_URL:-}" ]]; then
    echo "已指定 CLASH_CORE_URL，将使用该地址下载内核。"
    download_core
    return 0
  fi

  echo "查找项目目录中的本地 Clash/Mihomo 内核..."
  if find_local_core; then
    return 0
  fi

  echo "未找到可用的本地内核，将下载 Mihomo。"
  download_core
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
  local local_core="${CLASH_CORE_FILE:-}"
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
      --core)
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "--core 需要提供本地内核文件路径。" >&2
          usage
          exit 1
        fi
        local_core="$2"
        shift 2
        ;;
      --core=*)
        local_core="${1#--core=}"
        if [[ -z "$local_core" ]]; then
          echo "--core 需要提供本地内核文件路径。" >&2
          usage
          exit 1
        fi
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

  need_cmd wget

  printf '%s\n' "$subscription_url" > "$SUB_FILE"
  chmod 600 "$SUB_FILE"

  install_core "$local_core"
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
