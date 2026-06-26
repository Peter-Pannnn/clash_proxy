#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$PROJECT_DIR/config.yaml"

if ! command -v python3 >/dev/null 2>&1; then
  echo "未找到 python3，无法运行节点选择脚本。" >&2
  exit 1
fi

python3 - "$PROJECT_DIR" "$CONFIG_FILE" "$@" <<'PY'
import argparse
import concurrent.futures
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT_DIR, CONFIG_FILE = sys.argv[1], sys.argv[2]


def env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


parser = argparse.ArgumentParser(
    prog="./select-node.sh",
    description="按国家/地区分类选择 Mihomo 节点，并测试节点延迟。"
)
parser.add_argument("-c", "--country", help="指定国家/地区，例如: 日本、美国、新加坡")
parser.add_argument("-g", "--group", default=os.environ.get("CLASH_GROUP"), help="指定要切换的策略组")
parser.add_argument("--list", action="store_true", help="只列出国家/地区分类，不切换节点")
parser.add_argument("--test-only", action="store_true", help="只测速，不切换节点")
parser.add_argument("--fastest", action="store_true", help="测速后自动选择延迟最低的节点")
parser.add_argument(
    "--url",
    default=os.environ.get("CLASH_TEST_URL", "http://www.gstatic.com/generate_204"),
    help="测速 URL，默认使用 Google 204 测试地址",
)
parser.add_argument(
    "--timeout",
    type=int,
    default=env_int("CLASH_TEST_TIMEOUT", 5000),
    help="单个节点测速超时时间，单位毫秒，默认 5000",
)
parser.add_argument(
    "--concurrency",
    type=int,
    default=env_int("CLASH_TEST_CONCURRENCY", 8),
    help="并发测速数量，默认 8",
)
args = parser.parse_args(sys.argv[3:])


