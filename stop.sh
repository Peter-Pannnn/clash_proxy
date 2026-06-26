#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$PROJECT_DIR/clash.pid"

collect_pids() {
  {
    if [[ -s "$PID_FILE" ]]; then
      cat "$PID_FILE"
    fi
    pgrep -f "$PROJECT_DIR/clash -d $PROJECT_DIR -f $PROJECT_DIR/config.yaml" || true
    pgrep -f "$PROJECT_DIR/clash -d $PROJECT_DIR -f $PROJECT_DIR/config-tun.yaml" || true
  } | awk '/^[0-9]+$/ && !seen[$1]++ { print $1 }'
}

process_exists() {
  local pid="$1"
  ps -p "$pid" >/dev/null 2>&1
}

stop_pid() {
  local pid="$1"
  if ! process_exists "$pid"; then
    return 0
  fi

  if ! kill "$pid" >/dev/null 2>&1; then
    echo "无法停止 PID $pid，可能是 root/TUN 进程，请使用: sudo $PROJECT_DIR/stop.sh" >&2
    return 1
  fi

  for _ in $(seq 1 20); do
    if ! process_exists "$pid"; then
      return 0
    fi
    sleep 0.2
  done

  if process_exists "$pid"; then
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
}

pids="$(collect_pids)"

if [[ -z "$pids" ]]; then
  rm -f "$PID_FILE"
  echo "Clash 未运行。"
  exit 0
fi

failed=0
for pid in $pids; do
  stop_pid "$pid" || failed=1
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

rm -f "$PID_FILE"
echo "Clash 已停止。"
