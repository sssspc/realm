#!/usr/bin/env bash
# Realm relay manager for Debian / Ubuntu (systemd)
# Version: 2.0.1
set -Eeuo pipefail

SCRIPT_VERSION="2.0.1"
SCRIPT_URL="https://raw.githubusercontent.com/sssspc/realm/main/realm.sh"
REALM_REPO="zhboner/realm"
REALM_DIR="/opt/realm"
STATE_DIR="/opt/.realm"
CONFIG_PATH="${STATE_DIR}/config.toml"
BACKUP_DIR="${STATE_DIR}/backups"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_BIN="${REALM_DIR}/realm"
TMP_DIR=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; RESET='\033[0m'

msg()  { printf '%b\n' "$*"; }
ok()   { msg "${GREEN}[成功]${RESET} $*"; }
warn() { msg "${YELLOW}[提示]${RESET} $*"; }
err()  { msg "${RED}[错误]${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() { [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
trap 'err "脚本在第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

require_root() { [[ ${EUID} -eq 0 ]] || die "请使用 root 或 sudo 运行此脚本。"; }

check_platform() {
    [[ -r /etc/os-release ]] || die "无法识别系统类型。"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in debian|ubuntu) ;; *) warn "当前系统为 ${PRETTY_NAME:-未知系统}；本脚本主要面向 Debian / Ubuntu。" ;; esac
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd/systemctl，本脚本不支持当前服务管理环境。"
    systemctl is-system-running >/dev/null 2>&1 || {
        local state
        state=$(systemctl is-system-running 2>/dev/null || true)
        [[ "$state" == "degraded" ]] || warn "systemd 当前状态：${state:-unknown}，请确认服务管理正常。"
    }
}

check_dependencies() {
    local missing=() p
    for p in curl tar awk sed grep install id useradd getent; do
        command -v "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if ((${#missing[@]})); then
        apt-get update
        # systemd / id / awk 等通常由基础系统提供；仅安装常用下载和归档工具
        apt-get install -y curl tar gawk sed grep coreutils passwd
    fi
    for p in curl tar awk sed grep install id useradd getent; do
        command -v "$p" >/dev/null 2>&1 || die "缺少必要命令：$p"
    done
}

init_env() {
    install -d -m 0755 "$REALM_DIR"
    install -d -m 0750 -o root -g realm "$STATE_DIR" 2>/dev/null || install -d -m 0750 "$STATE_DIR"
    install -d -m 0700 "$BACKUP_DIR"
}

ensure_realm_user() {
    if ! getent group realm >/dev/null 2>&1; then groupadd --system realm; fi
    if ! id realm >/dev/null 2>&1; then
        useradd --system --gid realm --home-dir /nonexistent --shell /usr/sbin/nologin realm
    fi
    chown root:realm "$STATE_DIR"
    chmod 0750 "$STATE_DIR"
    if [[ -f "$CONFIG_PATH" ]]; then chown root:realm "$CONFIG_PATH"; chmod 0640 "$CONFIG_PATH"; fi
}

backup_config() {
    [[ -f "$CONFIG_PATH" ]] || return 0
    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    cp -a -- "$CONFIG_PATH" "${BACKUP_DIR}/config_${stamp}.toml"
    chmod 0600 "${BACKUP_DIR}/config_${stamp}.toml"
}

atomic_write_config() {
    local candidate="$1"
    [[ -s "$candidate" ]] || die "拒绝写入空配置文件。"
    # Python 3.11+ 可用 tomllib 做 TOML 语法校验；若没有则保留基本格式校验。
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$candidate" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit(0)
with open(sys.argv[1], 'rb') as f:
    tomllib.load(f)
PY
    fi
    backup_config
    local tmp="${CONFIG_PATH}.tmp.$$"
    install -o root -g realm -m 0640 "$candidate" "$tmp"
    mv -f -- "$tmp" "$CONFIG_PATH"
    chown root:realm "$CONFIG_PATH"
    chmod 0640 "$CONFIG_PATH"
}

ensure_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        cat >"$CONFIG_PATH" <<'TOML'
[network]
no_tcp = false
use_udp = true
zero_copy = true
fast_open = true
tcp_timeout = 300
udp_timeout = 30
send_proxy = false
send_proxy_version = 2
accept_proxy = false
accept_proxy_timeout = 5
TOML
        chown root:realm "$CONFIG_PATH" 2>/dev/null || true
        chmod 0640 "$CONFIG_PATH"
    fi
}

