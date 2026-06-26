#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_BIN="$PROJECT_DIR/clash"
CONFIG_FILE="$PROJECT_DIR/config.yaml"
PID_FILE="$PROJECT_DIR/clash.pid"
LOG_FILE="$PROJECT_DIR/clash.log"

is_running() {
  [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1
}

started_successfully() {
  is_running && grep -q "Mixed(http+socks) proxy listening at" "$LOG_FILE" 2>/dev/null
}

tun_enabled() {
  awk '
    /^tun:[[:space:]]*$/ { in_tun = 1; next }
    /^[^[:space:]]/ { in_tun = 0 }
    in_tun && /^[[:space:]]+enable:[[:space:]]*true[[:space:]]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$CONFIG_FILE"
}

start_background() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$CORE_BIN" -d "$PROJECT_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
  else
    nohup "$CORE_BIN" -d "$PROJECT_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
  fi
}

main() {
  if [[ ! -x "$CORE_BIN" ]]; then
    echo "找不到 Clash 内核: $CORE_BIN" >&2
    echo "请先运行 ./install.sh '<订阅链接>'。" >&2
    exit 1
  fi

  if [[ ! -s "$CONFIG_FILE" ]]; then
    echo "找不到配置文件: $CONFIG_FILE" >&2
    echo "请先运行 ./update-config.sh '<订阅链接>'。" >&2
    exit 1
  fi

  if tun_enabled && [[ "$(id -u)" -ne 0 ]]; then
    echo "当前配置已开启 TUN，需要管理员权限启动。" >&2
    echo "请使用: sudo $PROJECT_DIR/start-tun.sh" >&2
    exit 1
  fi

  if is_running; then
    echo "Clash 已在运行，PID: $(cat "$PID_FILE")"
    exit 0
  fi

  echo "检查配置..."
  "$CORE_BIN" -t -d "$PROJECT_DIR" -f "$CONFIG_FILE"

  echo "启动 Clash..."
  start_background
  echo "$!" > "$PID_FILE"

  for _ in $(seq 1 10); do
    if started_successfully; then
      break
    fi
    sleep 0.5
  done

  if started_successfully; then
    echo "Clash 已启动，PID: $(cat "$PID_FILE")"
    echo "日志: $LOG_FILE"
  else
    echo "Clash 启动失败，最近日志:" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 1
  fi
}

main "$@"
