#!/usr/bin/env bash

# NGINXPROXY_MANAGED_COMMAND=1

# Nginx Emby reverse-proxy deployment script with optional HAProxy SNI sharing.
# Supports multiple
# independent streaming/CDN upstream domains.
#
# Based on the interaction and deployment flow of:
# https://github.com/sakullla/nginx-reverse-emby
#
# Main additions:
#   1. Repeated interactive input for streaming upstream URLs.
#   2. Repeated -s/--stream-domain CLI option.
#   3. Rewrites absolute streaming URLs in Location headers and response bodies.
#   4. Generates fixed per-upstream proxy locations instead of exposing a
#      user-controlled general-purpose open proxy endpoint.

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SUDO=''
ROOT_HOME=$(awk -F: '$3 == 0 {print $6; exit}' /etc/passwd 2>/dev/null || true)
ROOT_HOME=${ROOT_HOME:-/root}
BACKUP_DIR='/etc/nginx/backup'
ACME_SH="${ROOT_HOME}/.acme.sh/acme.sh"
ACME_WEBROOT='/var/www/acme-challenge'
ACME_VERSION='3.1.2'
ACME_ARCHIVE_SHA256='a51511ad0e2912be45125cf189401e4ae776ca1a29d5768f020a1e35a9560186'
ACME_ARCHIVE_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"

# These commands are persisted by acme.sh and therefore must be standalone:
# cron renewals cannot call functions defined only in this deployment script.
ACME_NGINX_PRE_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl stop nginx; elif command -v service >/dev/null 2>&1 && service nginx stop; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s quit; i=0; while kill -0 "$(cat /run/nginx.pid)" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done; ! kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; fi'
ACME_NGINX_POST_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then :; else nginx; fi'
ACME_NGINX_RELOAD_CMD='if [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload; elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; else nginx; fi'

SCRIPT_VERSION='2026.08.21-haproxy7'
SCRIPT_DOWNLOAD_URL='https://raw.githubusercontent.com/KevinChen222/nginx_proxy/refs/heads/main/deploy.sh'
QUICK_COMMAND_PATH='/usr/local/bin/nginxproxy'
QUICK_COMMAND_MARKER='# NGINXPROXY_MANAGED_COMMAND=1'
SNI_ROUTER_BIN='/usr/local/bin/sb'
SNI_ROUTER_API_VERSION='1'
SNI_ROUTER_OWNER='nginx-proxy'
SNI_ROUTER_BACKEND_HOST='127.0.0.1'
SNI_ROUTER_BACKEND_PORT='8444'
TRANSFER_SCHEMA='nginxproxy-links'
TRANSFER_VERSION=1

# Temporary rollback snapshots for files changed during this invocation.
declare -a config_tx_targets=()
declare -a config_tx_backups=()
declare -a config_tx_existed=()

# Main frontend/upstream values.
you_domain_full=''
r_domain_full=''
you_domain=''
you_domain_path=''
you_frontend_port=''
no_tls=''
r_domain=''
r_domain_path=''
r_frontend_port=''
r_http_frontend=''

# Optional settings.
cert_domain=''
manual_resolver=''
parse_cert_domain='no'
dns_provider=''
cf_token=''
cf_account_id=''
domain_to_remove=''
install_command_only='no'
script_update_performed='no'
force_yes='no'
no_proxy_redirect='no'
upstream_tls_verify='yes'
manual_gh_proxy=''
format_cert_domain=''
resolver=''
frontend_mode='direct'
frontend_mode_explicit='no'
reuse_existing_certificate='no'
sni_route_registered='no'
sni_route_preexisting='no'
sni_route_removed_for_delete='no'
sni_route_removed_domain=''
sni_route_removed_owner=''
sni_route_removed_backend=''

# Streaming upstream arrays. Each --stream-domain appends one item.
declare -a stream_input_urls=()
declare -a stream_protocols=()
declare -a stream_domains=()
declare -a stream_ports=()
declare -a stream_base_paths=()
declare -a stream_origins=()
declare -a stream_origins_no_default_port=()

# Discovered reverse-proxy links managed by this script.
declare -a managed_link_configs=()
declare -a managed_link_frontends=()
declare -a managed_link_mains=()
declare -a managed_link_streams=()

log_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

