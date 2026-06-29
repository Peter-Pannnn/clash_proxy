# Clash/Mihomo 服务器代理脚本

一个用于在 Linux 服务器上快速部署 Mihomo/Clash TUN 代理的轻量脚本项目。它提供核心下载、TUN 权限配置、订阅更新、代理启动和按国家/地区交互选择节点等功能，并默认忽略二进制、订阅配置和运行缓存等本地文件。

普通代理不需要 root；TUN 模式需要 root。所有脚本默认围绕当前仓库目录工作，适合直接放在 `~/clash` 下使用。

## 功能概览

| 功能 | 脚本 | 说明 |
| --- | --- | --- |
| 一键安装 | `install.sh` | 下载 Mihomo 核心、拉取订阅、生成配置并启动 |
| 更新订阅 | `update-config.sh` | 使用已有订阅或新订阅重新生成普通/TUN 配置 |
| 普通代理 | `start.sh` | 启动本机 HTTP/SOCKS 代理 |
| TUN 模式 | `start-tun.sh` | 以 root 启动透明代理/TUN 模式 |
| 停止/重启 | `stop.sh` / `restart.sh` | 管理正在运行的代理进程 |
| 状态查看 | `status.sh` | 查看进程状态和最近日志 |
| 节点选择 | `select-node.sh` | 按国家/地区筛选节点、测速并切换 |
| 清理文件 | `clean.sh` | 停止代理并删除下载、缓存和运行产物 |

## 快速开始

```bash
cd ~/clash
./install.sh '你的订阅链接'
```

安装完成后，普通代理默认监听本机 `7890` 端口：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
curl -I -x http://127.0.0.1:7890 https://www.google.com
```

只安装和更新配置，不立即启动：

```bash
./install.sh '你的订阅链接' --no-start
```

## 常用命令

| 操作 | 命令 |
| --- | --- |
| 启动普通代理 | `./start.sh` |
| 停止代理 | `./stop.sh` |
| 重启代理 | `./restart.sh` |
| 查看状态 | `./status.sh` |
| 更新普通/TUN 配置 | `./update-config.sh` |
| 启动 TUN 模式 | `sudo ./start-tun.sh` |
| 测试 TUN 联网 | `curl -I https://www.google.com` |
| 取消当前 shell 代理环境变量 | `unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY` |

如果代理是用 TUN/root 模式启动的，停止时建议使用：

```bash
sudo ./stop.sh
```

## Codex 插件代理

在 VS Code Remote SSH 中使用 Codex 插件时，通常不需要开启 TUN。先启动普通代理：

```bash
cd ~/clash
./start.sh
```

然后在 `~/.codex/.env` 中写入代理环境变量：

```env
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=http://127.0.0.1:7890
NO_PROXY=localhost,127.0.0.1
```

保存后重启 Codex 插件或重连 VS Code Remote SSH。这样只有 Codex 进程走本机普通代理，服务器其他流量不会被透明代理接管。

## 更新订阅

使用已保存的订阅链接：

```bash
./update-config.sh
./restart.sh
```

`update-config.sh` 会同时生成两份配置：`config.yaml` 用于普通代理，`config-tun.yaml` 用于 TUN 模式。普通启动不会读取 TUN 配置，TUN 启动也不会复用普通配置。

更换订阅链接：

```bash
./update-config.sh '新的订阅链接'
./restart.sh
```

## 节点选择

交互式按国家/地区选择节点，并测试延迟：

```bash
./select-node.sh
```

常见用法：

```bash
./select-node.sh --list
./select-node.sh --country 日本
./select-node.sh --country 日本 --fastest
./select-node.sh --country 美国 --test-only
./select-node.sh --country 日本 --timeout 8000 --concurrency 4
```

参数含义：

| 参数 | 说明 |
| --- | --- |
| `--list` | 只列出可选国家/地区 |
| `--country <地区>` | 指定国家/地区测速或选择 |
| `--fastest` | 自动选择指定地区里延迟最低的节点 |
| `--test-only` | 只测速，不切换节点 |
| `--timeout <毫秒>` | 调整单个节点测速超时 |
| `--concurrency <数量>` | 调整并发测速数量 |

## 清理

停止代理并清除下载/运行生成的文件，保留脚本和 README：

```bash
./clean.sh
```

如果代理是用 TUN/root 启动的：

```bash
sudo ./clean.sh
```

不询问确认：

```bash
./clean.sh -y
```

清理脚本只删除下载和运行生成的文件，不会删除仓库脚本。
