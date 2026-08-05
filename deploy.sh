#!/usr/bin/env bash
# Nginx Emby reverse-proxy deployment script.
# Features: main upstream, fixed streaming upstreams, IPv4/IPv6/dual-stack
# ACME validation, verified upstream TLS, transactional config rollback.
# Upstreams are fixed at deployment; no user-controlled open-proxy endpoint.
set -Eeuo pipefail
SCRIPT_NAME='nginx-proxy-ipv6-fixed'
SCRIPT_VERSION='2026.08.05-r6-slim1'
SCRIPT_BUILD='same-feature-refactor'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
ROOT_HOME=$(awk -F: '$3 == 0 {print $6; exit}' /etc/passwd 2>/dev/null || true)
ROOT_HOME=${ROOT_HOME:-/root}
NGINX_ROOT=${NGINX_ROOT:-/etc/nginx}
NGINX_MAIN_CONF=${NGINX_MAIN_CONF:-${NGINX_ROOT}/nginx.conf}
NGINX_CONF_DIR=${NGINX_CONF_DIR:-${NGINX_ROOT}/conf.d}
NGINX_CERT_DIR=${NGINX_CERT_DIR:-${NGINX_ROOT}/certs}
BACKUP_DIR=${BACKUP_DIR:-${NGINX_ROOT}/backup}
ACME_WEBROOT=${ACME_WEBROOT:-/var/www/acme-challenge}
ACME_CHALLENGE_CONF=${ACME_CHALLENGE_CONF:-${NGINX_CONF_DIR}/00-acme-http01.conf}
ACME_SH=${ACME_SH:-${ROOT_HOME}/.acme.sh/acme.sh}
ACME_VERSION='3.1.2'
ACME_ARCHIVE_SHA256='a51511ad0e2912be45125cf189401e4ae776ca1a29d5768f020a1e35a9560186'
ACME_ARCHIVE_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
ACME_INSTALL_URL=$ACME_ARCHIVE_URL
# These strings are saved by acme.sh and must not call functions from this file.
ACME_NGINX_PRE_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl stop nginx; elif command -v service >/dev/null 2>&1 && service nginx stop; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s quit; i=0; while kill -0 "$(cat /run/nginx.pid)" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done; ! kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; fi'
ACME_NGINX_POST_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then :; else nginx; fi'
ACME_NGINX_RELOAD_CMD='if [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload; elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; else nginx; fi'
# Rollback transaction state.
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
force_yes='no'
no_proxy_redirect='no'
upstream_tls_verify='yes'
manual_gh_proxy=''
format_cert_domain=''
resolver=''
listen_mode_requested='auto'
frontend_listen_mode=''
frontend_dns_a=''
frontend_dns_aaaa=''
self_test_requested='no'
# Streaming upstream arrays.
declare -a stream_input_urls=()
declare -a stream_protocols=()
declare -a stream_domains=()
declare -a stream_ports=()
declare -a stream_base_paths=()
declare -a stream_origins=()
declare -a stream_origins_no_default_port=()
log_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
handle_error() {
    local exit_code=$?
    local line_number=${1:-unknown}
    if declare -F rollback_config_changes >/dev/null 2>&1; then
        rollback_config_changes || true
    fi
    echo >&2
    log_error "脚本在第 ${line_number} 行中止，退出码: ${exit_code}"
    exit "$exit_code"
}
trap 'handle_error $LINENO' ERR
handle_signal() {
    local signal_name=$1 exit_code=$2 had_config_changes=no
    ((${#config_tx_targets[@]})) && had_config_changes=yes
    rollback_config_changes || true
    if [[ $had_config_changes == yes ]] && command -v nginx >/dev/null 2>&1; then
        restore_nginx_after_rollback || true
    fi
    if command -v nginx >/dev/null 2>&1 && ! nginx_is_running; then
        start_nginx || true
    fi
    trap - INT TERM
    log_error "收到 ${signal_name}，已尽力恢复配置与 Nginx。"
    exit "$exit_code"
}
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

# --- 命令行入口 ---
show_help() {
    cat <<EOF_HELP
用法: $(basename "$0") [选项]（无参数时进入交互模式）

部署“Emby 主源站 + 多个固定推流源站”的 Nginx 反向代理。
  -y, --you-domain URL          前端访问 URL，例如 https://emby.example.com:443
  -r, --r-domain URL            Emby 登录/API 主源站 URL
  -s, --stream-domain URL       推流/CDN 源站 URL，可重复
  -m, --cert-domain DOMAIN      手动指定证书主域名
  -d, --parse-cert-domain       提取根域名并申请通配符证书
  -D, --dns PROVIDER            acme.sh DNS API，例如 cf
  -R, --resolver DNS            Nginx resolver，可填写多个 IP
      --listen-mode MODE        auto|ipv4|ipv6|dual，默认 auto
      --cf-token TOKEN          Cloudflare API Token
      --cf-account-id ID        Cloudflare Account ID
      --gh-proxy URL            GitHub 下载加速前缀
      --no-proxy-redirect       不改写普通重定向
      --no-upstream-tls-verify  不校验 HTTPS 源站证书
      --remove URL              删除指定前端 URL 的配置
  -Y, --yes                     非交互删除时自动确认
      --self-test               运行不联网的逻辑与 Nginx 语法测试
      --version                 输出脚本版本
  -h, --help                    显示帮助

监听/验证: auto 按 A/AAAA 选择；ipv4/ipv6 使用对应 standalone；dual 使用双栈 Nginx webroot。
EOF_HELP
}
require_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_error '此脚本必须完整地以 root 身份运行。'
        log_error "请使用: sudo -H bash '$0' [选项]"
        exit 1
    fi
    export HOME=$ROOT_HOME
}
version_at_least() {
    local current=$1 required=$2
    [[ $(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1) == "$required" ]]
}
has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}
nginx_is_running() {
    [[ -s /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null
}
start_nginx() {
    if has_systemd; then systemctl start nginx
    elif command -v service >/dev/null 2>&1 && service nginx start; then :
    else nginx
    fi
}
reload_or_start_nginx() {
    if nginx_is_running; then nginx -s reload; else start_nginx; fi
}

# --- 配置事务与回滚 ---
backup_file() {
    local file_path=$1 stamp
    if [[ -f $file_path ]]; then
        mkdir -p "$BACKUP_DIR"
        stamp=$(date +%Y%m%d_%H%M%S)
        cp -a -- "$file_path" "$BACKUP_DIR/$(basename "$file_path").${stamp}"
        log_info "已备份: $file_path"
    fi
}
stage_file_install() {
    local source=$1 target=$2 backup='' existed=no
    mkdir -p "$(dirname "$target")"
    if [[ -e $target || -L $target ]]; then
        backup=$(mktemp); cp -a -- "$target" "$backup"; existed=yes
    fi
    config_tx_targets+=("$target")
    config_tx_backups+=("$backup")
    config_tx_existed+=("$existed")
    cp -- "$source" "$target"
    [[ $existed == yes ]] || chmod 0644 "$target"
}
stage_file_removal() {
    local target=$1 backup
    backup=$(mktemp); cp -a -- "$target" "$backup"
    config_tx_targets+=("$target")
    config_tx_backups+=("$backup")
    config_tx_existed+=(yes)
    rm -f -- "$target"
}
rollback_config_changes() {
    local i target backup status=0
    ((${#config_tx_targets[@]})) || return 0
    log_warn '正在回滚本次 Nginx 配置改动...'
    for ((i=${#config_tx_targets[@]} - 1; i >= 0; i--)); do
        target=${config_tx_targets[$i]}; backup=${config_tx_backups[$i]}
        if [[ ${config_tx_existed[$i]} == yes ]]; then
            cp -a -- "$backup" "$target" || status=1
            rm -f -- "$backup"
        else
            rm -f -- "$target" || status=1
        fi
    done
    config_tx_targets=(); config_tx_backups=(); config_tx_existed=()
    return "$status"
}
commit_config_changes() {
    local backup
    for backup in "${config_tx_backups[@]}"; do [[ -z $backup ]] || rm -f -- "$backup"; done
    config_tx_targets=(); config_tx_backups=(); config_tx_existed=()
}
restore_nginx_after_rollback() {
    if nginx -t >/dev/null 2>&1; then
        reload_or_start_nginx || log_warn '配置已回滚，但 Nginx 未能自动加载。'
    else
        log_error '回滚后 Nginx 配置仍未通过测试，请检查其他站点配置。'
        return 1
    fi
}

# --- 输入与地址校验 ---
is_valid_ipv4() {
    local address=$1 octet
    local -a octets=()
    [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}
is_valid_ipv6() {
    local address=${1%%%*}
    [[ $address == *:* ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$address" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.IPv6Address(sys.argv[1])
PY
        return
    fi
    [[ $address =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    local left='' right='' remainder part group count=0
    local -a groups=()
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
        for group in "${groups[@]}"; do
            [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ((count += 1))
        done
    done
    if [[ $address == *::* ]]; then ((count < 8)); else ((count == 8)); fi
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
is_ip_address() {
    local address=${1#[}
    address=${address%]}
    if [[ $address == *:* ]]; then is_valid_ipv6 "$address"; else is_valid_ipv4 "$address"; fi
}
ipv6_stack_available() {
    # Do not use a procfs address-table file to decide whether the IPv6
    # kernel stack is available. Kernel support and address assignment are
    # separate states. Use the kernel IPv6 sysctl switch only.
    local disable_file='/proc/sys/net/ipv6/conf/all/disable_ipv6'
    local disabled=''
    [[ -d /proc/sys/net/ipv6 ]] || return 1
    [[ -r $disable_file ]] || return 1
    disabled=$(<"$disable_file")
    [[ $disabled == 0 ]]
}
ipv6_stack_diagnostics() {
    local proc_sys=no all_state=missing default_state=missing lo_state=missing ip6_link=unknown
    [[ -d /proc/sys/net/ipv6 ]] && proc_sys=yes
    [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && all_state=$(< /proc/sys/net/ipv6/conf/all/disable_ipv6)
    [[ -r /proc/sys/net/ipv6/conf/default/disable_ipv6 ]] && default_state=$(< /proc/sys/net/ipv6/conf/default/disable_ipv6)
    [[ -r /proc/sys/net/ipv6/conf/lo/disable_ipv6 ]] && lo_state=$(< /proc/sys/net/ipv6/conf/lo/disable_ipv6)
    if command -v ip >/dev/null 2>&1; then
        if ip -6 link show >/dev/null 2>&1; then ip6_link=ok; else ip6_link=failed; fi
    fi
    log_error "IPv6 diagnostics: proc_sys=${proc_sys}, all.disable_ipv6=${all_state}, default.disable_ipv6=${default_state}, lo.disable_ipv6=${lo_state}, ip6_link=${ip6_link}"
}
has_global_ipv6() {
    command -v ip >/dev/null 2>&1 && ip -6 -o addr show scope global 2>/dev/null | grep -q ' inet6 '
}
has_ipv4_interface() {
    command -v ip >/dev/null 2>&1 && ip -4 -o addr show scope global 2>/dev/null | grep -q ' inet '
}
nginx_supports_http2_directive() {
    local nginx_version
    nginx_version=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p')
    [[ -n $nginx_version ]] && version_at_least "$nginx_version" '1.25.1'
}
nginx_regex_escape() {
    printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}
nginx_quote_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf '%s' "$value"
}
# Prints protocol|domain|port|path.

# --- URL 与源站状态 ---
parse_url() {
    local input=$1 proto='' authority='' domain='' port='' path=''
    if [[ $input =~ ^(https?):// ]]; then
        proto=${BASH_REMATCH[1]}
        input=${input#*://}
    else
        return 1
    fi
    authority=${input%%/*}
    [[ $input == */* ]] && path=/${input#*/}
    if [[ -z $authority || $authority == *[[:space:]]* || $authority == *\"* || $authority == *"'"* || $authority == *';'* || $authority == *'{'* || $authority == *'}'* ]]; then
        return 1
    fi
    if [[ $authority =~ ^\[([0-9A-Fa-f:%]+)\](:([0-9]+))?$ ]]; then
        local ipv6_address=${BASH_REMATCH[1]}
        local ipv6_port=${BASH_REMATCH[3]:-}
        is_valid_ipv6 "$ipv6_address" || return 1
        domain="[${ipv6_address}]"
        port=$ipv6_port
    elif [[ $authority =~ ^([A-Za-z0-9._-]+)(:([0-9]+))?$ ]]; then
        domain=${BASH_REMATCH[1],,}
        port=${BASH_REMATCH[3]:-}
        if [[ $domain =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            is_valid_ipv4 "$domain" || return 1
        elif ! is_valid_dns_name "$domain"; then
            return 1
        fi
    else
        return 1
    fi
    if [[ -n $port ]] && ((port < 1 || port > 65535)); then return 1; fi
    if [[ -n $path ]]; then
        path=${path%%\?*}
        path=${path%%\#*}
        if [[ $path == *[[:space:]]* || $path == *\"* || $path == *"'"* || $path == *';'* || $path == *'{'* || $path == *'}'* || $path == *'$'* || $path == *'\\'* || $path == *$'\r'* || $path == *$'\n'* ]]; then
            return 1
        fi
        [[ $path == / ]] && path=''
        while [[ $path == */ && $path != / ]]; do path=${path%/}; done
    fi
    printf '%s|%s|%s|%s\n' "$proto" "$domain" "$port" "$path"
}
get_default_port() { [[ $1 == http ]] && printf '80\n' || printf '443\n'; }
get_protocol() { [[ $1 == yes ]] && printf 'http\n' || printf 'https\n'; }
process_url_input() {
    local full_url=$1 domain_type=$2 parsed proto domain port path default_port prefix http_flag
    parsed=$(parse_url "$full_url") || {
        log_error "URL 格式无效: $full_url；必须使用完整 http:// 或 https:// URL。"; return 1
    }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto"); port=${port:-$default_port}
    case $domain_type in
        you) prefix=you; http_flag=no_tls ;;
        r) prefix=r; http_flag=r_http_frontend ;;
        *) return 1 ;;
    esac
    printf -v "${prefix}_domain" %s "$domain"
    printf -v "${prefix}_domain_path" %s "$path"
    printf -v "${prefix}_frontend_port" %s "$port"
    if [[ $proto == http ]]; then printf -v "$http_flag" %s yes; else printf -v "$http_flag" %s no; fi
}
add_stream_url() {
    local full_url=$1 parsed proto domain port path default_port authority origin no_default_origin existing
    parsed=$(parse_url "$full_url") || { log_error "推流 URL 格式无效: $full_url"; return 1; }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto")
    port=${port:-$default_port}
    authority="${domain}:${port}"
    origin="${proto}://${authority}${path}"
    no_default_origin=$origin
    [[ $port == "$default_port" ]] && no_default_origin="${proto}://${domain}${path}"
    for existing in "${stream_origins[@]:-}"; do
        [[ $existing == "$origin" ]] && { log_warn "推流源站已存在，跳过: $origin"; return 0; }
    done
    stream_protocols+=("$proto")
    stream_domains+=("$domain")
    stream_ports+=("$port")
    stream_base_paths+=("$path")
    stream_origins+=("$origin")
    stream_origins_no_default_port+=("$no_default_origin")
    log_success "已添加推流源站: $origin"
}
normalize_resolver_list() {
    local input=$1 item host port=''
    local -a normalized=() items=()
    read -r -a items <<<"$input"
    for item in "${items[@]}"; do
        host=$item; port=''
        if [[ $item =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[3]:-}
            is_valid_ipv6 "$host" || return 1
            item="[$host]"
        elif [[ $item =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3})(:([0-9]+))?$ ]]; then
            host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[4]:-}
            is_valid_ipv4 "$host" || return 1
            item=$host
        else
            return 1
        fi
        if [[ -n $port ]]; then
            ((port >= 1 && port <= 65535)) || return 1
            item="${item}:${port}"
        fi
        normalized+=("$item")
    done
    ((${#normalized[@]})) || return 1
    printf '%s\n' "${normalized[*]}"
}

# --- DNS 与监听模式 ---
filter_dns_answers() {
    local record_type=$1
    case $record_type in
        A)
            awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/' | sort -u
            ;;
        AAAA)
            awk '/^[0-9A-Fa-f:]+(%[A-Za-z0-9_.-]+)?$/' | sort -u
            ;;
        *) return 1 ;;
    esac
}
query_dns_cli() {
    local tool=$1 name=$2 record_type=$3 nameserver=${4:-} output=''
    case $tool in
        dig)
            local -a args=(+time=2 +tries=1 +retry=0 +short)
            [[ -z $nameserver ]] || args=("@${nameserver}" "${args[@]}")
            dig "${args[@]}" "$record_type" "$name" 2>/dev/null | filter_dns_answers "$record_type"
            ;;
        nslookup)
            if [[ -n $nameserver ]]; then
                output=$(nslookup -type="$record_type" "$name" "$nameserver" 2>/dev/null) || true
            else
                output=$(nslookup -type="$record_type" "$name" 2>/dev/null) || true
            fi
            awk -F': ' '/^Address: / && $2 !~ /#/ {print $2}' <<<"$output" | filter_dns_answers "$record_type"
            ;;
        *) return 1 ;;
    esac
}
extract_doh_answers() {
    local record_type=$1
    # The JSON endpoints may return CNAME and address answers together. Split
    # every data field onto its own line, then keep only valid address shapes.
    sed 's/"data"/\n"data"/g' \
        | sed -n 's/^"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | filter_dns_answers "$record_type"
}
query_dns_with_doh() {
    local name=$1 record_type=$2 provider=$3 endpoint resolve_host output=''
    case $provider in
        cloudflare)
            endpoint='https://cloudflare-dns.com/dns-query'
            resolve_host='cloudflare-dns.com:443:1.1.1.1'
            ;;
        google)
            endpoint='https://dns.google/resolve'
            resolve_host='dns.google:443:8.8.8.8'
            ;;
        *) return 1 ;;
    esac
    output=$(curl -fsS --connect-timeout 2 --max-time 4 \
        --resolve "$resolve_host" \
        -H 'accept: application/dns-json' \
        --get --data-urlencode "name=${name}" --data-urlencode "type=${record_type}" \
        "$endpoint" 2>/dev/null) || true
    [[ -n $output ]] || return 0
    printf '%s\n' "$output" | extract_doh_answers "$record_type"
}
resolve_dns_records() {
    local name=$1 record_type=$2 result='' candidate='' tool='' nameserver provider
    local -a public_resolvers=(1.1.1.1 8.8.8.8)
    if command -v dig >/dev/null 2>&1; then tool=dig
    elif command -v nslookup >/dev/null 2>&1; then tool=nslookup
    fi
    if [[ -n $tool ]]; then
        result=$(query_dns_cli "$tool" "$name" "$record_type") || true
        if [[ -z $result ]]; then
            for nameserver in "${public_resolvers[@]}"; do
                candidate=$(query_dns_cli "$tool" "$name" "$record_type" "$nameserver") || true
                if [[ -n $candidate ]]; then result=$candidate; break; fi
            done
        fi
    elif command -v getent >/dev/null 2>&1; then
        case $record_type in
            A) result=$(getent ahostsv4 "$name" 2>/dev/null | awk '$2=="STREAM" && $1 ~ /\./ {print $1}' | sort -u) || true ;;
            AAAA) result=$(getent ahostsv6 "$name" 2>/dev/null | awk '$2=="STREAM" && $1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u) || true ;;
        esac
    fi
    if [[ -z $result ]] && command -v curl >/dev/null 2>&1; then
        for provider in cloudflare google; do
            candidate=$(query_dns_with_doh "$name" "$record_type" "$provider") || true
            if [[ -n $candidate ]]; then result=$candidate; break; fi
        done
    fi
    printf '%s\n' "$result"
}
resolve_frontend_records() {
    local name=$1 record_type=$2 test_var
    test_var="DEPLOY_TEST_DNS_${record_type}"
    if [[ -n ${!test_var+x} ]]; then printf '%s\n' "${!test_var}"
    else resolve_dns_records "$name" "$record_type"
    fi
}
resolve_a_records()    { resolve_frontend_records "$1" A; }
resolve_aaaa_records() { resolve_frontend_records "$1" AAAA; }
choose_dns_failure_fallback_mode() {
    if [[ -n ${DEPLOY_TEST_AUTO_FALLBACK_MODE+x} ]]; then
        [[ $DEPLOY_TEST_AUTO_FALLBACK_MODE == ipv4 || $DEPLOY_TEST_AUTO_FALLBACK_MODE == ipv6 ]] || return 1
        printf '%s\n' "$DEPLOY_TEST_AUTO_FALLBACK_MODE"
    elif has_ipv4_interface; then printf 'ipv4\n'
    elif ipv6_stack_available && has_global_ipv6; then printf 'ipv6\n'
    else printf 'ipv4\n'
    fi
}
detect_frontend_listen_mode() {
    local host=${you_domain#[}; host=${host%]}
    [[ $listen_mode_requested =~ ^(auto|ipv4|ipv6|dual)$ ]] || {
        log_error "无效的 --listen-mode: $listen_mode_requested"; return 1;
    }
    if [[ $listen_mode_requested != auto ]]; then
        frontend_listen_mode=$listen_mode_requested
    elif is_valid_ipv4 "$host"; then frontend_listen_mode=ipv4
    elif is_valid_ipv6 "$host"; then frontend_listen_mode=ipv6
    else
        frontend_dns_a=$(resolve_a_records "$you_domain")
        frontend_dns_aaaa=$(resolve_aaaa_records "$you_domain")
        if [[ -n $frontend_dns_a && -n $frontend_dns_aaaa ]]; then frontend_listen_mode=dual
        elif [[ -n $frontend_dns_aaaa ]]; then frontend_listen_mode=ipv6
        elif [[ -n $frontend_dns_a ]]; then frontend_listen_mode=ipv4
        else
            frontend_listen_mode=$(choose_dns_failure_fallback_mode)
            log_warn "系统 DNS 与公共 DNS/DoH 均未查询到 ${you_domain} 的 A/AAAA 记录。"
            log_warn "auto 模式不再中止，已按本机网络能力临时选择 ${frontend_listen_mode}（优先 IPv4）。"
            log_warn '这只绕过监听模式检测；如果公网 DNS 实际未生效，HTTP-01 证书申请仍会失败。'
        fi
    fi
    case $frontend_listen_mode in
        ipv6|dual)
            if [[ ${DEPLOY_SELF_TEST:-no} != yes ]] && ! ipv6_stack_available; then
                ipv6_stack_diagnostics
                log_error '系统 IPv6 栈不可用，不能启用 IPv6 监听。'
                return 1
            fi
            [[ ${DEPLOY_SELF_TEST:-no} == yes ]] || has_global_ipv6 || log_warn '未检测到全局 IPv6 地址；请确认 VPS 的 IPv6 已正确配置。'
            ;;
    esac
    case $frontend_listen_mode in
        ipv4|dual) [[ ${DEPLOY_SELF_TEST:-no} == yes ]] || has_ipv4_interface || log_warn '未检测到 IPv4 接口；IPv4 监听仍会生成，但公网 A 记录可能不可用。' ;;
    esac
    if ! is_ip_address "$you_domain"; then
        [[ -n $frontend_dns_a ]] || frontend_dns_a=$(resolve_a_records "$you_domain")
        [[ -n $frontend_dns_aaaa ]] || frontend_dns_aaaa=$(resolve_aaaa_records "$you_domain")
        if [[ $frontend_listen_mode == ipv4 && -n $frontend_dns_aaaa ]]; then
            log_warn '域名存在 AAAA 记录，但当前仅监听 IPv4；HTTP-01 可能被 CA 从 IPv6 访问而失败。'
        elif [[ $frontend_listen_mode == ipv6 && -n $frontend_dns_a ]]; then
            log_warn '域名存在 A 记录，但当前仅监听 IPv6；HTTP-01 可能被 CA 从 IPv4 访问而失败。'
        fi
    fi
}
get_resolver_host() {
    local system_dns=''
    system_dns=$(awk '/^nameserver[[:space:]]+/ {print ($2 ~ /:/ ? "["$2"]" : $2)}' /etc/resolv.conf 2>/dev/null | xargs) || true
    if [[ -n $system_dns ]]; then
        printf '%s\n' "$system_dns"
    elif [[ $frontend_listen_mode == ipv6 ]]; then
        printf '%s\n' '[2606:4700:4700::1111] [2001:4860:4860::8888]'
    else
        printf '%s\n' '1.1.1.1 8.8.8.8'
    fi
}
prepare_summary_values() {
    local normalized_resolver='' cert_prefix=''
    if is_ip_address "$you_domain"; then
        format_cert_domain=${you_domain//[\[\]]/}
    elif [[ -n $cert_domain ]]; then
        format_cert_domain=${cert_domain,,}
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
        [[ $you_domain == *."$format_cert_domain" ]] || { log_error "前端域名不属于证书域名: $you_domain / $format_cert_domain"; return 1; }
        cert_prefix=${you_domain%."$format_cert_domain"}
        [[ -n $cert_prefix && $cert_prefix != *.* ]] || { log_error "*.${format_cert_domain} 不能覆盖多级域名: $you_domain"; return 1; }
    fi
    detect_frontend_listen_mode
    if [[ -n $manual_resolver ]]; then
        normalized_resolver=$(normalize_resolver_list "$manual_resolver") || {
            log_error "Nginx resolver 无效: $manual_resolver"
            return 1
        }
        resolver="$normalized_resolver valid=60s"
    else
        resolver=$(get_resolver_host)
        has_global_ipv6 || resolver+=" ipv6=off"
        resolver+=" valid=60s"
    fi
}

# --- 参数、交互与依赖 ---
parse_arguments() {
    local temp
    temp=$(getopt -o y:r:s:m:R:dD:hY --long you-domain:,r-domain:,stream-domain:,cert-domain:,resolver:,parse-cert-domain,dns:,cf-token:,cf-account-id:,gh-proxy:,listen-mode:,remove:,yes,no-proxy-redirect,no-upstream-tls-verify,self-test,version,help -n "$(basename "$0")" -- "$@") || exit 1
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
            --listen-mode) listen_mode_requested=${2,,}; shift 2 ;;
            --remove) domain_to_remove=$2; shift 2 ;;
            -Y|--yes) force_yes=yes; shift ;;
            --no-proxy-redirect) no_proxy_redirect=yes; shift ;;
            --no-upstream-tls-verify) upstream_tls_verify=no; shift ;;
            --self-test) self_test_requested=yes; shift ;;
            --version) printf '%s %s (%s)\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$SCRIPT_BUILD"; exit 0 ;;
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
    [[ -z $cf_token ]] || log_warn '--cf-token 可能进入 shell 历史；建议使用 CF_Token 环境变量。'
    local -a raw_streams=("${stream_input_urls[@]:-}")
    stream_input_urls=()
    local item
    for item in "${raw_streams[@]}"; do [[ -n $item ]] && add_stream_url "$item" || true; done
    return 0
}
prompt_interactive_mode() {
    local entered=no input_you input_r input_stream
    if [[ -z $you_domain || -z $r_domain ]]; then
        [[ -t 0 ]] || { log_error '无法进入交互模式，请提供 -y 和 -r。'; exit 1; }
        entered=yes
        echo -e "\n${BLUE}--- 交互模式: 配置 Emby 反向代理 ---${NC}"
        read -r -p '请输入要访问的地址（例如 https://emby.example.com:443）: ' input_you
        read -r -p '请输入要反代的 Emby 主地址（登录/API 地址）: ' input_r
        process_url_input "$input_you" you
        process_url_input "$input_r" r
    fi
    if [[ $entered == yes ]]; then
        echo
        echo -e "${BLUE}可选：添加独立的推流/CDN 源站。${NC}"
        echo '可连续输入多个完整 URL；直接回车结束。'
        while true; do
            read -r -p '请输入推流源站 URL（直接回车结束）: ' input_stream
            [[ -z ${input_stream//[[:space:]]/} ]] && break
            add_stream_url "$input_stream" || log_warn '该地址未添加，请重新输入。'
        done
    fi
}
display_summary() {
    prepare_summary_values
    local front_proto upstream_proto i validation_mode='无（HTTP）'
    front_proto=$(get_protocol "$no_tls"); upstream_proto=$(get_protocol "$r_http_frontend")
    if [[ $no_tls != yes ]]; then
        if [[ -n $dns_provider ]]; then validation_mode="DNS API: ${dns_provider}"
        elif [[ $frontend_listen_mode == dual ]]; then validation_mode='HTTP-01 webroot（IPv4 + IPv6）'
        else validation_mode="HTTP-01 standalone (${frontend_listen_mode})"
        fi
    fi
    echo -e "\n${BLUE}Nginx 反代配置摘要${NC}\n──────────────────────────────────────────────"
    echo -e "前端访问: ${GREEN}${front_proto}://${you_domain}:${you_frontend_port}${you_domain_path}${NC}"
    echo -e "Emby 主站: ${YELLOW}${upstream_proto}://${r_domain}:${r_frontend_port}${r_domain_path}${NC}"
    if ((${#stream_origins[@]})); then
        echo '推流源站:'; for i in "${!stream_origins[@]}"; do echo "  $((i + 1)). ${stream_origins[$i]}"; done
    else echo '推流源站: 未单独配置，将仅代理主站'
    fi
    echo "前端监听模式: $frontend_listen_mode"
    [[ -z $frontend_dns_a ]] || echo "DNS A: $(tr '\n' ' ' <<<"$frontend_dns_a")"
    [[ -z $frontend_dns_aaaa ]] || echo "DNS AAAA: $(tr '\n' ' ' <<<"$frontend_dns_aaaa")"
    echo "证书域名: $format_cert_domain"
    echo "证书验证: $validation_mode"
    echo "DNS resolver: $resolver"
    echo -e "TLS: $([[ $no_tls == yes ]] && echo "${RED}关闭${NC}" || echo "${GREEN}开启${NC}")"
    echo '──────────────────────────────────────────────'
}
setup_download_urls() {
    local effective_proxy=${manual_gh_proxy:-${GH_PROXY:-}}
    if [[ -n $effective_proxy ]]; then
        if [[ $effective_proxy != https://* || $effective_proxy == *[[:space:]]* || $effective_proxy == *';'* || $effective_proxy == *'{'* || $effective_proxy == *'}'* ]]; then
            log_error "GitHub 代理必须是 HTTPS URL: $effective_proxy"
            return 1
        fi
        [[ $effective_proxy == */ ]] || effective_proxy="${effective_proxy}/"
        ACME_INSTALL_URL="${effective_proxy}${ACME_ARCHIVE_URL}"
        log_info "使用 GitHub 代理: $effective_proxy"
    fi
}
install_dependencies() {
    local ready=yes cmd pm='' os_id='' id_like=''
    local -a base=(nginx curl ca-certificates socat openssl tar coreutils util-linux) packages=()
    for cmd in nginx curl socat openssl tar sha256sum getopt ip crontab; do
        command -v "$cmd" >/dev/null 2>&1 || ready=no
    done
    [[ $upstream_tls_verify != yes || -r /etc/ssl/certs/ca-certificates.crt ]] || ready=no
    if [[ $ready == yes ]]; then
        log_info 'Nginx 和依赖已安装，跳过软件包安装。'
        mkdir -p "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$BACKUP_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
        nginx_is_running || start_nginx || log_warn 'Nginx 当前未运行，将在配置完成后重试。'
        return 0
    fi
    [[ -r /etc/os-release ]] && { source /etc/os-release; os_id=${ID:-}; id_like=${ID_LIKE:-}; }
    if command -v apt-get >/dev/null 2>&1; then
        pm=apt; packages=("${base[@]}" cron gettext-base iproute2)
        apt-get update; env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        pm=dnf; packages=("${base[@]}" cronie gettext iproute); dnf install -y "${packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        pm=yum; packages=("${base[@]}" cronie gettext iproute); yum install -y "${packages[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pm=pacman; packages=("${base[@]}" cronie gettext iproute2); pacman -Sy --noconfirm "${packages[@]}"
    elif command -v apk >/dev/null 2>&1; then
        pm=apk; packages=("${base[@]}" dcron gettext iproute2); apk add --no-cache "${packages[@]}"
    else
        log_error "不支持的系统。ID=${os_id}, ID_LIKE=${id_like}"; return 1
    fi
    log_info "依赖安装完成，包管理器: $pm"
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CERT_DIR" "$BACKUP_DIR" "$ACME_WEBROOT/.well-known/acme-challenge"
    has_systemd && systemctl enable nginx >/dev/null 2>&1 || true
    nginx_is_running || start_nginx || log_warn 'Nginx 当前未运行，将在配置完成后重试。'
}

# --- Nginx 基础安装 ---
ensure_http_include() {
    [[ -f $NGINX_MAIN_CONF ]] || { log_error "未找到 $NGINX_MAIN_CONF"; return 1; }
    if grep -Fq "include ${NGINX_CONF_DIR}/*.conf;" "$NGINX_MAIN_CONF"; then return 0; fi
    # Standard distro path is handled by the original insertion logic.
    if [[ $NGINX_CONF_DIR != /etc/nginx/conf.d ]]; then
        log_error "自定义 NGINX_CONF_DIR 未被 nginx.conf include: $NGINX_CONF_DIR"
        return 1
    fi
    backup_file "$NGINX_MAIN_CONF"
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN {in_http=0; depth=0; inserted=0}
        {
            line=$0; opens=gsub(/\{/, "{", line); closes=gsub(/\}/, "}", line)
            if (!in_http && $0 ~ /^[[:space:]]*http[[:space:]]*\{/) {in_http=1; depth=opens-closes; print; next}
            if (in_http) {
                if (depth==1 && $0 ~ /^[[:space:]]*}[[:space:]]*$/ && !inserted) {print "    include /etc/nginx/conf.d/*.conf;"; inserted=1}
                depth += opens-closes; if (depth==0) in_http=0
            }
            print
        }
        END {if (!inserted) exit 12}
    ' "$NGINX_MAIN_CONF" > "$tmp" || { rm -f "$tmp"; log_error '无法自动添加 conf.d include。'; return 1; }
    stage_file_install "$tmp" "$NGINX_MAIN_CONF"
    rm -f "$tmp"
    log_success "已向 nginx.conf 添加 ${NGINX_CONF_DIR}/*.conf"
}
cleanup_acme_extract_dir() {
    local directory=$1 resolved
    resolved=$(readlink -m -- "$directory")
    [[ $resolved == /tmp/acme-install.* && -d $resolved ]] || { log_error "拒绝清理异常目录: $resolved"; return 1; }
    rm -rf --one-file-system -- "$resolved"
}

# --- ACME 证书 ---
install_acme() {
    [[ $no_tls == yes ]] && return 0
    local current_version=''
    if [[ -x $ACME_SH ]]; then
        current_version=$("$ACME_SH" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 || true)
        if [[ -n $current_version ]] && version_at_least "$current_version" "$ACME_VERSION"; then
            "$ACME_SH" --set-default-ca --server letsencrypt; return 0
        fi
        log_warn "现有 acme.sh 版本过旧，将安装 ${ACME_VERSION}。"
    fi
    setup_download_urls
    log_info "安装 acme.sh ${ACME_VERSION}..."
    local archive extract_dir source_dir status=0
    archive=$(mktemp); extract_dir=$(mktemp -d /tmp/acme-install.XXXXXXXXXX)
    if ! curl -fsSL "$ACME_INSTALL_URL" -o "$archive"; then
        status=1
    elif ! printf '%s  %s\n' "$ACME_ARCHIVE_SHA256" "$archive" | sha256sum -c - >/dev/null; then
        log_error 'acme.sh SHA-256 校验失败。'; status=1
    elif ! tar -xzf "$archive" -C "$extract_dir"; then
        status=1
    else
        source_dir="$extract_dir/acme.sh-${ACME_VERSION}"
        if [[ ! -f $source_dir/acme.sh ]]; then status=1
        elif HOME=$ROOT_HOME sh "$source_dir/acme.sh" --install; then :
        else status=$?
        fi
    fi
    rm -f "$archive"; cleanup_acme_extract_dir "$extract_dir"
    ((status == 0)) || return "$status"
    "$ACME_SH" --set-default-ca --server letsencrypt
}
acme_cert_is_issued() {
    local info cert_path
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    cert_path=$(sed -n "s/^Le_RealFullChainPath='\(.*\)'$/\1/p" <<<"$info" | head -n 1)
    [[ -n $cert_path && -s $cert_path ]]
}
acme_record_matches_mode() {
    local info
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    case $frontend_listen_mode in
        ipv4) grep -Eq "^Le_Listen_V4='?1'?" <<<"$info" ;;
        ipv6) grep -Eq "^Le_Listen_V6='?1'?" <<<"$info" ;;
        dual) grep -Fq "$ACME_WEBROOT" <<<"$info" ;;
        *) return 1 ;;
    esac
}
cleanup_stale_acme_record() {
    [[ -x $ACME_SH ]] || return 0
    "$ACME_SH" --remove -d "$format_cert_domain" --ecc >/dev/null 2>&1 || true
    "$ACME_SH" --remove -d "$format_cert_domain" >/dev/null 2>&1 || true
}
write_listen_directives() {
    local file=$1 port=$2 tls=${3:-no} modern_http2=${4:-no} suffix=''
    local -a binds=()
    [[ $tls != yes ]] || { [[ $modern_http2 == yes ]] && suffix=' ssl' || suffix=' ssl http2'; }
    case $frontend_listen_mode in
        ipv4) binds=(0.0.0.0) ;;
        ipv6) binds=('[::]') ;;
        dual) binds=(0.0.0.0 '[::]') ;;
        *) log_error "未知监听模式: $frontend_listen_mode"; return 1 ;;
    esac
    local bind
    for bind in "${binds[@]}"; do printf '    listen %s:%s%s;\n' "$bind" "$port" "$suffix" >> "$file"; done
}
generate_acme_challenge_config() {
    [[ $frontend_listen_mode == dual ]] || return 0
    ensure_http_include
    mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF_ACME
# Generated by nginx_proxy deploy-ipv6-fixed.sh
server {
EOF_ACME
    write_listen_directives "$tmp" 80 no no
    cat >> "$tmp" <<EOF_ACME
    server_name ${you_domain};
    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF_ACME
    backup_file "$ACME_CHALLENGE_CONF"
    stage_file_install "$tmp" "$ACME_CHALLENGE_CONF"
    rm -f "$tmp"
    if ! nginx -t; then return 1; fi
    reload_or_start_nginx
    log_success '已启用双栈 ACME HTTP-01 webroot。'
}
build_standalone_family_args() {
    local -n output=$1
    output=()
    case $frontend_listen_mode in
        ipv4) output+=(--listen-v4) ;;
        ipv6) output+=(--listen-v6) ;;
        dual) return 0 ;;
        *) return 1 ;;
    esac
}
issue_certificate() {
    [[ $no_tls == yes ]] && return 0
    install_acme
    local cert_dir="${NGINX_CERT_DIR}/${format_cert_domain}"
    local cert_exists=no need_issue=yes issue_status=0
    local -a domain_args=(-d "$format_cert_domain") issue_extra=() force_args=() family_args=()
    if is_ip_address "$you_domain"; then
        issue_extra+=(--certificate-profile shortlived --days 6)
        dns_provider=''
    elif [[ $format_cert_domain != "$you_domain" ]]; then
        domain_args+=(-d "*.${format_cert_domain}")
    fi
    if acme_cert_is_issued; then cert_exists=yes; need_issue=no; fi
    if [[ -z $dns_provider && $cert_exists == yes ]] && ! acme_record_matches_mode; then
        log_warn "现有证书的续期地址族与当前 ${frontend_listen_mode} 模式不一致，将强制续签一次完成迁移。"
        need_issue=yes
        force_args+=(--force)
    fi
    if [[ $need_issue == yes ]]; then
        if [[ $cert_exists != yes ]]; then cleanup_stale_acme_record; force_args+=(--force); fi
        log_info "申请证书: $format_cert_domain"
        if [[ -n $dns_provider ]]; then
            if [[ $dns_provider == cf ]]; then
                [[ -n $cf_token ]] && export CF_Token=$cf_token
                [[ -n $cf_account_id ]] && export CF_Account_ID=$cf_account_id
                if [[ -z ${CF_Token:-} && -t 0 ]]; then read -r -s -p 'Cloudflare Token: ' CF_Token; echo; fi
                if [[ -z ${CF_Account_ID:-} && -t 0 ]]; then read -r -p 'Cloudflare Account ID: ' CF_Account_ID; fi
                [[ -n ${CF_Token:-} && -n ${CF_Account_ID:-} ]] || { log_error 'Cloudflare DNS 模式需要 Token 和 Account ID。'; return 1; }
                export CF_Token CF_Account_ID
            fi
            "$ACME_SH" --issue --dns "dns_${dns_provider}" "${domain_args[@]}" --keylength ec-256 "${force_args[@]}"
        else
            if [[ $format_cert_domain != "$you_domain" ]] && ! is_ip_address "$you_domain"; then
                log_error '通配符证书必须通过 -D 指定 DNS API。'
                return 1
            fi
            if [[ $frontend_listen_mode == dual ]] && ! is_ip_address "$you_domain"; then
                generate_acme_challenge_config
                "$ACME_SH" --issue --webroot "$ACME_WEBROOT" "${domain_args[@]}" --keylength ec-256 \
                    "${issue_extra[@]}" "${force_args[@]}" || issue_status=$?
            else
                build_standalone_family_args family_args
                log_info "Standalone 将临时停止 Nginx，并固定监听 ${frontend_listen_mode}。"
                "$ACME_SH" --issue --standalone "${domain_args[@]}" --keylength ec-256 \
                    --pre-hook "$ACME_NGINX_PRE_HOOK" \
                    --post-hook "$ACME_NGINX_POST_HOOK" \
                    "${family_args[@]}" "${issue_extra[@]}" "${force_args[@]}" || issue_status=$?
                if ! nginx_is_running; then start_nginx || log_warn '证书签发后未能自动恢复 Nginx。'; fi
            fi
            ((issue_status == 0)) || return "$issue_status"
        fi
    fi
    mkdir -p "$cert_dir"
    "$ACME_SH" --install-cert -d "$format_cert_domain" --ecc \
        --fullchain-file "$cert_dir/cert" \
        --key-file "$cert_dir/key" \
        --reloadcmd "$ACME_NGINX_RELOAD_CMD"
}

# --- 流媒体重写规则 ---
stream_indices_by_specificity() {
    local i
    for i in "${!stream_origins[@]}"; do printf '%09d %s\n' "${#stream_origins[$i]}" "$i"; done | sort -rn | awk '{print $2}'
}
append_stream_sub_filters() {
    local file=$1 i public_prefix escaped_public_prefix origin origin_no_default escaped_origin escaped_origin_no_default
    while IFS= read -r i; do
        [[ -n $i ]] || continue
        public_prefix="\$scheme://\$emby_public_host:\$server_port/__emby_stream/$((i + 1))"
        escaped_public_prefix="\$scheme:\\/\\/\$emby_public_host:\$server_port\\/__emby_stream\\/$((i + 1))"
        origin=$(nginx_quote_escape "${stream_origins[$i]}")
        origin_no_default=$(nginx_quote_escape "${stream_origins_no_default_port[$i]}")
        escaped_origin=${origin//\//\\/}
        escaped_origin_no_default=${origin_no_default//\//\\/}
        printf "        sub_filter '%s' '%s';\n" "$origin" "$public_prefix" >> "$file"
        printf "        sub_filter '%s' '%s';\n" "$escaped_origin" "$escaped_public_prefix" >> "$file"
        if [[ $origin_no_default != "$origin" ]]; then
            printf "        sub_filter '%s' '%s';\n" "$origin_no_default" "$public_prefix" >> "$file"
            printf "        sub_filter '%s' '%s';\n" "$escaped_origin_no_default" "$escaped_public_prefix" >> "$file"
        fi
    done < <(stream_indices_by_specificity)
}
append_stream_proxy_redirects() {
    local file=$1 i origin origin_no_default public_prefix
    while IFS= read -r i; do
        [[ -n $i ]] || continue
        origin=$(nginx_quote_escape "${stream_origins[$i]}")
        origin_no_default=$(nginx_quote_escape "${stream_origins_no_default_port[$i]}")
        public_prefix="\$scheme://\$emby_public_host:\$server_port/__emby_stream/$((i + 1))"
        printf "        proxy_redirect '%s/' '%s/';\n" "$origin" "$public_prefix" >> "$file"
        [[ $origin_no_default == "$origin" ]] || printf "        proxy_redirect '%s/' '%s/';\n" "$origin_no_default" "$public_prefix" >> "$file"
    done < <(stream_indices_by_specificity)
}
append_proxy_options() {
    local file=$1 mode=${2:-main}
    cat >> "$file" <<'EOF_HEADERS'
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        # Do not advertise an upstream's HTTP/3 endpoint as this proxy origin.
        proxy_hide_header Alt-Svc;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $emby_connection_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
EOF_HEADERS
    if [[ $upstream_tls_verify == yes ]]; then
        cat >> "$file" <<'EOF_VERIFY'
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 5;
EOF_VERIFY
    fi
    if [[ $mode == stream ]]; then
        cat >> "$file" <<'EOF_STREAM_OPTIONS'
        proxy_set_header Range $http_range;
        proxy_set_header If-Range $http_if_range;
        proxy_force_ranges on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
EOF_STREAM_OPTIONS
    fi
    if [[ $mode != headers ]] && ((${#stream_origins[@]})); then
        cat >> "$file" <<'EOF_FILTER'
        proxy_set_header Accept-Encoding "";
        sub_filter_once off;
        sub_filter_types text/plain text/css application/json application/javascript application/x-javascript application/xml application/vnd.apple.mpegurl application/x-mpegurl;
EOF_FILTER
        append_stream_sub_filters "$file"
        append_stream_proxy_redirects "$file"
    fi
}
append_common_proxy_headers() { append_proxy_options "$1" headers; }

# --- Nginx 站点配置 ---
generate_nginx_config() {
    ensure_http_include
    local map_conf="${NGINX_CONF_DIR}/00-emby-connection-map.conf" map_tmp
    map_tmp=$(mktemp)
    cat > "$map_tmp" <<'EOF_MAP'
map $http_upgrade $emby_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF_MAP
    backup_file "$map_conf"
    stage_file_install "$map_tmp" "$map_conf"
    rm -f "$map_tmp"
    local clean_domain=${you_domain//[\[\]]/}
    clean_domain=${clean_domain//:/_}
    local conf_path="${NGINX_CONF_DIR}/${clean_domain}.${you_frontend_port}.conf" tmp_conf
    tmp_conf=$(mktemp)
    local front_path=${you_domain_path:-/}
    [[ $front_path == */ ]] || front_path="${front_path}/"
    local front_exact=${front_path%/} front_path_regex
    front_path_regex=$(nginx_regex_escape "$front_path")
    local main_proto main_authority main_upstream main_base_path
    main_proto=$(get_protocol "$r_http_frontend")
    main_authority="${r_domain}:${r_frontend_port}"
    main_base_path=${r_domain_path:-}
    main_upstream="${main_proto}://${main_authority}"
    local modern_http2=no
    nginx_supports_http2_directive && modern_http2=yes
    cat > "$tmp_conf" <<'EOF_SERVER'
# Generated by nginx_proxy deploy-ipv6-fixed.sh
# Main upstream and fixed streaming upstreams are explicitly listed.
server {
EOF_SERVER
    if [[ $no_tls == yes ]]; then write_listen_directives "$tmp_conf" "$you_frontend_port" no "$modern_http2";
    else write_listen_directives "$tmp_conf" "$you_frontend_port" yes "$modern_http2"; fi
    [[ $no_tls == yes || $modern_http2 != yes ]] || echo '    http2 on;' >> "$tmp_conf"
    if [[ $you_domain == \[*\] ]]; then echo '    server_name _;' >> "$tmp_conf"; else echo "    server_name ${you_domain};" >> "$tmp_conf"; fi
    echo "    set \$emby_public_host '${you_domain}';" >> "$tmp_conf"
    if [[ $no_tls != yes ]]; then
        cat >> "$tmp_conf" <<EOF_TLS
    ssl_certificate ${NGINX_CERT_DIR}/${format_cert_domain}/cert;
    ssl_certificate_key ${NGINX_CERT_DIR}/${format_cert_domain}/key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1h;
EOF_TLS
    fi
    cat >> "$tmp_conf" <<EOF_BASE
    resolver ${resolver};
    resolver_timeout 5s;
    client_max_body_size 500m;
    client_header_timeout 1h;
    keepalive_timeout 30m;

EOF_BASE
    local i id proto domain port base_path upstream
    for i in "${!stream_origins[@]}"; do
        id=$((i + 1)); proto=${stream_protocols[$i]}; domain=${stream_domains[$i]}; port=${stream_ports[$i]}; base_path=${stream_base_paths[$i]}
        upstream="${proto}://${domain}:${port}"
        cat >> "$tmp_conf" <<EOF_STREAM
    # Streaming upstream ${id}: ${stream_origins[$i]}
    location ^~ /__emby_stream/${id}/ {
        set \$stream_upstream_${id} '${upstream}';
        rewrite ^/__emby_stream/${id}/(.*)\$ "${base_path}/\$1" break;
        proxy_pass \$stream_upstream_${id};
        proxy_set_header Host \$proxy_host;
EOF_STREAM
        append_proxy_options "$tmp_conf" stream
        echo '    }' >> "$tmp_conf"
        echo >> "$tmp_conf"
    done
    if [[ $front_path != / ]]; then
        cat >> "$tmp_conf" <<EOF_MAIN
    location = "${front_exact}" {
        return 308 "${front_exact}/\$is_args\$args";
    }

EOF_MAIN
    fi
    cat >> "$tmp_conf" <<EOF_MAIN
    location "${front_path}" {
        set \$emby_main_upstream '${main_upstream}';
EOF_MAIN
    if [[ $front_path != / ]]; then
        echo "        rewrite ^${front_path_regex}(.*)\$ \"${main_base_path}/\$1\" break;" >> "$tmp_conf"
    elif [[ -n $main_base_path ]]; then
        echo "        rewrite ^/(.*)\$ \"${main_base_path}/\$1\" break;" >> "$tmp_conf"
    fi
    cat >> "$tmp_conf" <<'EOF_MAIN'
        proxy_pass $emby_main_upstream;
        proxy_set_header Host $proxy_host;
EOF_MAIN
    append_proxy_options "$tmp_conf" main
    if [[ $no_proxy_redirect != yes ]]; then
        local main_origin="${main_proto}://${r_domain}:${r_frontend_port}${main_base_path}" main_origin_no_port default_main_port
        main_origin_no_port=$main_origin
        default_main_port=$(get_default_port "$main_proto")
        [[ $r_frontend_port == "$default_main_port" ]] && main_origin_no_port="${main_proto}://${r_domain}${main_base_path}"
        printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$server_port%s/';\n" "$main_origin" "${front_path%/}" >> "$tmp_conf"
        [[ $main_origin_no_port == "$main_origin" ]] || printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$server_port%s/';\n" "$main_origin_no_port" "${front_path%/}" >> "$tmp_conf"
    fi
    cat >> "$tmp_conf" <<'EOF_END'
    }
}
EOF_END
    backup_file "$conf_path"
    stage_file_install "$tmp_conf" "$conf_path"
    rm -f "$tmp_conf"
    log_success "配置文件已生成: $conf_path"
}
test_and_reload_nginx() {
    log_info '测试 Nginx 配置...'
    nginx -t || return 1
    reload_or_start_nginx
}
validate_nginx_features() {
    if ((${#stream_origins[@]})) && ! nginx -V 2>&1 | grep -q -- '--with-http_sub_module'; then
        log_error '当前 Nginx 未编译 ngx_http_sub_module，无法改写推流 URL。'
        return 1
    fi
}

# --- 管理与测试 ---
remove_domain_config() {
    local parsed proto domain port path default_port clean_domain conf_path
    parsed=$(parse_url "$domain_to_remove") || { log_error '请使用完整 URL。'; return 1; }
    IFS='|' read -r proto domain port path <<<"$parsed"
    default_port=$(get_default_port "$proto"); port=${port:-$default_port}
    clean_domain=${domain//[\[\]]/}; clean_domain=${clean_domain//:/_}
    conf_path="${NGINX_CONF_DIR}/${clean_domain}.${port}.conf"
    [[ -f $conf_path ]] || { log_error "未找到配置: $conf_path"; return 1; }
    grep -q '^# Generated by nginx_proxy deploy-ipv6-fixed.sh$' "$conf_path" || { log_error "拒绝删除非本脚本配置: $conf_path"; return 1; }
    if [[ $force_yes != yes ]]; then
        [[ -t 0 ]] || { log_error '非交互删除必须使用 --yes。'; return 1; }
        local answer; read -r -p "确认删除 $conf_path？请输入 yes: " answer
        [[ $answer == yes ]] || { log_info '已取消。'; return 0; }
    fi
    stage_file_removal "$conf_path"
    if ! test_and_reload_nginx; then rollback_config_changes; restore_nginx_after_rollback; return 1; fi
    commit_config_changes
    log_success '配置已移除。'
}
assert_eq() {
    local expected=$1 actual=$2 name=$3
    if [[ $expected != "$actual" ]]; then
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$name" "$expected" "$actual" >&2
        return 1
    fi
    printf 'PASS: %s\n' "$name"
}
self_test_mode() {
    local expected=$1 domain=$2 a=$3 aaaa=$4 name=$5
    you_domain=$domain; listen_mode_requested=auto; frontend_dns_a=''; frontend_dns_aaaa=''
    DEPLOY_TEST_DNS_A=$a DEPLOY_TEST_DNS_AAAA=$aaaa detect_frontend_listen_mode
    assert_eq "$expected" "$frontend_listen_mode" "$name"
}
self_test() {
    export DEPLOY_SELF_TEST=yes
    printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
    local parsed tmp
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(< /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]]; then
        ipv6_stack_available; printf 'PASS: IPv6 stack detection uses sysctl state only\n'
    fi
    parsed=$(parse_url 'https://[2001:db8::10]:8443/emby')
    assert_eq 'https|[2001:db8::10]|8443|/emby' "$parsed" '解析 IPv6 URL'
    parsed=$(parse_url 'https://emby.example.com:443')
    assert_eq 'https|emby.example.com|443|' "$parsed" '解析域名 URL'
    parsed=$(printf '%s' '{"Status":0,"Answer":[{"type":5,"data":"alias.example.com."},{"type":1,"data":"23.238.31.171"}]}' | extract_doh_answers A)
    assert_eq '23.238.31.171' "$parsed" '解析 DoH JSON 中的 A 记录'
    self_test_mode ipv6 v6.example.com '' '2001:db8::10' 'AAAA-only 自动识别为 IPv6'
    local -a family_args=(); build_standalone_family_args family_args
    assert_eq '--listen-v6' "${family_args[*]}" 'IPv6 standalone 参数'
    self_test_mode ipv4 v4.example.com '192.0.2.10' '' 'A-only 自动识别为 IPv4'
    build_standalone_family_args family_args
    assert_eq '--listen-v4' "${family_args[*]}" 'IPv4 standalone 参数'
    self_test_mode dual dual.example.com '192.0.2.10' '2001:db8::10' 'A+AAAA 自动识别为双栈'
    DEPLOY_TEST_AUTO_FALLBACK_MODE=ipv4 self_test_mode ipv4 dns-failure.example.com '' '' 'DNS 全部失败时 auto 安全降级为 IPv4'
    tmp=$(mktemp -d)
    upstream_tls_verify=no; : > "$tmp/proxy-headers.conf"; append_common_proxy_headers "$tmp/proxy-headers.conf"
    grep -Fq 'proxy_hide_header Alt-Svc;' "$tmp/proxy-headers.conf"
    printf 'PASS: 过滤上游 Alt-Svc，避免错误宣传 HTTP/3\n'
    frontend_listen_mode=ipv6; : > "$tmp/listen.conf"; write_listen_directives "$tmp/listen.conf" 443 yes no
    grep -Fq 'listen [::]:443 ssl http2;' "$tmp/listen.conf"; ! grep -Fq '0.0.0.0' "$tmp/listen.conf"
    printf 'PASS: IPv6-only Nginx 监听不含 IPv4\n'
    frontend_listen_mode=dual
    cat > "$tmp/nginx.conf" <<'EOF_TEST_NGINX'
events {}
http {
    server {
EOF_TEST_NGINX
    write_listen_directives "$tmp/nginx.conf" 18080 no no
    cat >> "$tmp/nginx.conf" <<'EOF_TEST_NGINX'
        server_name _;
        return 200;
    }
}
EOF_TEST_NGINX
    if command -v nginx >/dev/null 2>&1; then
        nginx -t -c "$tmp/nginx.conf" -p "$tmp" >/dev/null
        printf 'PASS: 双栈 Nginx 配置语法\n'
        cat > "$tmp/shared-listen.conf" <<'EOF_TEST_SHARED'
events {}
http {
    server { listen [::]:18443 default_server reuseport; server_name _; return 444; }
    server { listen [::]:18443; server_name ipv6.example.test; return 200; }
}
EOF_TEST_SHARED
        nginx -t -c "$tmp/shared-listen.conf" -p "$tmp" >/dev/null
        printf 'PASS: 与现有 reuseport/default_server IPv6 监听兼容\n'
    else printf 'SKIP: 未安装 Nginx，跳过 Nginx 语法测试\n'
    fi
    rm -rf -- "$tmp"; printf '\n全部内置测试通过。\n'
}

# --- 主流程 ---
main() {
    parse_arguments "$@"
    if [[ $self_test_requested == yes ]]; then self_test; exit 0; fi
    require_root
    log_info "Script version: ${SCRIPT_NAME} ${SCRIPT_VERSION} (${SCRIPT_BUILD})"
    if [[ -n $domain_to_remove ]]; then remove_domain_config; exit 0; fi
    prompt_interactive_mode
    [[ -n $you_domain && -n $r_domain ]] || { log_error '前端和主源站不能为空。'; exit 1; }
    display_summary
    install_dependencies
    validate_nginx_features
    issue_certificate
    generate_nginx_config
    if test_and_reload_nginx; then
        commit_config_changes
        local protocol
        protocol=$(get_protocol "$no_tls")
        log_success '部署成功！'
        echo -e "${GREEN}访问地址: ${protocol}://${you_domain}:${you_frontend_port}${you_domain_path}${NC}"
    else
        rollback_config_changes || true
        restore_nginx_after_rollback || true
        log_error 'Nginx 配置测试或加载失败，本次改动已回滚。'
        exit 1
    fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