get_latest_version() {
    local json version
    json=$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/${REALM_REPO}/releases/latest") || return 1
    version=$(printf '%s' "$json" | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

get_asset_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        armv7l|armv7*) printf 'armv7' ;;
        armv6l) printf 'arm' ;;
        *) return 1 ;;
    esac
}

asset_url_for() {
    local version="$1" arch="$2" suffix
    case "$arch" in
        x86_64) suffix="x86_64-unknown-linux-gnu" ;;
        aarch64) suffix="aarch64-unknown-linux-gnu" ;;
        armv7) suffix="armv7-unknown-linux-gnueabi" ;;
        arm) suffix="arm-unknown-linux-gnueabi" ;;
        *) return 1 ;;
    esac
    printf 'https://github.com/%s/releases/download/%s/realm-%s.tar.gz' "$REALM_REPO" "$version" "$suffix"
}

fetch_realm_binary() {
    local version="$1" arch="$2" url archive extract_dir binary
    url=$(asset_url_for "$version" "$arch") || die "不支持的架构：$arch"
    [[ -n "${TMP_DIR:-}" ]] || TMP_DIR=$(mktemp -d /tmp/realm-install.XXXXXX)
    archive="${TMP_DIR}/realm.tar.gz"
    extract_dir="${TMP_DIR}/extract"
    mkdir -p "$extract_dir"
    msg "下载 Realm ${version}（${arch}）..." >&2
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "$url" -o "$archive" || die "Realm 下载失败，旧版本未受影响。"
    tar -tzf "$archive" >/dev/null 2>&1 || die "下载文件不是有效的 gzip tar 压缩包。"
    tar -xzf "$archive" -C "$extract_dir" || die "Realm 压缩包解压失败。"
    binary=$(find "$extract_dir" -type f -name realm -perm /111 -print -quit)
    [[ -n "$binary" ]] || binary=$(find "$extract_dir" -type f -name realm -print -quit)
    [[ -n "$binary" ]] || die "压缩包中没有找到 realm 可执行文件。"
    chmod 0755 "$binary"
    "$binary" --version >/dev/null 2>&1 || die "下载的 Realm 二进制文件无法正常执行，取消替换。"
    FETCHED_BINARY="$binary"
}

install_service() {
    ensure_realm_user
    cat >"${SERVICE_FILE}.tmp" <<EOF_SERVICE
[Unit]
Description=Realm TCP/UDP Relay
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=realm
Group=realm
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CONFIG_PATH}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    install -o root -g root -m 0644 "${SERVICE_FILE}.tmp" "$SERVICE_FILE"
    rm -f "${SERVICE_FILE}.tmp"
    systemctl daemon-reload
}

service_installed() { [[ -x "$REALM_BIN" ]]; }
service_active() { systemctl is-active --quiet realm.service; }

restart_realm_checked() {
    systemctl daemon-reload
    if ! systemctl restart realm.service; then
        err "Realm 重启命令执行失败，最近日志如下："
        systemctl status realm.service --no-pager -l || true
        journalctl -u realm.service -n 60 --no-pager || true
        return 1
    fi

    # Realm 服务设置了 Restart=on-failure，给 systemd 一点时间完成启动或重试。
    local attempt
    for ((attempt=1; attempt<=10; attempt++)); do
        if service_active; then
            ok "Realm 服务运行正常。"
            return 0
        fi
        sleep 1
    done

    err "等待 10 秒后服务仍未处于 active 状态，最近日志如下："
    systemctl status realm.service --no-pager -l || true
    journalctl -u realm.service -n 60 --no-pager || true
    return 1
}

rollback_realm() {
    local backup="$1" rollback_tmp="${REALM_BIN}.rollback.$$"
    [[ -s "$backup" ]] || { err "旧版本备份不存在或为空，无法自动回滚：$backup"; return 1; }

    err "新版本启动失败，正在恢复旧版本……"
    if ! install -o root -g root -m 0755 "$backup" "$rollback_tmp"; then
        rm -f "$rollback_tmp"
        err "复制旧版本失败，未能完成回滚。"
        return 1
    fi
    if ! mv -f -- "$rollback_tmp" "$REALM_BIN"; then
        rm -f "$rollback_tmp"
        err "替换旧版本二进制失败，未能完成回滚。"
        return 1
    fi

    if restart_realm_checked; then
        ok "已自动回滚到旧版本并成功重启 Realm。"
        return 0
    fi

    err "旧版本二进制已恢复，但服务仍未能启动。请检查上方日志；备份文件保留在：$backup"
    return 1
}

