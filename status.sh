#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$PROJECT_DIR/clash.pid"
LOG_FILE="$PROJECT_DIR/clash.log"

collect_pids() {
  {
    if [[ -s "$PID_FILE" ]]; then
      cat "$PID_FILE"
    fi
    pgrep -f "$PROJECT_DIR/clash -d $PROJECT_DIR -f $PROJECT_DIR/config.yaml" || true
  } | awk '/^[0-9]+$/ && !seen[$1]++ { print $1 }'
}

process_exists() {
  local pid="$1"
  ps -p "$pid" >/dev/null 2>&1
}

listening_ports() {
  ss -ltn 2>/dev/null | awk '
    $4 ~ /127\.0\.0\.1:7890$/ || $4 ~ /127\.0\.0\.1:9090$/ || $4 ~ /198\.18\.0\.1:/ {
      print $4
    }
  ' | sort -u
}

pids="$(collect_pids)"
running_pids=""

for pid in $pids; do
  if process_exists "$pid"; then
    running_pids="${running_pids}${running_pids:+ }$pid"
  fi
done

if [[ -n "$running_pids" ]]; then
  echo "Clash 正在运行，PID: $running_pids"
  if [[ ! -s "$PID_FILE" ]]; then
    first_pid="${running_pids%% *}"
    echo "$first_pid" > "$PID_FILE" 2>/dev/null || true
  fi
else
  ports="$(listening_ports)"
  if [[ -n "$ports" ]]; then
    echo "Clash 可能正在运行，但当前用户未找到进程 PID。"
    echo "检测到监听端口:"
    echo "$ports"
    echo "如需停止 TUN/root 进程，请使用: sudo $PROJECT_DIR/stop.sh"
  else
    echo "Clash 未运行。"
    rm -f "$PID_FILE"
  fi
fi

if [[ -f "$LOG_FILE" ]]; then
  echo
  echo "最近日志:"
  tail -n 20 "$LOG_FILE"
fi
