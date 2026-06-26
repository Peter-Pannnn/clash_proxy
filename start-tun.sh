#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_BIN="$PROJECT_DIR/clash"
CONFIG_FILE="$PROJECT_DIR/config-tun.yaml"
PID_FILE="$PROJECT_DIR/clash.pid"
LOG_FILE="$PROJECT_DIR/clash.log"

if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "TUN 模式需要 root 权限，但系统未找到 sudo。" >&2
    exit 1
  fi
  exec sudo -E "$0" "$@"
fi

tun_enabled() {
  awk '
    /^tun:[[:space:]]*$/ { in_tun = 1; next }
    /^[^[:space:]]/ { in_tun = 0 }
    in_tun && /^[[:space:]]+enable:[[:space:]]*true[[:space:]]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$CONFIG_FILE"
}

ensure_tun_device() {
  if [[ -c /dev/net/tun ]]; then
    return 0
  fi

  modprobe tun >/dev/null 2>&1 || true
  mkdir -p /dev/net

  if [[ ! -c /dev/net/tun ]]; then
    mknod /dev/net/tun c 10 200
  fi

  chmod 666 /dev/net/tun
}

is_running() {
  [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1
}

started_successfully() {
  is_running && grep -q "Mixed(http+socks) proxy listening at" "$LOG_FILE" 2>/dev/null
}

if [[ ! -x "$CORE_BIN" ]]; then
  echo "找不到 Clash 内核: $CORE_BIN" >&2
  exit 1
fi

if [[ ! -s "$CONFIG_FILE" ]]; then
  echo "找不到 TUN 配置文件: $CONFIG_FILE" >&2
  echo "请先运行: $PROJECT_DIR/update-config.sh" >&2
  exit 1
fi

if ! tun_enabled; then
  echo "当前 config-tun.yaml 未开启 TUN。" >&2
  echo "请先运行: $PROJECT_DIR/update-config.sh" >&2
  exit 1
fi

ensure_tun_device
"$PROJECT_DIR/stop.sh" >/dev/null 2>&1 || true

echo "检查配置..."
"$CORE_BIN" -t -d "$PROJECT_DIR" -f "$CONFIG_FILE"

echo "以 TUN 模式启动 Clash..."
setsid "$CORE_BIN" -d "$PROJECT_DIR" -f "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
echo "$!" > "$PID_FILE"

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  chown "$SUDO_UID:$SUDO_GID" "$PID_FILE" "$LOG_FILE" 2>/dev/null || true
fi

for _ in $(seq 1 20); do
  if started_successfully; then
    echo "Clash TUN 已启动，PID: $(cat "$PID_FILE")"
    echo "日志: $LOG_FILE"
    exit 0
  fi
  sleep 0.5
done

echo "Clash TUN 启动失败，最近日志:" >&2
tail -n 60 "$LOG_FILE" >&2 || true
rm -f "$PID_FILE"
exit 1