def read_config():
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        print(f"找不到配置文件: {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)


def read_top_value(text, key):
    pattern = re.compile(rf"^{re.escape(key)}:\s*(.*?)\s*$", re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return ""
    value = match.group(1).split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    return value


def normalize_controller(value):
    value = (value or "127.0.0.1:9090").strip()
    if value.startswith(":"):
        value = "127.0.0.1" + value
    if "://" not in value:
        value = "http://" + value
    return value.rstrip("/")


config_text = read_config()
controller = normalize_controller(
    os.environ.get("CLASH_CONTROLLER") or read_top_value(config_text, "external-controller")
)
secret = os.environ.get("CLASH_SECRET") or read_top_value(config_text, "secret")


class ApiError(RuntimeError):
    pass


def api(method, path, data=None, expect_json=True, timeout_seconds=None):
    body = None
    headers = {}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    if data is not None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(
        controller + path,
        data=body,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=timeout_seconds or max(5, args.timeout / 1000 + 5),
        ) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "ignore")
        raise ApiError(f"HTTP {exc.code}: {detail or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise ApiError(str(exc.reason)) from exc
    except TimeoutError as exc:
        raise ApiError("请求超时") from exc

    if not expect_json:
        return None
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


def load_proxies():
    try:
        result = api("GET", "/proxies")
    except ApiError as exc:
        print(f"无法连接 Mihomo 控制接口: {controller}", file=sys.stderr)
        print(f"原因: {exc}", file=sys.stderr)
        print("请先启动 Clash: ./start.sh 或 sudo ./start-tun.sh", file=sys.stderr)
        sys.exit(1)

    proxies = result.get("proxies") if isinstance(result, dict) else None
    if not isinstance(proxies, dict):
        print("控制接口返回异常，未找到 proxies 数据。", file=sys.stderr)
        sys.exit(1)
    return proxies


def is_group(info):
    return isinstance(info, dict) and isinstance(info.get("all"), list)


def choose_group(proxies):
    preferred = [args.group, "🚀 节点选择", "GLOBAL", "Proxy", "PROXY"]
    for name in preferred:
        if name and name in proxies and is_group(proxies[name]):
            return name

    for name, info in proxies.items():
        if is_group(info) and str(info.get("type", "")).lower() in ("selector", "select"):
            return name

    for name, info in proxies.items():
        if is_group(info):
            return name

    print("未找到可切换的策略组。", file=sys.stderr)
    sys.exit(1)


SPECIAL_PROXIES = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL"}
GROUP_TYPES = {"selector", "select", "urltest", "url-test", "fallback", "loadbalance", "load-balance", "relay"}


def selectable_nodes(proxies, group_name):
    group = proxies[group_name]
    nodes = []
    for name in group.get("all", []):
        info = proxies.get(name, {})
        proxy_type = str(info.get("type", "")).lower() if isinstance(info, dict) else ""
        if name in SPECIAL_PROXIES:
            continue
        if is_group(info) or proxy_type in GROUP_TYPES:
            continue
        nodes.append(name)
    return nodes


COUNTRY_BY_CODE = {
    "AE": "阿联酋",
    "AU": "澳大利亚",
    "BR": "巴西",
    "CA": "加拿大",
    "CH": "瑞士",
    "DE": "德国",
    "FR": "法国",
    "GB": "英国",
    "HK": "香港",
    "IN": "印度",
    "JP": "日本",
    "KR": "韩国",
    "MO": "澳门",
    "MY": "马来西亚",
    "NL": "荷兰",
    "PH": "菲律宾",
    "RU": "俄罗斯",
    "SG": "新加坡",
    "TH": "泰国",
    "TR": "土耳其",
    "TW": "台湾",
    "UK": "英国",
    "US": "美国",
    "VN": "越南",
}

KEYWORDS = [
    ("日本", ("日本", "东京", "大阪", "jp", "japan", "tokyo", "osaka")),
    ("新加坡", ("新加坡", "sg", "singapore")),
    ("美国", ("美国", "美國", "圣何塞", "洛杉矶", "阿什本", "us", "usa", "united states", "san jose", "los angeles", "ashburn")),
    ("韩国", ("韩国", "韓國", "首尔", "kr", "korea", "seoul")),
    ("台湾", ("台湾", "台灣", "tw", "taiwan")),
    ("香港", ("香港", "hk", "hong kong")),
    ("印度", ("印度", "in", "india")),
    ("澳大利亚", ("澳大利亚", "澳洲", "au", "australia")),
    ("瑞士", ("瑞士", "苏黎世", "ch", "switzerland", "zurich")),
    ("阿联酋", ("阿联酋", "迪拜", "dubai", "ae", "uae")),
    ("英国", ("英国", "英國", "伦敦", "gb", "uk", "united kingdom", "london")),
    ("德国", ("德国", "德國", "de", "germany")),
    ("法国", ("法国", "法國", "fr", "france")),
    ("加拿大", ("加拿大", "ca", "canada")),
]


def flag_country(name):
    chars = list(name)
    for index in range(len(chars) - 1):
        first = ord(chars[index])
        second = ord(chars[index + 1])
        if 0x1F1E6 <= first <= 0x1F1FF and 0x1F1E6 <= second <= 0x1F1FF:
            code = chr(first - 0x1F1E6 + ord("A")) + chr(second - 0x1F1E6 + ord("A"))
            return COUNTRY_BY_CODE.get(code, code)
    return ""


def detect_country(name):
    country = flag_country(name)
    if country:
        return country

    lower_name = name.lower()
    for country, patterns in KEYWORDS:
        for pattern in patterns:
            if pattern in name or pattern.lower() in lower_name:
                return country
    return "其他"


def build_country_groups(nodes):
    groups = {}
    for node in nodes:
        groups.setdefault(detect_country(node), []).append(node)
    return dict(sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])))


def find_country(groups, query):
    value = (query or "").strip().lower()
    if not value:
        return ""
    for country in groups:
        if value == country.lower():
            return country
    for country in groups:
        if value in country.lower() or country.lower() in value:
            return country
    for country, nodes in groups.items():
        if any(value in node.lower() for node in nodes):
            return country
    return ""


EXIT_CHOICES = {"0", "q", "quit", "exit", "退出"}
BACK_CHOICES = {"b", "back", "return", "返回", "上一步"}
BACK = "__back__"


def normalize_choice(value):
    return (value or "").strip().lower()


def is_exit_choice(value):
    return normalize_choice(value) in EXIT_CHOICES


def is_back_choice(value):
    return normalize_choice(value) in BACK_CHOICES


def exit_interactive():
    print("已退出。")
    sys.exit(0)


def read_line(prompt):
    try:
        with open("/dev/tty", "r", encoding="utf-8") as tty_in, open(
            "/dev/tty", "w", encoding="utf-8"
        ) as tty_out:
            tty_out.write(prompt)
            tty_out.flush()
            return tty_in.readline().strip()
    except OSError:
        print("当前环境没有可交互终端，请使用 --country 指定国家/地区。", file=sys.stderr)
        sys.exit(1)


