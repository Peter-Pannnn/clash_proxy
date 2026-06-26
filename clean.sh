#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$PROJECT_DIR/clash.pid"
ORIGINAL_ARGS=("$@")

YES=0

usage() {
  cat <<EOF
用法:
  ./clean.sh          停止代理，并清除下载/运行生成的文件，保留脚本和 README
  ./clean.sh -y       不询问确认

默认会删除:
  clash, config.yaml, geoip.metadb, geosite.dat, subscription.url,
  clash.pid, clash.log, cache.db 等安装和运行生成的文件。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

collect_pids() {
  {
    if [[ -s "$PID_FILE" ]]; then
      cat "$PID_FILE"
    fi
    pgrep -f "$PROJECT_DIR/clash -d $PROJECT_DIR -f $PROJECT_DIR/config.yaml" || true
  } | awk '/^[0-9]+$/ && !seen[$1]++ { print $1 }'
}

running_pids() {
  local pid
  collect_pids | while read -r pid; do
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "$pid"
    fi
  done
}

stop_pids() {
  local pids="$1"
  local pid
  [[ -n "$pids" ]] || return 0

  for pid in $pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done

  for _ in $(seq 1 20); do
    if [[ -z "$(running_pids)" ]]; then
      return 0
    fi
    sleep 0.2
  done

  for pid in $(running_pids); do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
}

echo "停止 Clash/Mihomo 进程..."
initial_pids="$(running_pids)"

if [[ -n "$initial_pids" && "$(id -u)" -ne 0 ]]; then
  stop_pids "$initial_pids"
  if [[ -n "$(running_pids)" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "检测到可能由 root 启动的 TUN 进程，切换到 sudo 清理..."
      exec sudo -E "$0" "${ORIGINAL_ARGS[@]}"
    fi
    echo "仍有进程无法停止，请使用 sudo ./clean.sh" >&2
    exit 1
  fi
else
  stop_pids "$initial_pids"
fi

rm -f "$PID_FILE"

echo "清除下载和运行生成的文件..."

targets=(
  "$PROJECT_DIR/clash"
  "$PROJECT_DIR/config.yaml"
  "$PROJECT_DIR/config.yaml.download"
  "$PROJECT_DIR/geoip.metadb"
  "$PROJECT_DIR/geosite.dat"
  "$PROJECT_DIR/subscription.url"
  "$PROJECT_DIR/clash.pid"
  "$PROJECT_DIR/clash.log"
  "$PROJECT_DIR/cache.db"
  "$PROJECT_DIR/cache.db-shm"
  "$PROJECT_DIR/cache.db-wal"
  "$PROJECT_DIR/Country.mmdb"
)

for path in "${targets[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    rm -f -- "$path"
    echo "已删除: $path"
  fi
done

for path in "$PROJECT_DIR"/mihomo-* "$PROJECT_DIR"/*.gz "$PROJECT_DIR"/*.download; do
  if [[ -e "$path" || -L "$path" ]]; then
    rm -f -- "$path"
    echo "已删除: $path"
  fi
done

echo "清理完成。脚本和 README 已保留，可重新运行 ./install.sh 安装。"