install_or_update_realm() {
    local version arch binary staged old_version backup_file="" was_active=0 was_enabled=0
    version=$(get_latest_version) || die "获取 GitHub 最新版本失败，请检查网络或 API 限制。"
    arch=$(get_asset_arch) || die "不支持的 CPU 架构：$(uname -m)"
    msg "最新 Realm 版本：${version}；系统架构：${arch}"
    TMP_DIR=$(mktemp -d /tmp/realm-install.XXXXXX)
    fetch_realm_binary "$version" "$arch"
    binary="$FETCHED_BINARY"
    staged="${REALM_DIR}/realm.new.$$"
    install -o root -g root -m 0755 "$binary" "$staged"
    "$staged" --version >/dev/null 2>&1 || { rm -f "$staged"; die "安装前二次检查失败。"; }

    # 记录更新前的服务状态：原本未运行/未启用时，不擅自启动服务。
    service_active && was_active=1 || true
    systemctl is-enabled --quiet realm.service 2>/dev/null && was_enabled=1 || true

    old_version=""
    if service_installed; then
        old_version=$("$REALM_BIN" --version 2>/dev/null || true)
        if [[ -n "$old_version" ]]; then
            backup_file="${BACKUP_DIR}/realm_$(date +%Y%m%d_%H%M%S)_$$"
            cp -a -- "$REALM_BIN" "$backup_file" || die "旧版本备份失败，已取消更新。"
            ok "旧版本已备份：$backup_file"
        fi
    fi

    if ! mv -f -- "$staged" "$REALM_BIN"; then
        rm -f "$staged"
        die "替换 Realm 二进制失败，旧版本未主动删除。"
    fi
    chmod 0755 "$REALM_BIN"
    ok "Realm 二进制文件已安装/更新：$version"
    ensure_config
    install_service
    if [[ -f "$CONFIG_PATH" ]]; then
        chown root:realm "$CONFIG_PATH"; chmod 0640 "$CONFIG_PATH"
    fi

    if ((was_enabled || was_active)); then
        if ! restart_realm_checked; then
            if [[ -n "$backup_file" ]]; then
                rollback_realm "$backup_file" || warn "自动回滚未能恢复服务，请手动检查：systemctl status realm.service"
            else
                err "这是首次安装，没有可回滚的旧版本。"
            fi
            return 1
        fi
        ok "Realm 更新完成，新版本服务已正常启动。"
    else
        warn "Realm 已安装/更新。更新前服务未运行且未启用，因此没有自动启动；可先配置转发规则，再从菜单启动服务。"
    fi
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && ((10#$p >= 1 && 10#$p <= 65535))
}

validate_host() {
    local host="$1"
    [[ -n "$host" ]] || return 1
    if [[ "$host" == *"["* || "$host" == *"]"* ]]; then
        [[ "$host" == \[*\] ]] || return 1
        host="${host:1:${#host}-2}"
    fi
    [[ -n "$host" && "$host" =~ ^[A-Za-z0-9._:%-]+$ ]]
}

format_remote() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then printf '[%s]:%s' "$host" "$port"; else printf '%s:%s' "$host" "$port"; fi
}

endpoint_exists() {
    local listen="$1"
    grep -Fq "listen = \"${listen}\"" "$CONFIG_PATH"
}

append_endpoint() {
    local listen_port="$1" host="$2" remote_port="$3" candidate
    local remote
    remote=$(format_remote "$host" "$remote_port")
    endpoint_exists "0.0.0.0:${listen_port}" && { err "本地端口 ${listen_port} 已存在，跳过。"; return 1; }
    candidate=$(mktemp "${STATE_DIR}/config.XXXXXX")
    cat "$CONFIG_PATH" >"$candidate"
    cat >>"$candidate" <<EOF_ENDPOINT

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote}"
EOF_ENDPOINT
    atomic_write_config "$candidate"
    rm -f "$candidate"
}

