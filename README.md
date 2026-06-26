# Clash 代理脚本

本目录用于在 `~/clash` 下安装、启动和管理 Clash/Mihomo 代理。普通代理不需要 root；TUN 模式需要 root。

## 脚本说明

```text
install.sh         一键安装、拉取订阅并启动
update-config.sh   更新订阅配置
start.sh           启动普通代理
start-tun.sh       启动 TUN 模式
stop.sh            停止代理
restart.sh         重启代理
status.sh          查看运行状态和最近日志
select-node.sh     按国家/地区选择节点并测速
clean.sh           停止代理并清除下载/运行生成的文件
```

## 安装和启动

```bash
cd ~/clash
./install.sh '你的订阅链接'
```

只安装和更新配置，不立即启动：

```bash
./install.sh '你的订阅链接' --no-start
```

启动、停止、重启：

```bash
./start.sh
./stop.sh
./restart.sh
```

查看状态：

```bash
./status.sh
```

如果使用 TUN/root 启动，停止时建议使用：

```bash
sudo ./stop.sh
```

## 更新订阅

使用已保存的订阅链接：

```bash
./update-config.sh
./restart.sh
```

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

只列出可选国家/地区：

```bash
./select-node.sh --list
```

指定国家/地区测速：

```bash
./select-node.sh --country 日本
```

自动选择指定国家/地区里延迟最低的节点：

```bash
./select-node.sh --country 日本 --fastest
```

只测速，不切换节点：

```bash
./select-node.sh --country 美国 --test-only
```


调整测速超时和并发数：

```bash
./select-node.sh --country 日本 --timeout 8000 --concurrency 4
```

## TUN 模式

生成 TUN 配置并启动：

```bash
cd ~/clash
CLASH_TUN=1 ./update-config.sh
sudo ./start-tun.sh
```

查看状态：

```bash
./status.sh
```

TUN 模式下测试联网不需要指定代理端口：

```bash
curl -I https://www.google.com
```

关闭 TUN：

```bash
sudo ./stop.sh
```

## 使用和测试

普通代理默认使用本机 `7890` 端口：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
```

测试是否能连接 Google：

```bash
curl -I -x http://127.0.0.1:7890 https://www.google.com
```

取消当前 shell 的代理环境变量：

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
```

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

清理脚本只删除下载和运行生成的文件