handle_error() {
    local exit_code=$?
    local line_number=${1:-unknown}
    local had_config_changes=no
    ((${#config_tx_targets[@]})) && had_config_changes=yes
    if declare -F rollback_new_sni_route >/dev/null 2>&1; then
        rollback_new_sni_route || true
    fi
    if declare -F restore_removed_sni_route >/dev/null 2>&1; then
        restore_removed_sni_route || true
    fi
    if declare -F rollback_config_changes >/dev/null 2>&1; then
        rollback_config_changes || true
    fi
    if [[ $had_config_changes == yes ]] && command -v nginx >/dev/null 2>&1 && \
       declare -F restore_nginx_after_rollback >/dev/null 2>&1; then
        restore_nginx_after_rollback
    fi
    echo >&2
    log_error "脚本在第 ${line_number} 行中止，退出码: ${exit_code}"
    exit "$exit_code"
}
trap 'handle_error $LINENO' ERR

handle_signal() {
    local signal_name=$1 exit_code=$2 had_config_changes=no
    ((${#config_tx_targets[@]})) && had_config_changes=yes
    if declare -F rollback_new_sni_route >/dev/null 2>&1; then
        rollback_new_sni_route || true
    fi
    if declare -F restore_removed_sni_route >/dev/null 2>&1; then
        restore_removed_sni_route || true
    fi
    if declare -F rollback_config_changes >/dev/null 2>&1; then
        rollback_config_changes || true
    fi
    if [[ $had_config_changes == yes ]] && declare -F restore_nginx_after_rollback >/dev/null 2>&1; then
        restore_nginx_after_rollback
    fi
    if declare -F nginx_is_running >/dev/null 2>&1 && command -v nginx >/dev/null 2>&1 && ! nginx_is_running; then
        start_nginx || true
    fi
    trap - INT TERM
    log_error "收到 ${signal_name}，已尽力恢复配置与 Nginx。"
    exit "$exit_code"
}
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_error '此脚本必须完整地以 root 身份运行。'
        log_error "请使用: sudo -H bash '$0' [选项]"
        exit 1
    fi
    export HOME=$ROOT_HOME
}

current_script_path() {
    local source_path=${BASH_SOURCE[0]}
    [[ -f $source_path ]] || return 1
    readlink -f -- "$source_path" 2>/dev/null || printf '%s\n' "$source_path"
}

install_quick_command() {
    local source_path source_real target_real install_tmp
    source_path=${1:-}
    if [[ -z $source_path ]]; then
        if ! source_path=$(current_script_path); then
            log_error '当前脚本不是普通本地文件，无法安全安装快捷命令。'
            log_error '请先下载 deploy.sh，通过 Bash 语法校验后再安装到 /usr/local/bin/nginxproxy。'
            return 1
        fi
    fi

    if ! grep -Fqx -- "$QUICK_COMMAND_MARKER" "$source_path" || ! bash -n "$source_path"; then
        log_error '当前脚本缺少管理标记或 Bash 语法校验失败，拒绝安装快捷命令。'
        return 1
    fi

    source_real=$(readlink -f -- "$source_path" 2>/dev/null || printf '%s\n' "$source_path")
    if [[ -L $QUICK_COMMAND_PATH ]]; then
        log_error "快捷命令路径是符号链接，拒绝覆盖: $QUICK_COMMAND_PATH"
        return 1
    fi
    if [[ -e $QUICK_COMMAND_PATH ]]; then
        target_real=$(readlink -f -- "$QUICK_COMMAND_PATH" 2>/dev/null || printf '%s\n' "$QUICK_COMMAND_PATH")
        if [[ $source_real == "$target_real" ]]; then
            chmod 700 -- "$QUICK_COMMAND_PATH"
            log_success "快捷命令已就绪: nginxproxy"
            return 0
        fi
        if [[ ! -f $QUICK_COMMAND_PATH ]] || ! grep -Fqx -- "$QUICK_COMMAND_MARKER" "$QUICK_COMMAND_PATH"; then
            log_error "路径已被其他文件占用，拒绝覆盖: $QUICK_COMMAND_PATH"
            return 1
        fi
    fi

    install_tmp=$(mktemp "${QUICK_COMMAND_PATH}.tmp.XXXXXXXXXX") || return 1
    if ! install -m 700 -- "$source_path" "$install_tmp" || ! mv -f -- "$install_tmp" "$QUICK_COMMAND_PATH"; then
        rm -f -- "$install_tmp"
        log_error "安装快捷命令失败: $QUICK_COMMAND_PATH"
        return 1
    fi
    log_success "快捷命令已安装: nginxproxy"
}

ensure_quick_command() {
    if [[ -L $QUICK_COMMAND_PATH ]]; then
        log_warn "快捷命令路径是符号链接，已跳过自动安装: $QUICK_COMMAND_PATH"
        return 0
    fi
    if [[ -e $QUICK_COMMAND_PATH ]]; then
        if [[ -f $QUICK_COMMAND_PATH ]] && grep -Fqx -- "$QUICK_COMMAND_MARKER" "$QUICK_COMMAND_PATH"; then
            chmod 700 -- "$QUICK_COMMAND_PATH" || log_warn "无法修复快捷命令权限: $QUICK_COMMAND_PATH"
        else
            log_warn "快捷命令路径已被其他文件占用，已保留原文件: $QUICK_COMMAND_PATH"
        fi
        return 0
    fi

    if [[ ! -f ${BASH_SOURCE[0]} ]]; then
        log_warn '当前通过管道或进程替换运行，已跳过自动安装 nginxproxy。'
        return 0
    fi
    log_info '正在安装快捷命令 nginxproxy...'
    install_quick_command || log_warn '快捷命令安装失败，但不会影响本次反代配置。'
}

show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

部署一个支持“主 Emby 域名 + 多个独立推流域名”的 Nginx 反向代理。
不带参数运行时进入管理菜单，可添加、查看、修改或删除反代链路。

部署选项:
  -y, --you-domain <URL>       用户访问的反代 URL
                               例如: https://emby.example.com:443
  -r, --r-domain <URL>         Emby 登录/API 主源站 URL
                               例如: https://v1.uhdnow.com:443
  -s, --stream-domain <URL>    推流/CDN 源站 URL，可重复使用多次
                               例如: -s https://v1-vod1.example.com:443 \\
                                     -s https://v1-vod2.example.com:443
  -m, --cert-domain <域名>     手动指定证书主域名
  -d, --parse-cert-domain      自动提取根域名作为证书域名
  -D, --dns <provider>         使用 acme.sh DNS API 申请证书，例如 cf
  -R, --resolver <DNS>         指定 Nginx resolver，例如 "1.1.1.1 8.8.8.8"
      --cf-token <TOKEN>       Cloudflare API Token
      --cf-account-id <ID>     Cloudflare Account ID
      --gh-proxy <URL>         显式指定 GitHub 加速前缀（下载仍会校验哈希）
      --no-proxy-redirect      不改写未显式配置的普通重定向
      --no-upstream-tls-verify 不校验 HTTPS 源站证书（仅用于自签名源站）
      --frontend-mode <模式>   direct（Nginx 直监听）或 haproxy（与 Reality 共享 443）
      --sni-router             等同于 --frontend-mode haproxy
      --version                显示脚本版本

管理选项:
      --install-command        将当前脚本安装为 /usr/local/bin/nginxproxy
      --remove <URL>           删除指定前端 URL 的配置及其独占证书/续期记录
  -Y, --yes                    非交互删除时自动确认
  -h, --help                   显示帮助

交互模式中，主源站输入完成后会连续询问推流源站；直接回车结束。
EOF
}

backup_file() {
    local file_path=$1
    if $SUDO test -f "$file_path"; then
        $SUDO mkdir -p "$BACKUP_DIR"
        local stamp
        stamp=$(date +%Y%m%d_%H%M%S)
        $SUDO cp -a "$file_path" "$BACKUP_DIR/$(basename "$file_path").${stamp}"
        log_info "已备份: $file_path"
    fi
}

version_at_least() {
    local current=$1 required=$2
    [[ $(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1) == "$required" ]]
}

download_script_update() {
    local destination=$1
    local update_url="${SCRIPT_DOWNLOAD_URL}?v=$(date +%s)"

    rm -f -- "$destination"
    if command -v curl >/dev/null 2>&1 && \
       curl -LfsS --connect-timeout 15 --max-time 120 "$update_url" -o "$destination"; then
        return 0
    fi
    rm -f -- "$destination"
    if command -v wget >/dev/null 2>&1 && \
       wget -q --timeout=120 -O "$destination" "$update_url"; then
        return 0
    fi
    rm -f -- "$destination"
    log_error '脚本下载失败，请检查网络以及 GitHub 连接。'
    return 1
}

validate_script_update() {
    local candidate=$1
    local candidate_version

    if [[ ! -s $candidate ]] || ! head -n 1 "$candidate" | grep -Fqx '#!/usr/bin/env bash'; then
        log_error '下载内容不是有效的 deploy.sh，已拒绝更新。'
        return 1
    fi
    if ! grep -Fqx -- "$QUICK_COMMAND_MARKER" "$candidate"; then
        log_error '下载内容缺少脚本管理标记，已拒绝更新。'
        return 1
    fi
    candidate_version=$(sed -n "s/^SCRIPT_VERSION='\([^']*\)'.*/\1/p" "$candidate" | head -n 1)
    if [[ -z $candidate_version ]] || ! bash -n "$candidate"; then
        log_error '下载脚本的版本号无效或 Bash 语法校验失败，已拒绝更新。'
        return 1
    fi
    printf '%s\n' "$candidate_version"
}

update_script() {
    local candidate candidate_version answer
    candidate=$(mktemp) || return 1
    script_update_performed='no'
    log_info "正在检查更新，当前版本: ${SCRIPT_VERSION}"

    if ! download_script_update "$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi
    if ! candidate_version=$(validate_script_update "$candidate"); then
        rm -f -- "$candidate"
        return 1
    fi

    if [[ $candidate_version == "$SCRIPT_VERSION" ]]; then
        rm -f -- "$candidate"
        log_success "当前已是最新版本: ${SCRIPT_VERSION}"
        return 0
    fi
    if version_at_least "$SCRIPT_VERSION" "$candidate_version"; then
        rm -f -- "$candidate"
        log_warn "本地版本 ${SCRIPT_VERSION} 高于远端版本 ${candidate_version}，已跳过降级。"
        return 0
    fi

    echo "发现新版本: ${SCRIPT_VERSION} -> ${candidate_version}"
    read -r -p '是否立即更新？[Y/n]: ' answer
    if [[ $answer =~ ^[Nn]$ ]]; then
        rm -f -- "$candidate"
        log_info '已取消更新。'
        return 0
    fi
    if ! install_quick_command "$candidate"; then
        rm -f -- "$candidate"
        return 1
    fi
    rm -f -- "$candidate"
    script_update_performed='yes'
    log_success "脚本已更新: ${SCRIPT_VERSION} -> ${candidate_version}"
}

uninstall_quick_command() {
    local answer resolved_target=''
    echo
    log_warn '此操作只会删除 /usr/local/bin/nginxproxy。'
    echo '以下内容全部保留：Nginx、证书、Emby 反代配置、HAProxy/SNI 分流、sb.sh、Sing-box 与 Reality 节点。'

    if [[ ! -e $QUICK_COMMAND_PATH && ! -L $QUICK_COMMAND_PATH ]]; then
        log_info 'nginxproxy 快捷脚本当前未安装，无需卸载。'
        return 0
    fi
    if [[ -L $QUICK_COMMAND_PATH ]]; then
        resolved_target=$(readlink -f -- "$QUICK_COMMAND_PATH" 2>/dev/null || true)
        if [[ -z $resolved_target || ! -f $resolved_target ]] || \
           ! grep -Fqx -- "$QUICK_COMMAND_MARKER" "$resolved_target"; then
            log_error "该路径是非本脚本管理的符号链接，拒绝删除: $QUICK_COMMAND_PATH"
            return 1
        fi
    elif [[ ! -f $QUICK_COMMAND_PATH ]] || \
         ! grep -Fqx -- "$QUICK_COMMAND_MARKER" "$QUICK_COMMAND_PATH"; then
        log_error "该路径不属于本脚本，拒绝删除: $QUICK_COMMAND_PATH"
        return 1
    fi

    read -r -p '确定只卸载 nginxproxy 脚本吗？[y/N]: ' answer
    if [[ ! $answer =~ ^[Yy]$ ]]; then
        log_info '已取消卸载。'
        return 0
    fi
    if ! rm -f -- "$QUICK_COMMAND_PATH"; then
        log_error "无法删除: $QUICK_COMMAND_PATH"
        return 1
    fi
    log_success 'nginxproxy 脚本已卸载；现有反代服务与 Reality 节点均未改动。'
}

has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

sni_router_call() {
    local api
    if [[ ! -x $SNI_ROUTER_BIN ]]; then
        log_error "未找到可执行的 ${SNI_ROUTER_BIN}；请先安装同仓库的 sb.sh。"
        return 1
    fi
    api=$($SNI_ROUTER_BIN sni-router api-version 2>/dev/null || true)
    if [[ $api != "$SNI_ROUTER_API_VERSION" ]]; then
        log_error "sb SNI 路由接口不兼容（需要 ${SNI_ROUTER_API_VERSION}，实际 ${api:-不可用}）。"
        return 1
    fi
    $SNI_ROUTER_BIN sni-router "$@"
}

prepare_sni_router() {
    local status
    sni_router_call prepare || return 1
    status=$(sni_router_call status) || return 1
    if grep -Fqx "https=${you_domain,,} -> ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT} (${SNI_ROUTER_OWNER})" <<<"$status"; then
        sni_route_preexisting=yes
    fi
}

register_sni_route() {
    [[ $frontend_mode == haproxy ]] || return 0
    if [[ $sni_route_preexisting == yes ]]; then
        log_info "HAProxy 已登记该 Emby SNI，保留现有路由。"
        return 0
    fi
    sni_router_call register-https "$SNI_ROUTER_OWNER" "${you_domain,,}" "$SNI_ROUTER_BACKEND_PORT" || return 1
    sni_route_registered=yes
}

rollback_new_sni_route() {
    [[ $sni_route_registered == yes && $sni_route_preexisting != yes ]] || return 0
    log_warn "正在撤销本次新增的 HAProxy SNI 路由: ${you_domain,,}"
    sni_router_call remove-https "$SNI_ROUTER_OWNER" "${you_domain,,}" || return 1
    sni_route_registered=no
}

restore_removed_sni_route() {
    [[ $sni_route_removed_for_delete == yes ]] || return 0
    log_warn "正在恢复删除前的 HAProxy SNI 路由: $sni_route_removed_domain"
    sni_router_call register-https "$sni_route_removed_owner" "$sni_route_removed_domain" "$sni_route_removed_backend" || return 1
    sni_route_removed_for_delete=no
}

validate_frontend_mode() {
    [[ $frontend_mode == direct || $frontend_mode == haproxy ]] || {
        log_error "不支持的前端模式: $frontend_mode"
        return 1
    }
    if [[ $frontend_mode == direct ]]; then
        if [[ $you_frontend_port == 443 && -x $SNI_ROUTER_BIN ]] && \
           [[ $($SNI_ROUTER_BIN sni-router api-version 2>/dev/null || true) == "$SNI_ROUTER_API_VERSION" ]] && \
           $SNI_ROUTER_BIN sni-router status 2>/dev/null | grep -Fq 'haproxy=active'; then
            log_error 'HAProxy 已占用公网 443；请使用 --frontend-mode haproxy，或先移除所有 SNI 路由。'
            return 1
        fi
        return 0
    fi
    [[ $no_tls != yes ]] || { log_error 'HAProxy SNI 分流只支持 HTTPS 前端。'; return 1; }
    [[ $you_frontend_port == 443 ]] || { log_error 'HAProxy SNI 分流的公网入口必须是 443。'; return 1; }
    ! is_ip_address "$you_domain" || { log_error 'HAProxy SNI 分流必须使用域名，不能使用 IP。'; return 1; }
    has_systemd || { log_error '当前 sb.sh 的 HAProxy 管理器要求 systemd。'; return 1; }
    sni_router_call api-version >/dev/null || return 1
}

nginx_is_running() {
    [[ -s /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null
}

start_nginx() {
    if has_systemd; then
        systemctl start nginx
        return
    fi
    if command -v service >/dev/null 2>&1 && service nginx start; then
        return
    fi
    nginx
}

reload_or_start_nginx() {
    if nginx_is_running; then
        nginx -s reload
    else
        start_nginx
    fi
}

stage_file_install() {
    local source=$1 target=$2 backup='' existed=no
    if [[ -e $target || -L $target ]]; then
        backup=$(mktemp)
        cp -a -- "$target" "$backup"
        existed=yes
    fi
    config_tx_targets+=("$target")
    config_tx_backups+=("$backup")
    config_tx_existed+=("$existed")
    cp -- "$source" "$target"
    [[ $existed == yes ]] || chmod 0644 "$target"
}

stage_file_removal() {
    local target=$1 backup
    backup=$(mktemp)
    cp -a -- "$target" "$backup"
    config_tx_targets+=("$target")
    config_tx_backups+=("$backup")
    config_tx_existed+=(yes)
    rm -f -- "$target"
}

rollback_config_changes() {
    local i target backup existed status=0
    ((${#config_tx_targets[@]})) || return 0
    log_warn '正在回滚本次 Nginx 配置改动...'
    for ((i=${#config_tx_targets[@]} - 1; i >= 0; i--)); do
        target=${config_tx_targets[$i]}
        backup=${config_tx_backups[$i]}
        existed=${config_tx_existed[$i]}
        if [[ $existed == yes ]]; then
            if cp -a -- "$backup" "$target"; then
                rm -f -- "$backup"
            else
                log_error "回滚失败，快照保留在: $backup"
                status=1
            fi
        else
            rm -f -- "$target" || status=1
        fi
    done
    config_tx_targets=()
    config_tx_backups=()
    config_tx_existed=()
    return "$status"
}

commit_config_changes() {
    local backup
    for backup in "${config_tx_backups[@]}"; do
        [[ -z $backup ]] || rm -f -- "$backup"
    done
    config_tx_targets=()
    config_tx_backups=()
    config_tx_existed=()
}

restore_nginx_after_rollback() {
    if nginx -t >/dev/null 2>&1; then
        reload_or_start_nginx || log_warn '配置已回滚，但 Nginx 未能自动重新加载。'
    else
        log_error '回滚后 Nginx 配置仍未通过测试，请检查其他站点配置。'
    fi
}

cleanup_acme_extract_dir() {
    local directory resolved
    directory=$1
    resolved=$(readlink -m -- "$directory")
    if [[ $resolved != /tmp/acme-install.* || ! -d $resolved ]]; then
        log_error "拒绝清理非预期的临时目录: $resolved"
        return 1
    fi
    rm -rf --one-file-system -- "$resolved"
}

is_in_china() {
    local loc=''
    loc=$(curl -m 3 -fsSL https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="loc"{print $2; exit}') || true
    [[ $loc == CN ]]
}

setup_download_urls() {
    local effective_proxy=${manual_gh_proxy:-${GH_PROXY:-}}

    if [[ -n $effective_proxy ]]; then
        if [[ $effective_proxy != https://* || $effective_proxy == *[[:space:]]* || $effective_proxy == *';'* || $effective_proxy == *'{'* || $effective_proxy == *'}'* ]]; then
            log_error "GitHub 代理必须是安全的 HTTPS URL: $effective_proxy"
            return 1
        fi
        [[ $effective_proxy == */ ]] || effective_proxy="${effective_proxy}/"
        ACME_INSTALL_URL="${effective_proxy}${ACME_ARCHIVE_URL}"
        log_info "使用显式指定的 GitHub 代理: $effective_proxy"
    else
        ACME_INSTALL_URL=$ACME_ARCHIVE_URL
    fi
}

has_ipv6() {
    command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q inet6
}

ipv6_stack_available() {
    [[ -s /proc/net/if_inet6 ]]
}

nginx_supports_http2_directive() {
    local nginx_version
    nginx_version=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
    [[ -n $nginx_version ]] && version_at_least "$nginx_version" '1.25.1'
}

get_resolver_host() {
    local system_dns=''
    system_dns=$(awk '/^nameserver[[:space:]]+/ {print ($2 ~ /:/ ? "["$2"]" : $2)}' /etc/resolv.conf 2>/dev/null | xargs) || true
    if [[ -n $system_dns ]]; then
        printf '%s\n' "$system_dns"
    elif is_in_china; then
        printf '%s\n' '223.5.5.5 119.29.29.29'
    else
        printf '%s\n' '1.1.1.1 8.8.8.8'
    fi
}

is_valid_ipv4() {
    local address=$1 octet
    local -a octets=()
    [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_ipv6() {
    local address=$1 left='' right='' part remainder
    local count=0
    local -a groups=()

    [[ $address == *:* && $address =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    if [[ $address == *::* ]]; then
        remainder=${address#*::}
        [[ $remainder != *::* ]] || return 1
        left=${address%%::*}
        right=$remainder
    else
        left=$address
    fi

    for part in "$left" "$right"; do
        [[ -n $part ]] || continue
        IFS=':' read -r -a groups <<<"$part"
        local group
        for group in "${groups[@]}"; do
            [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ((count += 1))
        done
    done

    if [[ $address == *::* ]]; then
        (( count < 8 ))
    else
        (( count == 8 ))
    fi
}

is_valid_dns_name() {
    local name=${1%.} label
    local -a labels=()
    [[ -n $name && ${#name} -le 253 ]] || return 1
    IFS='.' read -r -a labels <<<"$name"
    ((${#labels[@]} >= 2)) || return 1
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

normalize_resolver_list() {
    local input=$1 item host port=''
    local -a normalized=() items=()
    read -r -a items <<<"$input"
    for item in "${items[@]}"; do
        host=$item
        port=''
        if [[ $item =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[3]:-}
            is_valid_ipv6 "$host" || return 1
            item="[${host}]"
        elif [[ $item =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3})(:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}
            port=${BASH_REMATCH[4]:-}
            is_valid_ipv4 "$host" || return 1
            item=$host
        else
            return 1
        fi
        if [[ -n $port ]]; then
            (( port >= 1 && port <= 65535 )) || return 1
            item="${item}:${port}"
        fi
        normalized+=("$item")
    done
    ((${#normalized[@]})) || return 1
    printf '%s\n' "${normalized[*]}"
}

nginx_regex_escape() {
    printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# Prints: protocol|domain|port|path
parse_url() {
    local input=$1
    local proto='' authority='' domain='' port='' path=''

    if [[ $input =~ ^(https?):// ]]; then
        proto=${BASH_REMATCH[1]}
        input=${input#*://}
    else
        return 1
    fi

    authority=${input%%/*}
    if [[ $input == */* ]]; then
        path=/${input#*/}
    fi

    # Reject query/fragment-only authority forms and unsafe Nginx characters.
    if [[ -z $authority || $authority == *[[:space:]]* || $authority == *\"* || $authority == *"'"* || $authority == *';'* || $authority == *'{'* || $authority == *'}'* ]]; then
        return 1
    fi

    if [[ $authority =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
        local ipv6_address=${BASH_REMATCH[1]}
        local ipv6_port=${BASH_REMATCH[3]:-}
        is_valid_ipv6 "$ipv6_address" || return 1
        domain="[${ipv6_address}]"
        port=$ipv6_port
    elif [[ $authority =~ ^([A-Za-z0-9._-]+)(:([0-9]+))?$ ]]; then
        domain=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[3]:-}
        if [[ $domain =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            is_valid_ipv4 "$domain" || return 1
        fi
    else
        return 1
    fi

    if [[ -n $port ]] && (( port < 1 || port > 65535 )); then
        return 1
    fi

    if [[ -n $path ]]; then
        path=${path%%\?*}
        path=${path%%\#*}
        # Paths are inserted into Nginx locations and rewrite replacements.
        if [[ $path == *[[:space:]]* || $path == *\"* || $path == *"'"* || $path == *';'* || $path == *'{'* || $path == *'}'* || $path == *'$'* || $path == *'\\'* || $path == *$'\r'* || $path == *$'\n'* ]]; then
            return 1
        fi
        [[ $path == / ]] && path=''
        while [[ $path == */ && $path != / ]]; do path=${path%/}; done
    fi

    printf '%s|%s|%s|%s\n' "$proto" "$domain" "$port" "$path"
}

is_ip_address() {
    local address=${1#[}
    address=${address%]}
    if [[ $address == *:* ]]; then
        is_valid_ipv6 "$address"
    else
        is_valid_ipv4 "$address"
    fi
}

get_default_port() {
    [[ $1 == http ]] && printf '80\n' || printf '443\n'
}

get_protocol() {
    [[ $1 == yes ]] && printf 'http\n' || printf 'https\n'
}

process_url_input() {
    local full_url=$1
    local domain_type=$2
    local parsed proto domain port path default_port

    parsed=$(parse_url "$full_url") || {
        log_error "URL 格式无效: $full_url；必须以 http:// 或 https:// 开头。"
        return 1
    }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto")
    port=${port:-$default_port}

    case $domain_type in
        you)
            you_domain=$domain
            you_domain_path=$path
            you_frontend_port=$port
            [[ $proto == http ]] && no_tls=yes || no_tls=no
            ;;
        r)
            r_domain=$domain
            r_domain_path=$path
            r_frontend_port=$port
            [[ $proto == http ]] && r_http_frontend=yes || r_http_frontend=no
            ;;
        *) return 1 ;;
    esac
}

add_stream_url() {
    local full_url=$1
    local parsed proto domain port path default_port authority origin no_default_origin existing

    parsed=$(parse_url "$full_url") || {
        log_error "推流 URL 格式无效: $full_url"
        return 1
    }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto")
    port=${port:-$default_port}

    authority="${domain}:${port}"
    origin="${proto}://${authority}${path}"
    no_default_origin=$origin
    if [[ $port == "$default_port" ]]; then
        no_default_origin="${proto}://${domain}${path}"
    fi

    for existing in "${stream_origins[@]:-}"; do
        if [[ $existing == "$origin" ]]; then
            log_warn "推流源站已存在，跳过重复项: $origin"
            return 0
        fi
    done

    stream_input_urls+=("$full_url")
    stream_protocols+=("$proto")
    stream_domains+=("$domain")
    stream_ports+=("$port")
    stream_base_paths+=("$path")
    stream_origins+=("$origin")
    stream_origins_no_default_port+=("$no_default_origin")
    log_success "已添加推流源站: $origin"
}

discover_managed_links() {
    local conf_dir=${1:-/etc/nginx/conf.d}
    local conf link_version frontend main streams host port proto path

    managed_link_configs=()
    managed_link_frontends=()
    managed_link_mains=()
    managed_link_streams=()

    [[ -d $conf_dir ]] || return 0
    for conf in "$conf_dir"/*.conf; do
        [[ -f $conf ]] || continue
        grep -Fqx '# Generated by deploy-stream-domains.sh' "$conf" || continue

        link_version=$(sed -n 's/^# nginxproxy-link-version: //p' "$conf" | head -n 1)
        frontend=$(sed -n 's/^# nginxproxy-frontend: //p' "$conf" | head -n 1)
        main=$(sed -n 's/^# nginxproxy-main: //p' "$conf" | head -n 1)

        # Compatibility with configurations generated before link metadata was
        # introduced. The upstream base path cannot always be recovered from
        # those files, but the upstream origin remains unambiguous.
        if [[ -z $frontend ]]; then
            host=$(awk -F "'" '/^[[:space:]]*set \$emby_public_host / {print $2; exit}' "$conf")
            port=$(awk -F "'" '/^[[:space:]]*set \$emby_public_port / {print $2; exit}' "$conf")
            if grep -Eq '^[[:space:]]*ssl_certificate[[:space:]]+' "$conf"; then
                proto=https
            else
                proto=http
            fi
            path=$(awk '$1 == "location" && $2 ~ /^"/ {gsub(/^"|"$/, "", $2); print $2; exit}' "$conf")
            [[ $path == / ]] && path=''
            if [[ -n $host && -n $port ]]; then
                frontend="${proto}://${host}:${port}${path}"
            fi
        fi
        if [[ -z $main ]]; then
            main=$(awk -F "'" '/^[[:space:]]*set \$emby_main_upstream / {print $2; exit}' "$conf")
        fi
        if [[ $link_version == 1 ]]; then
            streams=$(sed -n 's/^# nginxproxy-stream: //p' "$conf")
        else
            streams=$(sed -n 's/^[[:space:]]*# Streaming upstream [0-9][0-9]*: //p' "$conf")
        fi

        [[ -n $frontend ]] || frontend="无法识别 ($(basename "$conf"))"
        [[ -n $main ]] || main='无法识别'
        managed_link_configs+=("$conf")
        managed_link_frontends+=("$frontend")
        managed_link_mains+=("$main")
        managed_link_streams+=("$streams")
    done
}

show_managed_links() {
    local conf_dir=${1:-/etc/nginx/conf.d}
    local i stream stream_index
    discover_managed_links "$conf_dir"
    echo -e "\n${BLUE}--- 现有 Emby 反代链路 ---${NC}"
    if ((${#managed_link_configs[@]} == 0)); then
        log_info '未找到由本脚本生成的反代链路。'
        return 0
    fi

    for i in "${!managed_link_configs[@]}"; do
        printf '  [%d] %s -> %s\n' "$((i + 1))" \
            "${managed_link_frontends[$i]}" "${managed_link_mains[$i]}"
        stream_index=0
        while IFS= read -r stream; do
            [[ -n $stream ]] || continue
            stream_index=$((stream_index + 1))
            printf '      推流 %d: %s\n' "$stream_index" "$stream"
        done <<<"${managed_link_streams[$i]}"
        ((stream_index > 0)) || printf '      推流: 未单独配置\n'
    done
}

ensure_transfer_tools() {
    if command -v jq >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        return 0
    fi
    log_info '导入/导出功能需要 jq 与 base64，正在补齐依赖...'
    install_dependencies
    if ! command -v jq >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        log_error '未能安装 jq 或 base64，无法使用链路传输功能。'
        return 1
    fi
}

build_link_export_payload() {
    local conf_dir=${1:-/etc/nginx/conf.d}
    local payload item streams_json i conf frontend main stream valid
    local no_redirect tls_verify no_redirect_json tls_verify_json
    discover_managed_links "$conf_dir"
    payload=$(jq -cn --arg schema "$TRANSFER_SCHEMA" --argjson version "$TRANSFER_VERSION" \
        '{schema:$schema,version:$version,links:[]}') || return 1

    for i in "${!managed_link_configs[@]}"; do
        conf=${managed_link_configs[$i]}
        frontend=${managed_link_frontends[$i]}
        main=${managed_link_mains[$i]}
        if ! parse_url "$frontend" >/dev/null 2>&1 || ! parse_url "$main" >/dev/null 2>&1; then
            log_warn "链路元数据不完整，已跳过导出: $frontend -> $main"
            continue
        fi

        valid=yes
        while IFS= read -r stream; do
            [[ -n $stream ]] || continue
            if ! parse_url "$stream" >/dev/null 2>&1; then
                valid=no
                break
            fi
        done <<<"${managed_link_streams[$i]}"
        if [[ $valid != yes ]]; then
            log_warn "推流 URL 无效，已跳过整条链路: $frontend"
            continue
        fi

        streams_json=$(printf '%s' "${managed_link_streams[$i]}" | \
            jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
        no_redirect=$(sed -n 's/^# nginxproxy-no-proxy-redirect: //p' "$conf" | head -n 1)
        if [[ $no_redirect != yes && $no_redirect != no ]]; then
            if grep -Eq 'proxy_redirect.*\$emby_public_host' "$conf"; then no_redirect=no; else no_redirect=yes; fi
        fi
        tls_verify=$(sed -n 's/^# nginxproxy-upstream-tls-verify: //p' "$conf" | head -n 1)
        if [[ $tls_verify != yes && $tls_verify != no ]]; then
            if grep -Eq '^[[:space:]]*proxy_ssl_verify on;' "$conf"; then tls_verify=yes; else tls_verify=no; fi
        fi
        [[ $no_redirect == yes ]] && no_redirect_json=true || no_redirect_json=false
        [[ $tls_verify == yes ]] && tls_verify_json=true || tls_verify_json=false

        item=$(jq -cn \
            --arg source_frontend "$frontend" \
            --arg main "$main" \
            --argjson streams "$streams_json" \
            --argjson no_proxy_redirect "$no_redirect_json" \
            --argjson upstream_tls_verify "$tls_verify_json" \
            '{source_frontend:$source_frontend,main:$main,streams:$streams,no_proxy_redirect:$no_proxy_redirect,upstream_tls_verify:$upstream_tls_verify}') || return 1
        payload=$(jq -c --argjson item "$item" '.links += [$item]' <<<"$payload") || return 1
    done
    printf '%s\n' "$payload"
}

export_managed_links_base64() {
    ensure_transfer_tools || return 1
    local payload count encoded
    payload=$(build_link_export_payload) || return 1
    count=$(jq -r '.links | length' <<<"$payload" | tr -d '\r')
    if ((count == 0)); then
        log_error '没有可导出的有效反代链路。'
        return 1
    fi
    encoded=$(printf '%s' "$payload" | base64 | tr -d '\r\n')
    echo
    echo -e "${BLUE}----- NGINXPROXY BASE64 导出开始 -----${NC}"
    printf '%s\n' "$encoded"
    echo -e "${BLUE}----- NGINXPROXY BASE64 导出结束 -----${NC}"
    log_success "已导出 ${count} 条链路。Base64 仅用于传输，不是加密；内容不含证书私钥和令牌。"
}

decode_transfer_payload() {
    local encoded=$1 normalized
    encoded=$(printf '%s' "$encoded" | tr -d '[:space:]')
    if [[ -z $encoded || ${#encoded} -gt 1048576 ]]; then
        log_error 'Base64 内容为空或超过 1 MiB 限制。'
        return 1
    fi
    if ! normalized=$(printf '%s' "$encoded" | base64 -d 2>/dev/null | jq -ce \
        --arg schema "$TRANSFER_SCHEMA" --argjson version "$TRANSFER_VERSION" '
        select(
            type == "object" and
            .schema == $schema and
            .version == $version and
            (.links | type == "array") and
            (.links | length >= 1 and length <= 50) and
            all(.links[];
                (.source_frontend | type == "string") and
                (.main | type == "string") and
                (.streams | type == "array") and
                all(.streams[]; type == "string") and
                (.no_proxy_redirect | type == "boolean") and
                (.upstream_tls_verify | type == "boolean")
            )
        )
        '); then
        log_error 'Base64 解码失败，或内容不是受支持的 nginxproxy 导出格式。'
        return 1
    fi
    normalized=${normalized%$'\r'}
    printf '%s\n' "$normalized"
}

validate_transfer_payload_urls() {
    local payload=$1 count i source_frontend main stream
    count=$(jq -r '.links | length' <<<"$payload" | tr -d '\r') || return 1
    for ((i=0; i<count; i++)); do
        source_frontend=$(jq -r --argjson i "$i" '.links[$i].source_frontend' <<<"$payload" | tr -d '\r')
        main=$(jq -r --argjson i "$i" '.links[$i].main' <<<"$payload" | tr -d '\r')
        if ! parse_url "$source_frontend" >/dev/null 2>&1 || ! parse_url "$main" >/dev/null 2>&1; then
            log_error "导入数据第 $((i + 1)) 条链路包含无效 URL。"
            return 1
        fi
        while IFS= read -r stream; do
            if ! parse_url "$stream" >/dev/null 2>&1; then
                log_error "导入数据第 $((i + 1)) 条链路包含无效推流 URL。"
                return 1
            fi
        done < <(jq -r --argjson i "$i" '.links[$i].streams[]' <<<"$payload" | tr -d '\r')
    done
}

normalize_import_frontend() {
    local raw=$1 parsed proto domain port path default_port
    raw=${raw//$'\r'/}
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -n $raw ]] || return 1
    [[ $raw == http://* || $raw == https://* ]] || raw="https://${raw}"
    parsed=$(parse_url "$raw") || return 1
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto")
    port=${port:-$default_port}
    printf '%s://%s:%s%s\n' "$proto" "${domain,,}" "$port" "$path"
}

import_links_from_base64() {
    ensure_transfer_tools || return 1
    local encoded payload count i source_frontend main streams_json stream import_choice
    local frontend parsed proto domain port path share_answer mode clean_domain conf_path overwrite_answer
    local runner progress_label existing duplicate
    local -a import_sources=() import_frontends=() import_mains=() import_streams=()
    local -a import_modes=() import_no_redirect=() import_tls_verify=()
    local -a success_links=() failed_links=() skipped_links=() seen_frontends=()

    echo
    read -r -p '请粘贴 NGINXPROXY Base64 字符串: ' encoded
    if ! payload=$(decode_transfer_payload "$encoded"); then
        return 0
    fi
    if ! validate_transfer_payload_urls "$payload"; then
        return 0
    fi
    count=$(jq -r '.links | length' <<<"$payload" | tr -d '\r')
    echo
    log_info "已识别 ${count} 条反代链路。先收集目标域名与分流选择，再依次部署。"

    for ((i=0; i<count; i++)); do
        source_frontend=$(jq -r --argjson i "$i" '.links[$i].source_frontend' <<<"$payload" | tr -d '\r')
        main=$(jq -r --argjson i "$i" '.links[$i].main' <<<"$payload" | tr -d '\r')
        streams_json=$(jq -c --argjson i "$i" '.links[$i].streams' <<<"$payload")
        echo
        echo -e "${BLUE}[$((i + 1))/$count] 来源链路: ${source_frontend} -> ${main}${NC}"
        while IFS= read -r stream; do
            echo "    推流: $stream"
        done < <(jq -r '.[]' <<<"$streams_json" | tr -d '\r')
        read -r -p '是否导入此链路？[Y/n]: ' import_choice
        if [[ $import_choice =~ ^[Nn]$ ]]; then
            skipped_links+=("$source_frontend")
            continue
        fi

        while true; do
            read -r -p '请输入此链路在本机供客户端访问的域名或完整 URL: ' frontend
            if ! frontend=$(normalize_import_frontend "$frontend"); then
                log_warn '访问地址无效；可输入 emby.example.com 或 https://emby.example.com:443。'
                continue
            fi
            parsed=$(parse_url "$frontend") || continue
            IFS='|' read -r proto domain port path <<<"$parsed"
            port=${port:-$(get_default_port "$proto")}

            duplicate=no
            for existing in "${seen_frontends[@]}"; do
                if [[ ${existing,,} == "${frontend,,}" ]]; then duplicate=yes; break; fi
            done
            if [[ $duplicate == yes ]]; then
                log_warn '该目标访问地址已被本次导入中的另一条链路使用，请更换。'
                continue
            fi

            clean_domain=${domain//[\[\]]/}
            conf_path="/etc/nginx/conf.d/${clean_domain}.${port}.conf"
            if [[ -e $conf_path ]]; then
                if ! grep -Fqx '# Generated by deploy-stream-domains.sh' "$conf_path"; then
                    log_error "目标配置已存在且不属于本脚本，拒绝覆盖: $conf_path"
                    continue
                fi
                log_warn "目标链路已存在，导入成功后将更新它: $conf_path"
                read -r -p '确认更新现有链路？[y/N]: ' overwrite_answer
                [[ $overwrite_answer =~ ^[Yy]$ ]] || continue
            fi

            while true; do
                read -r -p '是否使用 HAProxy SNI 分流？[Y/n]: ' share_answer
                if [[ $share_answer =~ ^[Nn]$ ]]; then
                    mode=direct
                    break
                fi
                if [[ $proto != https || $port != 443 ]] || is_ip_address "$domain"; then
                    log_warn 'HAProxy SNI 分流要求客户端地址为 HTTPS 域名且端口为 443；请选择 n 或重新输入访问地址。'
                    continue
                fi
                if [[ ! -x $SNI_ROUTER_BIN ]]; then
                    log_warn "未找到 ${SNI_ROUTER_BIN}；请先安装同仓库 sb.sh，或选择 n 使用 Nginx 直连。"
                    continue
                fi
                mode=haproxy
                break
            done
            break
        done

        seen_frontends+=("$frontend")
        import_sources+=("$source_frontend")
        import_frontends+=("$frontend")
        import_mains+=("$main")
        import_streams+=("$streams_json")
        import_modes+=("$mode")
        import_no_redirect+=("$(jq -r --argjson i "$i" 'if .links[$i].no_proxy_redirect then "yes" else "no" end' <<<"$payload" | tr -d '\r')")
        import_tls_verify+=("$(jq -r --argjson i "$i" 'if .links[$i].upstream_tls_verify then "yes" else "no" end' <<<"$payload" | tr -d '\r')")
    done

    if ((${#import_frontends[@]} == 0)); then
        log_info '没有选择需要导入的链路。'
        return 0
    fi
    if ! runner=$(current_script_path) || [[ ! -f $runner ]]; then
        log_error '无法定位当前脚本文件，不能启动独立导入任务。'
        return 1
    fi

    echo
    log_info "开始依次部署 ${#import_frontends[@]} 条链路；证书申请可能需要较长时间。"
    for i in "${!import_frontends[@]}"; do
        progress_label="${import_frontends[$i]} -> ${import_mains[$i]}"
        echo
        echo -e "${BLUE}========== 导入 $((i + 1))/${#import_frontends[@]}: ${progress_label} ==========${NC}"
        local -a deploy_command=(bash "$runner" -y "${import_frontends[$i]}" -r "${import_mains[$i]}" --frontend-mode "${import_modes[$i]}")
        while IFS= read -r stream; do
            deploy_command+=(-s "$stream")
        done < <(jq -r '.[]' <<<"${import_streams[$i]}" | tr -d '\r')
        [[ ${import_no_redirect[$i]} == yes ]] && deploy_command+=(--no-proxy-redirect)
        [[ ${import_tls_verify[$i]} == no ]] && deploy_command+=(--no-upstream-tls-verify)

        if "${deploy_command[@]}"; then
            success_links+=("$progress_label")
        else
            failed_links+=("$progress_label")
        fi
    done

    echo
    echo -e "${BLUE}--- 批量导入结果 ---${NC}"
    if ((${#success_links[@]})); then
        echo '成功:'
        printf '  - %s\n' "${success_links[@]}"
    fi
    if ((${#failed_links[@]})); then
        echo '失败:'
        printf '  - %s\n' "${failed_links[@]}"
    fi
    if ((${#skipped_links[@]})); then
        echo '跳过:'
        printf '  - %s\n' "${skipped_links[@]}"
    fi
    if ((${#failed_links[@]} == 0)); then
        log_success "选择的 ${#success_links[@]} 条反代链路已全部导入成功。"
    else
        log_warn "导入完成：成功 ${#success_links[@]} 条，失败 ${#failed_links[@]} 条。失败链路已在上方列出。"
    fi
}

link_transfer_menu() {
    local action
    show_managed_links
    echo
    echo '  [1] 导出当前反代链路为 Base64'
    echo '  [2] 从其他机器的 Base64 导入链路'
    echo '  [0] 返回主菜单'
    read -r -p '请选择操作 [0-2]: ' action
    case $action in
        1) export_managed_links_base64 || true ;;
        2) import_links_from_base64 || true ;;
        0) return 0 ;;
        *) log_error '无效输入。' ;;
    esac
}

reset_proxy_inputs() {
    you_domain_full=''
    r_domain_full=''
    you_domain=''
    you_domain_path=''
    you_frontend_port=''
    no_tls=''
    r_domain=''
    r_domain_path=''
    r_frontend_port=''
    r_http_frontend=''
    cert_domain=''
    manual_resolver=''
    parse_cert_domain='no'
    dns_provider=''
    cf_token=''
    cf_account_id=''
    no_proxy_redirect='no'
    upstream_tls_verify='yes'
    format_cert_domain=''
    resolver=''
    frontend_mode='direct'
    frontend_mode_explicit='yes'
    reuse_existing_certificate='no'
    sni_route_registered='no'
    sni_route_preexisting='no'
    stream_input_urls=()
    stream_protocols=()
    stream_domains=()
    stream_ports=()
    stream_base_paths=()
    stream_origins=()
    stream_origins_no_default_port=()
}

load_managed_link_for_edit() {
    local index=$1 conf frontend cert_path cert_key_path cert_name setting
    conf=${managed_link_configs[$index]}
    frontend=${managed_link_frontends[$index]}
    [[ $frontend == http://* || $frontend == https://* ]] || {
        log_error "无法从配置中识别前端地址，不能安全修改: $conf"
        return 1
    }

    reset_proxy_inputs
    process_url_input "$frontend" you || return 1

    if grep -Eq '^# sb-sni-router: ' "$conf"; then
        frontend_mode=haproxy
    fi

    cert_path=$(awk '/ssl_certificate[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' "$conf")
    cert_key_path=$(awk '/ssl_certificate_key[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' "$conf")
    if [[ -n $cert_path ]]; then
        cert_name=$(basename "$(dirname "$cert_path")")
        [[ $cert_name == "$you_domain" ]] || cert_domain=$cert_name
        if [[ -s $cert_path && -n $cert_key_path && -s $cert_key_path ]]; then
            reuse_existing_certificate=yes
        fi
    fi

    setting=$(sed -n 's/^# nginxproxy-no-proxy-redirect: //p' "$conf" | head -n 1)
    if [[ $setting == yes || $setting == no ]]; then
        no_proxy_redirect=$setting
    elif ! grep -Eq 'proxy_redirect.*\$emby_public_host' "$conf"; then
        no_proxy_redirect=yes
    fi

    setting=$(sed -n 's/^# nginxproxy-upstream-tls-verify: //p' "$conf" | head -n 1)
    if [[ $setting == yes || $setting == no ]]; then
        upstream_tls_verify=$setting
    elif ! grep -Eq '^[[:space:]]*proxy_ssl_verify on;' "$conf"; then
        upstream_tls_verify=no
    fi
}

prompt_replacement_upstreams() {
    local current_main=$1 input_r input_stream
    echo -e "\n${BLUE}--- 修改反代链路 ---${NC}"
    echo "前端地址保持不变: $you_domain_full"
    echo "当前 Emby 主站: $current_main"
    echo '请重新输入主站和全部推流源站；推流直接回车表示不再单独配置。'

    while true; do
        read -r -p '请输入新的 Emby 主地址（登录/API 地址）: ' input_r
        if process_url_input "$input_r" r; then
            r_domain_full=$input_r
            break
        fi
        log_warn '主站 URL 无效，请输入以 http:// 或 https:// 开头的完整地址。'
    done

    while true; do
        read -r -p '请输入推流源站 URL（可重复输入，直接回车结束）: ' input_stream
        [[ -z ${input_stream//[[:space:]]/} ]] && break
        add_stream_url "$input_stream" || log_warn '该地址未添加，请重新输入。'
    done
}

manage_existing_link() {
    local selection action index current_main
    show_managed_links
    ((${#managed_link_configs[@]})) || return 0

    echo
    read -r -p '请选择链路编号（输入 0 返回）: ' selection
    [[ $selection == 0 ]] && return 0
    if [[ ! $selection =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#managed_link_configs[@]})); then
        log_error '链路编号无效。'
        return 0
    fi
    index=$((selection - 1))
    current_main=${managed_link_mains[$index]}

    echo
    echo "  [1] 修改该反代链路"
    echo "  [2] 删除该反代链路、其独占证书及续期记录"
    echo "  [0] 返回"
    read -r -p '请选择操作 [0-2]: ' action
    case $action in
        1)
            load_managed_link_for_edit "$index"
            you_domain_full=${managed_link_frontends[$index]}
            prompt_replacement_upstreams "$current_main"
            run_proxy_deployment
            pause_for_menu
            if [[ -x $QUICK_COMMAND_PATH ]]; then
                exec "$QUICK_COMMAND_PATH"
            fi
            ;;
        2)
            domain_to_remove=${managed_link_frontends[$index]}
            force_yes=no
            ( remove_domain_config )
            ;;
        0) return 0 ;;
        *)
            log_error '无效输入。'
            return 0
            ;;
    esac
}

parse_arguments() {
    local temp
    temp=$(getopt -o y:r:s:m:R:dD:hY --long you-domain:,r-domain:,stream-domain:,cert-domain:,resolver:,parse-cert-domain,dns:,cf-token:,cf-account-id:,gh-proxy:,remove:,yes,no-proxy-redirect,no-upstream-tls-verify,frontend-mode:,sni-router,install-command,version,help -n "$(basename "$0")" -- "$@") || exit 1
    eval set -- "$temp"

    while true; do
        case $1 in
            -y|--you-domain) you_domain_full=$2; shift 2 ;;
            -r|--r-domain) r_domain_full=$2; shift 2 ;;
            -s|--stream-domain) stream_input_urls+=("$2"); shift 2 ;;
            -m|--cert-domain) cert_domain=$2; shift 2 ;;
            -R|--resolver) manual_resolver=$2; shift 2 ;;
            -d|--parse-cert-domain) parse_cert_domain=yes; shift ;;
            -D|--dns) dns_provider=$2; shift 2 ;;
            --cf-token) cf_token=$2; shift 2 ;;
            --cf-account-id) cf_account_id=$2; shift 2 ;;
            --gh-proxy) manual_gh_proxy=$2; shift 2 ;;
            --remove) domain_to_remove=$2; shift 2 ;;
            -Y|--yes) force_yes=yes; shift ;;
            --no-proxy-redirect) no_proxy_redirect=yes; shift ;;
            --no-upstream-tls-verify) upstream_tls_verify=no; shift ;;
            --frontend-mode) frontend_mode=${2,,}; frontend_mode_explicit=yes; shift 2 ;;
            --sni-router) frontend_mode=haproxy; frontend_mode_explicit=yes; shift ;;
            --install-command) install_command_only=yes; shift ;;
            --version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help) show_help; exit 0 ;;
            --) shift; break ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done

    [[ -n $you_domain_full ]] && process_url_input "$you_domain_full" you
    [[ -n $r_domain_full ]] && process_url_input "$r_domain_full" r
    if [[ -n $dns_provider && ! $dns_provider =~ ^[A-Za-z0-9_]+$ ]]; then
        log_error "DNS provider 名称无效: $dns_provider"
        exit 1
    fi
    if [[ -n $cf_token ]]; then
        log_warn '--cf-token 可能进入 shell 历史；建议改用 CF_Token 环境变量。'
    fi

    # Rebuild the stream arrays from the raw repeated options.
    local -a raw_streams=("${stream_input_urls[@]:-}")
    stream_input_urls=()
    local item
    for item in "${raw_streams[@]}"; do
        [[ -n $item ]] && add_stream_url "$item"
    done
    return 0
}

prompt_interactive_mode() {
    local entered_interactive_mode=no

    if [[ -z $you_domain || -z $r_domain ]]; then
        if [[ ! -t 0 ]]; then
            log_error "无法进入交互模式，请至少提供 -y 和 -r 参数。"
            exit 1
        fi

        entered_interactive_mode=yes
        echo -e "\n${BLUE}--- 交互模式: 配置 Emby 反向代理 ---${NC}"
        local input_you input_r
        read -r -p "请输入要访问的地址（例如 https://emby.example.com:443）: " input_you
        read -r -p "请输入要反代的 Emby 主地址（登录/API 地址）: " input_r
        process_url_input "$input_you" you
        process_url_input "$input_r" r
    fi

    # Preserve the original behavior: when -y and -r are both supplied, the
    # script remains fully non-interactive. Streaming URLs can then be supplied
    # with repeated -s/--stream-domain options.
    if [[ $entered_interactive_mode == yes ]]; then
        echo
        echo -e "${BLUE}可选：添加独立的推流/CDN 源站。${NC}"
        echo "可连续输入多个完整 URL；不需要添加或输入完毕时，直接回车结束。"
        local input_stream=''
        while true; do
            read -r -p "请输入推流源站 URL（直接回车结束）: " input_stream
            [[ -z ${input_stream//[[:space:]]/} ]] && break
            add_stream_url "$input_stream" || log_warn "该地址未添加，请重新输入。"
        done
    fi

    if [[ $frontend_mode_explicit != yes && -t 0 && $no_tls != yes && $you_frontend_port == 443 ]] && \
       ! is_ip_address "$you_domain" && [[ -x $SNI_ROUTER_BIN ]]; then
        local share_answer=''
        echo
        echo -e "${BLUE}检测到 sb.sh，可由 HAProxy 按 SNI 让 Emby 与 Reality 复用公网 443。${NC}"
        echo "要求 Emby 域名与 Reality SNI 不同；Nginx 将只监听 ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT}。"
        read -r -p '是否启用 443 SNI 分流？[Y/n]: ' share_answer
        if [[ ! $share_answer =~ ^[Nn]$ ]]; then
            frontend_mode=haproxy
        fi
    fi
}

prepare_summary_values() {
    local normalized_resolver='' cert_prefix=''
    if is_ip_address "$you_domain"; then
        format_cert_domain=${you_domain//[\[\]]/}
    elif [[ -n $cert_domain ]]; then
        format_cert_domain=$cert_domain
    elif [[ $parse_cert_domain == yes && $you_domain == *.*.* ]]; then
        format_cert_domain=${you_domain#*.}
    else
        format_cert_domain=$you_domain
    fi

    if [[ $no_tls != yes ]] && ! is_ip_address "$you_domain" && ! is_valid_dns_name "$format_cert_domain"; then
        log_error "证书域名无效: $format_cert_domain"
        return 1
    fi
    if [[ $no_tls != yes && $format_cert_domain != "$you_domain" ]] && ! is_ip_address "$you_domain"; then
        if [[ $you_domain != *."$format_cert_domain" ]]; then
            log_error "前端域名不属于证书域名: $you_domain / $format_cert_domain"
            return 1
        fi
        cert_prefix=${you_domain%."$format_cert_domain"}
        if [[ -z $cert_prefix || $cert_prefix == *.* ]]; then
            log_error "*.${format_cert_domain} 不能覆盖多级前端域名: $you_domain"
            return 1
        fi
    fi

    if [[ -n $manual_resolver ]]; then
        normalized_resolver=$(normalize_resolver_list "$manual_resolver") || {
            log_error "Nginx resolver 无效；只允许 IPv4/IPv6 地址及可选端口: $manual_resolver"
            return 1
        }
        resolver="$normalized_resolver valid=60s"
    else
        resolver=$(get_resolver_host)
        if ! has_ipv6; then
            resolver+=" ipv6=off"
        fi
        resolver+=" valid=60s"
    fi
}

display_summary() {
    prepare_summary_values || return 1
    validate_frontend_mode || return 1
    local front_proto upstream_proto i
    front_proto=$(get_protocol "$no_tls")
    upstream_proto=$(get_protocol "$r_http_frontend")

    echo -e "\n${BLUE}Nginx 反代配置摘要${NC}"
    echo '──────────────────────────────────────────────'
    echo -e "前端访问: ${GREEN}${front_proto}://${you_domain}:${you_frontend_port}${you_domain_path}${NC}"
    echo -e "Emby 主站: ${YELLOW}${upstream_proto}://${r_domain}:${r_frontend_port}${r_domain_path}${NC}"
    if ((${#stream_origins[@]})); then
        echo '推流源站:'
        for i in "${!stream_origins[@]}"; do
            echo "  $((i + 1)). ${stream_origins[$i]}"
        done
    else
        echo '推流源站: 未单独配置，将仅代理主站'
    fi
    echo "证书域名: $format_cert_domain"
    echo "DNS resolver: $resolver"
    echo -e "TLS: $([[ $no_tls == yes ]] && echo "${RED}关闭${NC}" || echo "${GREEN}开启${NC}")"
    if [[ $frontend_mode == haproxy ]]; then
        echo "443 入口: HAProxy SNI 分流 -> ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT} (PROXY v2)"
    else
        echo '443 入口: Nginx 直接监听'
    fi
    echo '──────────────────────────────────────────────'
}

install_dependencies() {
    local id_like='' os_id='' pm=''
    local -a required_packages=()
    local dependencies_ready=yes
    local required_command
    for required_command in nginx curl socat openssl envsubst tar sha256sum timeout jq base64; do
        command -v "$required_command" >/dev/null 2>&1 || dependencies_ready=no
    done
    command -v crontab >/dev/null 2>&1 || dependencies_ready=no
    if [[ $upstream_tls_verify == yes && ! -r /etc/ssl/certs/ca-certificates.crt ]]; then
        dependencies_ready=no
    fi

    if [[ $dependencies_ready == yes ]]; then
        log_info "Nginx 和依赖已安装，跳过软件包安装。"
        $SUDO mkdir -p /etc/nginx/conf.d /etc/nginx/certs "$BACKUP_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
        if ! nginx_is_running; then
            start_nginx || log_warn 'Nginx 当前未运行；将在配置完成后再次尝试启动。'
        fi
        return 0
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id=${ID:-}
        id_like=${ID_LIKE:-}
    fi

    if command -v apt-get >/dev/null 2>&1; then
        pm=apt
        required_packages=(nginx curl ca-certificates socat cron openssl gettext-base tar coreutils jq)
        $SUDO apt-get update
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${required_packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        pm=dnf
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext coreutils jq)
        $SUDO dnf install -y "${required_packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        pm=yum
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext coreutils jq)
        $SUDO yum install -y "${required_packages[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pm=pacman
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext coreutils jq)
        $SUDO pacman -Sy --noconfirm "${required_packages[@]}"
    elif command -v apk >/dev/null 2>&1; then
        pm=apk
        required_packages=(nginx curl ca-certificates socat dcron openssl gettext coreutils jq)
        $SUDO apk add --no-cache "${required_packages[@]}"
    else
        log_error "不支持的系统，无法识别包管理器。ID=${os_id}, ID_LIKE=${id_like}"
        exit 1
    fi

    log_info "依赖安装完成，包管理器: $pm"
    $SUDO mkdir -p /etc/nginx/conf.d /etc/nginx/certs "$BACKUP_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"

    if has_systemd; then
        $SUDO systemctl enable nginx >/dev/null 2>&1 || true
    fi
    if ! nginx_is_running; then
        start_nginx || log_warn 'Nginx 当前未运行；将在配置完成后再次尝试启动。'
    fi
}

ensure_http_include() {
    local main_conf=/etc/nginx/nginx.conf
    [[ -f $main_conf ]] || { log_error "未找到 $main_conf"; return 1; }

    if grep -Eq 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$main_conf"; then
        return 0
    fi

    backup_file "$main_conf"
    local tmp
    tmp=$(mktemp)

    # Insert the include immediately before the closing brace of http {}.
    awk '
        BEGIN {in_http=0; depth=0; inserted=0}
        {
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)

            if (!in_http && $0 ~ /^[[:space:]]*http[[:space:]]*\{/) {
                in_http=1
                depth=opens-closes
                print $0
                next
            }

            if (in_http) {
                if (depth==1 && $0 ~ /^[[:space:]]*}[[:space:]]*$/ && !inserted) {
                    print "    include /etc/nginx/conf.d/*.conf;"
                    inserted=1
                }
                depth += opens-closes
                if (depth==0) in_http=0
            }
            print $0
        }
        END {if (!inserted) exit 12}
    ' "$main_conf" > "$tmp" || {
        rm -f "$tmp"
        log_error "无法自动向 nginx.conf 添加 conf.d include。"
        return 1
    }

    stage_file_install "$tmp" "$main_conf"
    rm -f "$tmp"
    log_success "已向 nginx.conf 添加 /etc/nginx/conf.d/*.conf"
}

install_acme() {
    [[ $no_tls == yes ]] && return 0
    local current_version=''
    if [[ -x $ACME_SH ]]; then
        current_version=$("$ACME_SH" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 || true)
        if [[ -n $current_version ]] && version_at_least "$current_version" "$ACME_VERSION"; then
            "$ACME_SH" --set-default-ca --server letsencrypt
            return 0
        fi
        log_warn "现有 acme.sh 版本过旧或无法识别，将安装固定版本 ${ACME_VERSION}。"
    fi

    setup_download_urls
    log_info "安装 acme.sh ${ACME_VERSION}..."
    local archive extract_dir source_dir install_status=0
    archive=$(mktemp)
    extract_dir=$(mktemp -d /tmp/acme-install.XXXXXXXXXX)
    if ! curl -fsSL "$ACME_INSTALL_URL" -o "$archive"; then
        rm -f "$archive"
        cleanup_acme_extract_dir "$extract_dir"
        log_error "下载 acme.sh 失败: $ACME_INSTALL_URL"
        return 1
    fi
    if ! printf '%s  %s\n' "$ACME_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null; then
        rm -f "$archive"
        cleanup_acme_extract_dir "$extract_dir"
        log_error 'acme.sh 归档 SHA-256 校验失败，拒绝执行。'
        return 1
    fi
    tar -xzf "$archive" -C "$extract_dir"
    source_dir="$extract_dir/acme.sh-${ACME_VERSION}"
    [[ -f $source_dir/acme.sh ]] || {
        rm -f "$archive"
        cleanup_acme_extract_dir "$extract_dir"
        log_error 'acme.sh 归档结构无效。'
        return 1
    }
    HOME=$ROOT_HOME sh "$source_dir/acme.sh" --install || install_status=$?
    rm -f "$archive"
    cleanup_acme_extract_dir "$extract_dir"
    (( install_status == 0 )) || return "$install_status"
    "$ACME_SH" --set-default-ca --server letsencrypt
}

acme_cert_is_issued() {
    local info cert_path
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    cert_path=$(sed -n 's/^Le_RealFullChainPath=//p' <<<"$info" | head -n 1)
    cert_path=${cert_path#\'}
    cert_path=${cert_path%\'}
    [[ -n $cert_path && -s $cert_path ]]
}

acme_has_renewal_hooks() {
    local info
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    grep -Eq '^Le_PreHook=.+$' <<<"$info" && grep -Eq '^Le_PostHook=.+$' <<<"$info"
}

acme_uses_webroot() {
    local info webroot
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    webroot=$(sed -n 's/^Le_Webroot=//p' <<<"$info" | head -n 1)
    webroot=${webroot#\'}
    webroot=${webroot%\'}
    [[ $webroot == "$ACME_WEBROOT" ]]
}

prepare_acme_webroot() {
    [[ $frontend_mode == haproxy && -z $dns_provider ]] || return 0
    [[ $format_cert_domain == "$you_domain" ]] || {
        log_error '泛域名证书不能使用 HTTP-01；请通过 -D 指定 DNS API。'
        return 1
    }
    ensure_http_include || return 1

    local safe_domain=${you_domain,,}
    safe_domain=${safe_domain//[^a-z0-9.-]/_}
    local conf_path="/etc/nginx/conf.d/00-emby-acme-${safe_domain}.conf"
    local tmp
    tmp=$(mktemp)
    {
        echo '# Generated by deploy-stream-domains.sh (ACME webroot)'
        echo "# sb-sni-router-domain: ${you_domain,,}"
        echo 'server {'
        echo '    listen 80;'
        ipv6_stack_available && echo '    listen [::]:80;'
        echo "    server_name ${you_domain,,};"
        echo '    location ^~ /.well-known/acme-challenge/ {'
        echo "        root ${ACME_WEBROOT};"
        echo '        default_type text/plain;'
        echo '        try_files $uri =404;'
        echo '    }'
        echo '    location / { return 404; }'
        echo '}'
    } > "$tmp"
    backup_file "$conf_path"
    stage_file_install "$tmp" "$conf_path"
    rm -f "$tmp"

    if ! test_and_reload_nginx; then
        log_error 'HTTP-01 webroot 配置未通过 Nginx 验证。'
        return 1
    fi
    log_success "证书续期入口已配置: http://${you_domain}/.well-known/acme-challenge/"
}

cleanup_stale_acme_record() {
    [[ -x $ACME_SH ]] || return 0
    "$ACME_SH" --remove -d "$format_cert_domain" --ecc >/dev/null 2>&1 || true
    "$ACME_SH" --remove -d "$format_cert_domain" >/dev/null 2>&1 || true
}

issue_certificate() {
    [[ $no_tls == yes ]] && return 0
    install_acme

    local cert_dir="/etc/nginx/certs/${format_cert_domain}"
    local issue_extra=()
    local domain_args=(-d "$format_cert_domain")
    local cert_exists=no need_issue=yes issue_status=0
    local -a force_args=()

    if is_ip_address "$you_domain"; then
        issue_extra+=(--certificate-profile shortlived --days 6)
        [[ $you_domain == *:* ]] && issue_extra+=(--listen-v6)
        dns_provider=''
    elif [[ $format_cert_domain != "$you_domain" ]]; then
        domain_args+=(-d "*.${format_cert_domain}")
    fi

    if acme_cert_is_issued; then
        cert_exists=yes
        need_issue=no
    fi

    if [[ -z $dns_provider && $cert_exists == yes ]]; then
        if [[ $frontend_mode == haproxy ]] && ! acme_uses_webroot; then
            log_warn '现有证书不是 webroot 续期方式，将强制续签一次以迁移。'
            need_issue=yes
            force_args+=(--force)
        elif [[ $frontend_mode != haproxy ]] && ! acme_has_renewal_hooks; then
            log_warn '现有 standalone 证书缺少续期停启 hook，将强制续签一次以补全。'
            need_issue=yes
            force_args+=(--force)
        fi
    fi

    if [[ $need_issue == yes ]]; then
        if [[ $cert_exists != yes ]]; then
            cleanup_stale_acme_record
            # acme.sh --remove intentionally keeps an existing domain key.
            # A recovery issue must explicitly allow reusing/overwriting it.
            force_args+=(--force)
        fi
        log_info "申请证书: $format_cert_domain"
        if [[ -n $dns_provider ]]; then
            if [[ $dns_provider == cf ]]; then
                [[ -n $cf_token ]] && export CF_Token=$cf_token
                [[ -n $cf_account_id ]] && export CF_Account_ID=$cf_account_id
                if [[ -z ${CF_Token:-} && -t 0 ]]; then
                    read -r -s -p 'Cloudflare Token: ' CF_Token
                    echo
                fi
                if [[ -z ${CF_Account_ID:-} && -t 0 ]]; then
                    read -r -p 'Cloudflare Account ID: ' CF_Account_ID
                fi
                if [[ -z ${CF_Token:-} || -z ${CF_Account_ID:-} ]]; then
                    log_error 'Cloudflare DNS 模式需要 CF_Token 和 CF_Account_ID。'
                    return 1
                fi
                export CF_Token CF_Account_ID
            fi
            "$ACME_SH" --issue --dns "dns_${dns_provider}" "${domain_args[@]}" --keylength ec-256 \
                "${force_args[@]}"
        elif [[ $frontend_mode == haproxy ]]; then
            if [[ $format_cert_domain != "$you_domain" ]] && ! is_ip_address "$you_domain"; then
                log_error "泛域名证书必须通过 -D 指定 DNS API 模式。"
                return 1
            fi
            log_info '使用 Nginx 80 端口的 HTTP-01 webroot 验证；续期不会停止 HAProxy 或 Nginx。'
            "$ACME_SH" --issue --webroot "$ACME_WEBROOT" "${domain_args[@]}" --keylength ec-256 \
                "${issue_extra[@]}" "${force_args[@]}"
        else
            if [[ $format_cert_domain != "$you_domain" ]] && ! is_ip_address "$you_domain"; then
                log_error "泛域名证书必须通过 -D 指定 DNS API 模式。"
                return 1
            fi

            log_info 'Standalone 验证会临时停止 Nginx，并为后续续期保存相同的停启 hook。'
            "$ACME_SH" --issue --standalone "${domain_args[@]}" --keylength ec-256 \
                --pre-hook "$ACME_NGINX_PRE_HOOK" \
                --post-hook "$ACME_NGINX_POST_HOOK" \
                "${issue_extra[@]}" "${force_args[@]}" || issue_status=$?
            if ! nginx_is_running; then
                start_nginx || log_warn '证书签发结束后未能自动恢复 Nginx。'
            fi
            (( issue_status == 0 )) || return "$issue_status"
        fi
    fi

    $SUDO mkdir -p "$cert_dir"
    "$ACME_SH" --install-cert -d "$format_cert_domain" --ecc \
        --fullchain-file "$cert_dir/cert" \
        --key-file "$cert_dir/key" \
        --reloadcmd "$ACME_NGINX_RELOAD_CMD"
}

nginx_quote_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf '%s' "$value"
}


stream_indices_by_specificity() {
    local i
    for i in "${!stream_origins[@]}"; do
        printf '%09d %s\n' "${#stream_origins[$i]}" "$i"
    done | sort -rn | awk '{print $2}'
}

# Append all configured stream URL body rewrites to the requested file.
append_stream_sub_filters() {
    local file=$1
    local i public_prefix escaped_public_prefix origin origin_no_default escaped_origin escaped_origin_no_default
    while IFS= read -r i; do
        [[ -n $i ]] || continue
        public_prefix="\$scheme://\$emby_public_host:\$emby_public_port/__emby_stream/$((i + 1))"
        escaped_public_prefix="\$scheme:\\/\\/\$emby_public_host:\$emby_public_port\/__emby_stream\/$((i + 1))"
        origin=$(nginx_quote_escape "${stream_origins[$i]}")
        origin_no_default=$(nginx_quote_escape "${stream_origins_no_default_port[$i]}")
        escaped_origin=${origin//\//\\/}
        escaped_origin_no_default=${origin_no_default//\//\\/}
        {
            printf "        sub_filter '%s' '%s';\n" "$origin" "$public_prefix"
            printf "        sub_filter '%s' '%s';\n" "$escaped_origin" "$escaped_public_prefix"
            if [[ $origin_no_default != "$origin" ]]; then
                printf "        sub_filter '%s' '%s';\n" "$origin_no_default" "$public_prefix"
                printf "        sub_filter '%s' '%s';\n" "$escaped_origin_no_default" "$escaped_public_prefix"
            fi
        } >> "$file"
    done < <(stream_indices_by_specificity)
}

# Append exact Location-header rewrites for all configured stream origins.
append_stream_proxy_redirects() {
    local file=$1
    local i origin origin_no_default public_prefix
    while IFS= read -r i; do
        [[ -n $i ]] || continue
        origin=$(nginx_quote_escape "${stream_origins[$i]}")
        origin_no_default=$(nginx_quote_escape "${stream_origins_no_default_port[$i]}")
        public_prefix="\$scheme://\$emby_public_host:\$emby_public_port/__emby_stream/$((i + 1))"
        {
            printf "        proxy_redirect '%s/' '%s/';\n" "$origin" "$public_prefix"
            if [[ $origin_no_default != "$origin" ]]; then
                printf "        proxy_redirect '%s/' '%s/';\n" "$origin_no_default" "$public_prefix"
            fi
        } >> "$file"
    done < <(stream_indices_by_specificity)
}

append_common_proxy_headers() {
    local file=$1
    cat >> "$file" <<'EOF'
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $emby_connection_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $emby_public_port;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
EOF
    if [[ $upstream_tls_verify == yes ]]; then
        cat >> "$file" <<'EOF'
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 5;
EOF
    fi
}

append_body_filter_preamble() {
    local file=$1
    if ((${#stream_origins[@]})); then
        cat >> "$file" <<'EOF'
        # Absolute streaming URLs may be embedded in Emby JSON or M3U8 bodies.
        # Disable upstream compression so ngx_http_sub_module can inspect them.
        proxy_set_header Accept-Encoding "";
        sub_filter_once off;
        sub_filter_types text/plain text/css application/json application/javascript application/x-javascript application/xml application/vnd.apple.mpegurl application/x-mpegurl;
EOF
        append_stream_sub_filters "$file"
    fi
}

generate_nginx_config() {
    ensure_http_include

    local map_conf=/etc/nginx/conf.d/00-emby-connection-map.conf
    local map_tmp
    map_tmp=$(mktemp)
    cat > "$map_tmp" <<'EOF'
map $http_upgrade $emby_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    backup_file "$map_conf"
    stage_file_install "$map_tmp" "$map_conf"
    rm -f "$map_tmp"

    local clean_domain=${you_domain//[\[\]]/}
    local conf_path="/etc/nginx/conf.d/${clean_domain}.${you_frontend_port}.conf"
    local tmp_conf
    tmp_conf=$(mktemp)

    local front_path=${you_domain_path:-/}
    [[ $front_path == */ ]] || front_path="${front_path}/"
    local front_exact=${front_path%/}
    local front_path_regex
    front_path_regex=$(nginx_regex_escape "$front_path")

    local main_proto main_authority main_upstream main_base_path front_proto frontend_url main_url metadata_index
    main_proto=$(get_protocol "$r_http_frontend")
    main_authority="${r_domain}:${r_frontend_port}"
    main_base_path=${r_domain_path:-}
    main_upstream="${main_proto}://${main_authority}"
    front_proto=$(get_protocol "$no_tls")
    frontend_url="${front_proto}://${you_domain}:${you_frontend_port}${you_domain_path}"
    main_url="${main_upstream}${main_base_path}"

    local modern_http2=no
    nginx_supports_http2_directive && modern_http2=yes

    {
        echo '# Generated by deploy-stream-domains.sh'
        echo '# Main upstream and fixed streaming upstreams are explicitly listed.'
        echo '# nginxproxy-link-version: 1'
        echo "# nginxproxy-frontend: ${frontend_url}"
        echo "# nginxproxy-main: ${main_url}"
        for metadata_index in "${!stream_origins[@]}"; do
            echo "# nginxproxy-stream: ${stream_origins[$metadata_index]}"
        done
        echo "# nginxproxy-no-proxy-redirect: ${no_proxy_redirect}"
        echo "# nginxproxy-upstream-tls-verify: ${upstream_tls_verify}"
        [[ $frontend_mode == haproxy ]] && echo "# sb-sni-router: ${you_domain,,} ${SNI_ROUTER_OWNER} ${SNI_ROUTER_BACKEND_PORT}"
        echo 'server {'
        if [[ $frontend_mode == haproxy ]]; then
            if [[ $modern_http2 == yes ]]; then
                echo "    listen ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT} ssl proxy_protocol;"
                echo '    http2 on;'
            else
                echo "    listen ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT} ssl http2 proxy_protocol;"
            fi
            echo "    set_real_ip_from ${SNI_ROUTER_BACKEND_HOST};"
            echo '    real_ip_header proxy_protocol;'
        elif [[ $no_tls == yes ]]; then
            echo "    listen ${you_frontend_port};"
            ipv6_stack_available && echo "    listen [::]:${you_frontend_port};"
        else
            if [[ $modern_http2 == yes ]]; then
                echo "    listen ${you_frontend_port} ssl;"
                ipv6_stack_available && echo "    listen [::]:${you_frontend_port} ssl;"
                echo '    http2 on;'
            else
                echo "    listen ${you_frontend_port} ssl http2;"
                ipv6_stack_available && echo "    listen [::]:${you_frontend_port} ssl http2;"
            fi
        fi
        if [[ $you_domain == \[*\] ]]; then
            echo '    server_name _;'
        else
            echo "    server_name ${you_domain};"
        fi
        echo "    set \$emby_public_host '${you_domain}';"
        echo "    set \$emby_public_port '${you_frontend_port}';"
        echo
        if [[ $no_tls != yes ]]; then
            echo "    ssl_certificate /etc/nginx/certs/${format_cert_domain}/cert;"
            echo "    ssl_certificate_key /etc/nginx/certs/${format_cert_domain}/key;"
            echo '    ssl_protocols TLSv1.2 TLSv1.3;'
            echo '    ssl_session_cache shared:SSL:10m;'
            echo '    ssl_session_timeout 1h;'
            echo
        fi
        echo "    resolver ${resolver};"
        echo '    resolver_timeout 5s;'
        echo '    client_max_body_size 500m;'
        echo '    client_header_timeout 1h;'
        echo '    keepalive_timeout 30m;'
        echo
    } >> "$tmp_conf"

    # Fixed, numbered streaming proxy locations.
    local i id proto domain port base_path upstream
    for i in "${!stream_origins[@]}"; do
        id=$((i + 1))
        proto=${stream_protocols[$i]}
        domain=${stream_domains[$i]}
        port=${stream_ports[$i]}
        base_path=${stream_base_paths[$i]}
        upstream="${proto}://${domain}:${port}"
        {
            echo "    # Streaming upstream ${id}: ${stream_origins[$i]}"
            echo "    location ^~ /__emby_stream/${id}/ {"
            echo "        set \$stream_upstream_${id} '${upstream}';"
            echo "        rewrite ^/__emby_stream/${id}/(.*)\$ \"${base_path}/\$1\" break;"
            echo "        proxy_pass \$stream_upstream_${id};"
            echo '        proxy_set_header Host $proxy_host;'
        } >> "$tmp_conf"
        append_common_proxy_headers "$tmp_conf"
        cat >> "$tmp_conf" <<'EOF'
        proxy_set_header Range $http_range;
        proxy_set_header If-Range $http_if_range;
        proxy_force_ranges on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
EOF
        append_body_filter_preamble "$tmp_conf"
        append_stream_proxy_redirects "$tmp_conf"
        {
            echo '    }'
            echo
        } >> "$tmp_conf"
    done

    # Main Emby login/API location.
    {
        if [[ $front_path != / ]]; then
            echo "    location = \"${front_exact}\" {"
            echo "        return 308 \"${front_exact}/\$is_args\$args\";"
            echo '    }'
            echo
        fi
        echo "    location \"${front_path}\" {"
        echo "        set \$emby_main_upstream '${main_upstream}';"
        if [[ $front_path != / ]]; then
            echo "        rewrite ^${front_path_regex}(.*)\$ \"${main_base_path}/\$1\" break;"
        elif [[ -n $main_base_path ]]; then
            echo "        rewrite ^/(.*)\$ \"${main_base_path}/\$1\" break;"
        fi
        echo '        proxy_pass $emby_main_upstream;'
        echo '        proxy_set_header Host $proxy_host;'
    } >> "$tmp_conf"
    append_common_proxy_headers "$tmp_conf"
    append_body_filter_preamble "$tmp_conf"
    append_stream_proxy_redirects "$tmp_conf"

    if [[ $no_proxy_redirect != yes ]]; then
        # Keep main-origin redirects behind this reverse proxy.
        local main_origin="${main_proto}://${r_domain}:${r_frontend_port}${main_base_path}"
        local main_origin_no_port=$main_origin
        local default_main_port
        default_main_port=$(get_default_port "$main_proto")
        if [[ $r_frontend_port == "$default_main_port" ]]; then
            main_origin_no_port="${main_proto}://${r_domain}${main_base_path}"
        fi
        {
            printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$emby_public_port%s/';\n" "$main_origin" "${front_path%/}"
            if [[ $main_origin_no_port != "$main_origin" ]]; then
                printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$emby_public_port%s/';\n" "$main_origin_no_port" "${front_path%/}"
            fi
        } >> "$tmp_conf"
    fi

    {
        echo '    }'
        echo '}'
    } >> "$tmp_conf"

    backup_file "$conf_path"
    stage_file_install "$tmp_conf" "$conf_path"
    rm -f "$tmp_conf"
    log_success "配置文件已生成: $conf_path"
}

test_and_reload_nginx() {
    log_info '测试 Nginx 配置...'
    if ! $SUDO nginx -t; then
        return 1
    fi
    reload_or_start_nginx
}

verify_sni_frontend() {
    [[ $frontend_mode == haproxy ]] || return 0
    local output
    output=$(printf '\n' | timeout 12 openssl s_client \
        -connect "127.0.0.1:443" -servername "$you_domain" \
        -verify_hostname "$you_domain" 2>&1 || true)
    if ! grep -Fq 'Verify return code: 0 (ok)' <<<"$output"; then
        log_error "HAProxy -> Nginx 的 TLS/SNI 端到端验证失败: $you_domain"
        return 1
    fi
    log_success 'HAProxy -> Nginx 的 TLS/SNI 端到端验证通过。'
}

remove_acme_ecc_record_and_files() {
    local cert_name=$1 acme_home candidate candidate_real
    [[ -x $ACME_SH ]] || return 0

    if ! "$ACME_SH" --remove -d "$cert_name" --ecc >/dev/null 2>&1; then
        log_warn "acme.sh 未能移除 ${cert_name} 的 ECC 续期记录；其内部证书文件已保留，请手动检查。"
        return 1
    fi

    acme_home=$(readlink -m -- "$(dirname "$ACME_SH")")
    candidate="${acme_home}/${cert_name}_ecc"
    candidate_real=$(readlink -m -- "$candidate")
    if [[ $(dirname "$candidate_real") != "$acme_home" || $(basename "$candidate_real") != "${cert_name}_ecc" ]]; then
        log_warn "acme.sh 证书目录校验失败，未删除内部文件: $candidate_real"
        return 1
    fi
    if [[ -d $candidate_real ]]; then
        rm -rf -- "$candidate_real"
    fi
    log_success "已移除证书续期记录及 acme.sh 内部文件: $cert_name"
}

remove_domain_config() {
    local parsed proto domain port path default_port clean_domain conf_path
    parsed=$(parse_url "$domain_to_remove") || {
        log_error '请使用完整 URL，例如 https://emby.example.com:443'
        exit 1
    }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto")
    port=${port:-$default_port}
    clean_domain=${domain//[\[\]]/}
    conf_path="/etc/nginx/conf.d/${clean_domain}.${port}.conf"

    if ! $SUDO test -f "$conf_path"; then
        log_error "未找到配置: $conf_path"
        exit 1
    fi
    if ! $SUDO grep -q '^# Generated by deploy-stream-domains.sh$' "$conf_path"; then
        log_error "拒绝删除非本脚本生成的配置: $conf_path"
        exit 1
    fi

    local router_sni='' router_owner='' router_backend='' router_removed=no router_status=''
    local router_marker
    router_marker=$($SUDO sed -n 's/^# sb-sni-router: \([^ ]*\) \([^ ]*\) \([0-9][0-9]*\)$/\1|\2|\3/p' "$conf_path" | head -n 1)
    if [[ -n $router_marker ]]; then
        IFS='|' read -r router_sni router_owner router_backend <<<"$router_marker"
        if [[ $router_owner != "$SNI_ROUTER_OWNER" || $router_backend != "$SNI_ROUTER_BACKEND_PORT" ]]; then
            log_error "共享 443 标记不符合当前脚本约定，拒绝自动删除: $router_marker"
            exit 1
        fi
    fi

    if [[ $force_yes != yes ]]; then
        if [[ ! -t 0 ]]; then
            log_error '非交互删除必须使用 --yes。'
            exit 1
        fi
        local answer
        read -r -p "确认删除 $conf_path？请输入 yes: " answer
        [[ $answer == yes ]] || { log_info '已取消。'; exit 0; }
    fi

    local cert_path cert_dir='' cert_dir_real='' cert_path_real='' cert_root cert_name refs
    cert_path=$($SUDO awk '/ssl_certificate[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' "$conf_path")
    if [[ -n $cert_path ]]; then
        cert_root=$(readlink -m /etc/nginx/certs)
        cert_path_real=$(readlink -m -- "$cert_path")
        cert_dir_real=$(dirname "$cert_path_real")
        if [[ $(dirname "$cert_dir_real") != "$cert_root" || $(basename "$cert_path_real") != cert ]]; then
            log_error "证书路径不在受管目录中，拒绝删除: $cert_path"
            exit 1
        fi
        cert_dir=$cert_dir_real
        cert_name=$(basename "$cert_dir_real")
    fi

    if [[ -n $router_sni ]]; then
        router_status=$(sni_router_call status) || exit 1
        if grep -Fqx "https=${router_sni} -> ${SNI_ROUTER_BACKEND_HOST}:${router_backend} (${router_owner})" <<<"$router_status"; then
            sni_router_call remove-https "$router_owner" "$router_sni" || exit 1
            router_removed=yes
            sni_route_removed_for_delete=yes
            sni_route_removed_domain=$router_sni
            sni_route_removed_owner=$router_owner
            sni_route_removed_backend=$router_backend
        else
            log_warn "HAProxy 中已没有 ${router_sni} 的受管路由，将继续删除 Nginx 配置。"
        fi
    fi

    stage_file_removal "$conf_path"
    local acme_conf="/etc/nginx/conf.d/00-emby-acme-${clean_domain,,}.conf"
    if [[ -n $router_sni && -f $acme_conf ]] && grep -q '^# Generated by deploy-stream-domains.sh (ACME webroot)$' "$acme_conf"; then
        stage_file_removal "$acme_conf"
    fi
    if ! test_and_reload_nginx; then
        rollback_config_changes || true
        restore_nginx_after_rollback
        if [[ $router_removed == yes ]]; then
            restore_removed_sni_route || log_error "Nginx 已恢复，但 HAProxy 路由恢复失败: $router_sni"
        fi
        log_error '删除后的 Nginx 配置测试或加载失败，已恢复原配置。'
        exit 1
    fi
    commit_config_changes
    sni_route_removed_for_delete=no

    if [[ -n $cert_path ]]; then
        refs=$($SUDO grep -RslF "$cert_path" /etc/nginx/conf.d 2>/dev/null || true)
        if [[ -z $refs ]]; then
            remove_acme_ecc_record_and_files "$cert_name" || true
            $SUDO rm -f -- "$cert_dir/cert" "$cert_dir/key"
            if ! $SUDO rmdir -- "$cert_dir" 2>/dev/null; then
                log_warn "证书目录中仍有其他文件，未递归删除: $cert_dir"
            fi
            log_success "已移除该链路的独占 Nginx 证书: $cert_name"
        else
            log_warn "证书仍被其他站点引用，已保留证书及续期记录: $cert_dir"
        fi
    fi

    log_success '配置已移除。'
}


validate_nginx_features() {
    if ((${#stream_origins[@]})) && ! nginx -V 2>&1 | grep -q -- '--with-http_sub_module'; then
        log_error "当前 Nginx 未编译 ngx_http_sub_module，无法改写 JSON/M3U8 中的推流 URL。"
        log_error "请安装带 --with-http_sub_module 的 Nginx 后重试。"
        return 1
    fi
    if [[ $frontend_mode == haproxy ]] && ! nginx -V 2>&1 | grep -q -- '--with-http_realip_module'; then
        log_error '当前 Nginx 未编译 ngx_http_realip_module，无法安全接收 HAProxy PROXY v2 客户端地址。'
        return 1
    fi
}

run_proxy_deployment() {
    prompt_interactive_mode
    [[ -n $you_domain && -n $r_domain ]] || { log_error '前端和主源站不能为空。'; exit 1; }
    display_summary
    install_dependencies
    validate_nginx_features
    if [[ $frontend_mode == haproxy ]]; then
        prepare_sni_router
        if [[ $reuse_existing_certificate != yes ]]; then
            prepare_acme_webroot
        fi
    fi
    if [[ $reuse_existing_certificate == yes ]]; then
        log_info "修改链路将复用现有证书及续期设置: $format_cert_domain"
    else
        issue_certificate
    fi
    generate_nginx_config

    if ! test_and_reload_nginx; then
        rollback_config_changes || true
        restore_nginx_after_rollback
        log_error 'Nginx 配置测试或加载失败，本次配置改动已回滚。'
        exit 1
    fi

    if ! register_sni_route || \
       { [[ $frontend_mode == haproxy ]] && ! sni_router_call check; } || \
       ! verify_sni_frontend; then
        rollback_new_sni_route || true
        rollback_config_changes || true
        restore_nginx_after_rollback
        log_error '共享 443 的端到端验证失败，本次 Nginx 与 HAProxy 路由改动已回滚。'
        exit 1
    fi

    commit_config_changes
    sni_route_registered=no
    local protocol
    protocol=$(get_protocol "$no_tls")
    log_success '部署成功！'
    echo -e "${GREEN}访问地址: ${protocol}://${you_domain}:${you_frontend_port}${you_domain_path}${NC}"
    [[ $frontend_mode == haproxy ]] && echo "公网 :443 -> HAProxy(SNI ${you_domain,,}) -> Nginx ${SNI_ROUTER_BACKEND_HOST}:${SNI_ROUTER_BACKEND_PORT}"
    [[ -x $QUICK_COMMAND_PATH ]] && echo '后续可直接运行: nginxproxy'
}

pause_for_menu() {
    [[ -t 0 ]] || return 0
    echo
    read -r -n 1 -s -p '按任意键返回主菜单...'
    echo
}

main_menu() {
    local choice
    while true; do
        if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        echo -e "${BLUE}"
        echo '  ╔═══════════════════════════════════════╗'
        echo '  ║          Nginx Emby 反代管理          ║'
        echo '  ╚═══════════════════════════════════════╝'
        echo -e "${NC}"
        echo -e "  版本: ${GREEN}${SCRIPT_VERSION}${NC}"
        echo
        echo -e "    ${GREEN}[1]${NC} 添加反代"
        echo -e "    ${GREEN}[2]${NC} 查看现有反代链路"
        echo -e "    ${GREEN}[3]${NC} 更改或删除反代链路"
        echo -e "    ${GREEN}[4]${NC} 检查并更新脚本"
        echo -e "    ${RED}[5]${NC} 卸载反代管理脚本"
        echo
        echo -e "    ${YELLOW}[0]${NC} 退出"
        echo
        if ! read -r -p '  请输入选项 [0-5]: ' choice; then
            echo
            return 0
        fi

        case $choice in
            1)
                run_proxy_deployment
                pause_for_menu
                if [[ -x $QUICK_COMMAND_PATH ]]; then
                    exec "$QUICK_COMMAND_PATH"
                fi
                return 0
                ;;
            2)
                link_transfer_menu
                pause_for_menu
                ;;
            3)
                manage_existing_link
                pause_for_menu
                ;;
            4)
                if update_script && [[ $script_update_performed == yes ]]; then
                    log_info '正在重新载入新版脚本...'
                    exec "$QUICK_COMMAND_PATH"
                fi
                pause_for_menu
                ;;
            5)
                if uninstall_quick_command; then
                    return 0
                fi
                pause_for_menu
                ;;
            0) return 0 ;;
            *)
                log_error '无效输入，请重试。'
                pause_for_menu
                ;;
        esac
    done
}

main() {
    local argument_count=$#
    parse_arguments "$@"
    require_root

    if [[ $install_command_only == yes ]]; then
        if ! install_quick_command; then
            exit 1
        fi
        exit 0
    fi
    ensure_quick_command

    if [[ -n $domain_to_remove ]]; then
        remove_domain_config
        exit 0
    fi
    if ((argument_count == 0)); then
        main_menu
        return 0
    fi
    run_proxy_deployment
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