read_single_rule() {
    local listen_port host remote_port
    read -r -p "本地监听端口：" listen_port
    validate_port "$listen_port" || { err "本地端口必须为 1-65535 的整数。"; return 1; }
    read -r -p "目标机 IP / 域名：" host
    validate_host "$host" || { err "目标地址为空或包含非法字符。"; return 1; }
    read -r -p "目标机端口：" remote_port
    validate_port "$remote_port" || { err "目标端口必须为 1-65535 的整数。"; return 1; }
    append_endpoint "$listen_port" "$host" "$remote_port"
}

add_forward() {
    ensure_config
    local answer
    while true; do
        read_single_rule || true
        read -r -p "继续添加规则？[y/N]：" answer
        [[ "$answer" =~ ^[Yy]$ ]] || break
    done
    install_service
    read -r -p "是否立即重启 Realm 使配置生效？[Y/n]：" answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then restart_realm_checked || true; fi
}

add_port_range_forward() {
    ensure_config
    local host start_port end_port remote_start count i local_port remote_port answer
    read -r -p "目标机 IP / 域名：" host
    validate_host "$host" || { err "目标地址为空或包含非法字符。"; return 1; }
    read -r -p "本地起始端口：" start_port
    read -r -p "本地截止端口：" end_port
    read -r -p "目标机起始端口：" remote_start
    validate_port "$start_port" && validate_port "$end_port" && validate_port "$remote_start" || { err "端口必须为 1-65535 的整数。"; return 1; }
    ((10#$start_port <= 10#$end_port)) || { err "本地起始端口不能大于截止端口。"; return 1; }
    count=$((10#$end_port - 10#$start_port + 1))
    ((10#$remote_start + count - 1 <= 65535)) || { err "目标端口段超出 65535。"; return 1; }
    ((count <= 2000)) || { err "单次最多添加 2000 条规则，避免误操作。"; return 1; }
    for ((i=0; i<count; i++)); do
        local_port=$((10#$start_port + i))
        remote_port=$((10#$remote_start + i))
        if endpoint_exists "0.0.0.0:${local_port}"; then
            err "本地端口 ${local_port} 已存在，整个端口段操作已取消。"
            return 1
        fi
    done
    local candidate
    candidate=$(mktemp "${STATE_DIR}/config.XXXXXX")
    cp "$CONFIG_PATH" "$candidate"
    for ((i=0; i<count; i++)); do
        local_port=$((10#$start_port + i))
        remote_port=$((10#$remote_start + i))
        printf '\n[[endpoints]]\nlisten = "0.0.0.0:%s"\nremote = "%s"\n' "$local_port" "$(format_remote "$host" "$remote_port")" >>"$candidate"
    done
    atomic_write_config "$candidate"
    rm -f "$candidate"
    ok "已添加 ${count} 条一一映射规则：本地 ${start_port}-${end_port} → 目标 ${remote_start}-$((10#$remote_start + count - 1))"
    install_service
    read -r -p "是否立即重启 Realm 使配置生效？[Y/n]：" answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then restart_realm_checked || true; fi
}

# 输出配置中的 endpoint 块：序号、本地监听、远程目标。
list_endpoints() {
    awk '
    /^\[\[endpoints\]\][[:space:]]*$/ { if (seen) print idx "|" listen "|" remote; seen=1; idx++; listen=""; remote=""; next }
    seen && /^[[:space:]]*listen[[:space:]]*=/ { line=$0; sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/[\"]/, "", line); listen=line }
    seen && /^[[:space:]]*remote[[:space:]]*=/ { line=$0; sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/[\"]/, "", line); remote=line }
    END { if (seen) print idx "|" listen "|" remote }
    ' "$CONFIG_PATH"
}

show_all_conf() {
    [[ -f "$CONFIG_PATH" ]] || { warn "配置文件不存在，请先部署 Realm。"; return; }
    local rows count=0 idx listen remote
    rows=$(list_endpoints)
    if [[ -z "$rows" ]]; then msg "当前没有配置任何转发规则。"; return; fi
    printf '\n%-6s %-24s %s\n' '序号' '本地监听' '目标地址'
    printf '%s\n' '---------------------------------------------------------------'
    while IFS='|' read -r idx listen remote; do
        [[ -n "$idx" ]] || continue
        printf '%-6s %-24s %s\n' "$idx" "$listen" "$remote"
        ((count+=1))
    done <<<"$rows"
    printf '\n共 %s 条转发规则。\n' "$count"
}

delete_forward() {
    ensure_config
    local rows idx listen remote choice candidate
    rows=$(list_endpoints)
    [[ -n "$rows" ]] || { warn "当前没有转发规则。"; return; }
    show_all_conf
    read -r -p "输入要删除的规则序号（输入 all 删除全部，回车取消）：" choice
    [[ -n "$choice" ]] || return 0
    if [[ "$choice" != "all" && ! "$choice" =~ ^[0-9]+$ ]]; then err "请输入有效序号或 all。"; return 1; fi
    if [[ "$choice" != "all" ]] && ! awk -F'|' -v n="$choice" '$1==n{found=1} END{exit !found}' <<<"$rows"; then
        err "规则序号不存在。"; return 1
    fi
    candidate=$(mktemp "${STATE_DIR}/config.XXXXXX")
    awk -v target="$choice" '
    BEGIN { idx=0; drop=0 }
    /^\[\[endpoints\]\][[:space:]]*$/ {
        if (drop==0 && block!="") printf "%s", block
        block=$0 "\n"; idx++; drop=(target=="all" || idx==target); next
    }
    {
        if (idx==0) { print; next }
        if (drop==0) block=block $0 "\n"
    }
    END { if (drop==0 && block!="") printf "%s", block }
    ' "$CONFIG_PATH" >"$candidate"
    atomic_write_config "$candidate"
    rm -f "$candidate"
    ok "转发规则已删除；配置已备份。"
    read -r -p "是否立即重启 Realm 使配置生效？[Y/n]：" choice
    if [[ ! "$choice" =~ ^[Nn]$ ]]; then restart_realm_checked || true; fi
}

show_status() {
    printf '\nRealm 程序：'
    if service_installed; then "$REALM_BIN" --version 2>/dev/null || echo '已安装'; else echo '未安装'; fi
    printf '服务状态：'
    if service_active; then msg "${GREEN}运行中${RESET}"; else msg "${RED}未运行${RESET}"; fi
    printf '开机启动：'
    if systemctl is-enabled --quiet realm.service 2>/dev/null; then echo '已启用'; else echo '未启用'; fi
    printf '配置文件：%s\n' "$CONFIG_PATH"
}

start_service() {
    service_installed || { err "Realm 尚未安装，请先选择部署环境。"; return 1; }
    [[ -f "$CONFIG_PATH" ]] || ensure_config
    install_service
    systemctl enable realm.service
    restart_realm_checked
}

stop_service() {
    systemctl stop realm.service || { err "停止服务失败。"; return 1; }
    systemctl disable realm.service || true
    ok "Realm 已停止，并已取消开机自启。"
}

restart_service() {
    service_installed || { err "Realm 尚未安装。"; return 1; }
    install_service
    restart_realm_checked
}

view_logs() {
    local n
    read -r -p "查看最近多少行日志？[默认 100]：" n
    n=${n:-100}
    [[ "$n" =~ ^[0-9]+$ ]] || { err "请输入数字。"; return 1; }
    journalctl -u realm.service -n "$n" --no-pager
    read -r -p "按回车返回菜单..." _
}

follow_logs() { journalctl -u realm.service -f; }

check_config() {
    [[ -f "$CONFIG_PATH" ]] || { err "配置文件不存在。"; return 1; }
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$CONFIG_PATH" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    print("当前 Python 版本没有 tomllib（需要 Python 3.11+），跳过 TOML 语法校验。")
    raise SystemExit(0)
try:
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
    endpoints = data.get('endpoints', [])
    print(f"TOML 语法正确；检测到 {len(endpoints)} 条 endpoint。")
except Exception as e:
    print(f"TOML 配置错误：{e}", file=sys.stderr)
    raise SystemExit(1)
PY
    else
        warn "未安装 Python 3，无法执行完整 TOML 语法校验。"
    fi
}

uninstall_realm() {
    local answer
    read -r -p "确认卸载 Realm 服务和程序？[y/N]：" answer
    [[ "$answer" =~ ^[Yy]$ ]] || { warn "已取消卸载。"; return; }
    systemctl disable --now realm.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf -- "$REALM_DIR"
    ok "Realm 服务和程序已卸载。"
    read -r -p "是否同时删除配置和备份目录 ${STATE_DIR}？[y/N]：" answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then rm -rf -- "$STATE_DIR"; ok "配置和备份已删除。"; else warn "配置和备份已保留。"; fi
}

update_script() {
    local self tmp
    self=$(readlink -f "$0")
    tmp=$(mktemp "${self}.new.XXXXXX")
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"; err "脚本下载失败，原脚本未修改。"; return 1
    fi
    if ! bash -n "$tmp"; then rm -f "$tmp"; err "新脚本语法检查失败，原脚本未修改。"; return 1; fi
    cp -a "$self" "${self}.bak.$(date +%Y%m%d_%H%M%S)"
    chmod 0755 "$tmp"
    mv -f "$tmp" "$self"
    ok "脚本更新完成。重新启动脚本即可使用新版本。"
    exit 0
}

add_from_cli() {
    local listen="$1" remote="$2" host port
    [[ "$listen" == *:* && "$remote" == *:* ]] || die "参数格式应为 -l 本地IP:端口 -r 目标IP:端口"
    local listen_host=${listen%:*} listen_port=${listen##*:}
    host=${remote%:*}; port=${remote##*:}
    validate_port "$listen_port" || die "本地端口无效。"
    validate_port "$port" || die "目标端口无效。"
    validate_host "$host" || die "目标地址无效。"
    [[ "$listen_host" == "0.0.0.0" || "$listen_host" == "::" || "$listen_host" == "127.0.0.1" || "$listen_host" == "localhost" ]] || warn "当前版本命令行参数只使用端口，监听地址统一为 0.0.0.0。"
    ensure_config
    append_endpoint "$listen_port" "$host" "$port"
    ok "已添加：0.0.0.0:${listen_port} → $(format_remote "$host" "$port")。需要重启服务后生效。"
}

show_menu() {
    clear 2>/dev/null || true
    msg "${BLUE}==============================================${RESET}"
    msg "          Realm 转发管理脚本 [${SCRIPT_VERSION}]"
    msg "${BLUE}==============================================${RESET}"
    show_status
    msg ""
    cat <<'MENU'
 1. 部署 / 安装 Realm（自动获取最新版本）
 2. 添加单端口转发
 3. 添加端口段转发（一一映射）
 4. 查看现有转发配置
 5. 删除转发规则
 6. 启动服务并设置开机自启
 7. 停止服务并取消开机自启
 8. 重启服务
 9. 更新 Realm 程序
10. 查看服务状态
11. 查看服务日志
12. 实时跟踪服务日志
13. 检查配置文件
14. 卸载 Realm
15. 更新管理脚本
 0. 退出
MENU
    msg "${BLUE}==============================================${RESET}"
}

main() {
    require_root
    check_platform
    check_dependencies
    init_env
    ensure_realm_user

    # 兼容原脚本的 -l listen:port -r remote:port 用法
    if (($#)); then
        local listen_arg="" remote_arg=""
        while getopts ':l:r:' opt; do
            case "$opt" in
                l) listen_arg="$OPTARG" ;;
                r) remote_arg="$OPTARG" ;;
                *) die "用法：$0 [-l listen_ip:port -r remote_ip:port]" ;;
            esac
        done
        if [[ -n "$listen_arg" || -n "$remote_arg" ]]; then
            [[ -n "$listen_arg" && -n "$remote_arg" ]] || die "-l 和 -r 必须同时提供。"
            add_from_cli "$listen_arg" "$remote_arg"
            exit 0
        fi
    fi

    local choice
    while true; do
        show_menu
        read -r -p "请输入选项 [0-15]：" choice || exit 0
        case "$choice" in
            1) install_or_update_realm; read -r -p "按回车继续..." _ ;;
            2) add_forward ;;
            3) add_port_range_forward ;;
            4) show_all_conf; read -r -p "按回车返回..." _ ;;
            5) delete_forward ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            9) install_or_update_realm; read -r -p "按回车继续..." _ ;;
            10) show_status; systemctl status realm.service --no-pager -l || true; read -r -p "按回车返回..." _ ;;
            11) view_logs ;;
            12) follow_logs ;;
            13) check_config; read -r -p "按回车返回..." _ ;;
            14) uninstall_realm; read -r -p "按回车继续..." _ ;;
            15) update_script ;;
            0) exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
    done
}

main "$@"