def prompt_country(groups):
    countries = list(groups)
    while True:
        print("可用国家/地区:")
        for index, country in enumerate(countries, 1):
            print(f"  {index}. {country} ({len(groups[country])} 个)")
        print("  0. 退出")

        choice = read_line("请选择国家/地区编号或名称，输入 0/q 退出: ")
        if not choice or is_exit_choice(choice):
            exit_interactive()
        if choice.isdigit() and 1 <= int(choice) <= len(countries):
            return countries[int(choice) - 1]

        country = find_country(groups, choice)
        if country:
            return country

        print(f"未找到国家/地区: {choice}", file=sys.stderr)


def test_delay(node):
    encoded_node = urllib.parse.quote(node, safe="")
    encoded_url = urllib.parse.quote(args.url, safe="")
    path = f"/proxies/{encoded_node}/delay?timeout={args.timeout}&url={encoded_url}"
    try:
        result = api("GET", path, timeout_seconds=max(3, args.timeout / 1000 + 2))
        delay = result.get("delay") if isinstance(result, dict) else None
        if isinstance(delay, int) and delay >= 0:
            return {"name": node, "delay": delay, "error": ""}
        return {"name": node, "delay": None, "error": "无延迟数据"}
    except ApiError as exc:
        return {"name": node, "delay": None, "error": str(exc)}


def test_nodes(nodes):
    workers = max(1, min(args.concurrency, len(nodes)))
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        future_map = {executor.submit(test_delay, node): node for node in nodes}
        for future in concurrent.futures.as_completed(future_map):
            results.append(future.result())

    return sorted(
        results,
        key=lambda item: (
            item["delay"] is None,
            item["delay"] if item["delay"] is not None else 10**9,
            item["name"],
        ),
    )


def print_results(results):
    for index, item in enumerate(results, 1):
        if item["delay"] is None:
            delay_text = "失败"
        else:
            delay_text = f'{item["delay"]} ms'
        print(f"  {index:>2}. {delay_text:<8} {item['name']}")


def choose_node(results, allow_back=False):
    ok_results = [item for item in results if item["delay"] is not None]
    if args.fastest:
        if not ok_results:
            print("没有测速成功的节点，未切换。", file=sys.stderr)
            sys.exit(1)
        return ok_results[0]["name"]

    default_name = ok_results[0]["name"] if ok_results else results[0]["name"]
    if allow_back:
        print("   b. 返回国家/地区")
    print("   0. 退出")

    prompt = "请选择节点编号，直接回车使用延迟最低节点"
    if allow_back:
        prompt += "，输入 b 返回"
    prompt += "，输入 0/q 退出: "

    while True:
        choice = read_line(prompt)
        if not choice:
            return default_name
        if allow_back and is_back_choice(choice):
            return BACK
        if is_exit_choice(choice):
            exit_interactive()
        if choice.isdigit() and 1 <= int(choice) <= len(results):
            return results[int(choice) - 1]["name"]
        print(f"无效编号: {choice}", file=sys.stderr)


def switch_node(group_name, node_name):
    encoded_group = urllib.parse.quote(group_name, safe="")
    api("PUT", f"/proxies/{encoded_group}", {"name": node_name}, expect_json=False)


proxies = load_proxies()
group_name = choose_group(proxies)
nodes = selectable_nodes(proxies, group_name)
if not nodes:
    print(f"策略组 {group_name} 中没有可选择的节点。", file=sys.stderr)
    sys.exit(1)

groups = build_country_groups(nodes)
current = proxies.get(group_name, {}).get("now", "")
print(f"当前策略组: {group_name}")
if current:
    print(f"当前节点: {current}")

if args.list:
    print("国家/地区分类:")
    for country, country_nodes in groups.items():
        print(f"  {country}: {len(country_nodes)} 个")
    sys.exit(0)

def handle_country(country, allow_back=False):
    country_nodes = groups[country]
    print(f"正在测试 {country} 节点延迟，共 {len(country_nodes)} 个...")
    results = test_nodes(country_nodes)
    print_results(results)

    if args.test_only:
        return None

    selected = choose_node(results, allow_back=allow_back)
    if selected == BACK:
        return BACK

    switch_node(group_name, selected)
    print(f"已切换 {group_name} -> {selected}")
    return selected


if args.country:
    country = find_country(groups, args.country)
    if not country:
        print(f"未找到国家/地区: {args.country}", file=sys.stderr)
        sys.exit(1)
    handle_country(country)
    sys.exit(0)

while True:
    country = prompt_country(groups)
    result = handle_country(country, allow_back=True)
    if result == BACK:
        continue
    break
PY
