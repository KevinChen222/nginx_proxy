#!/usr/bin/env bash

# Nginx Emby reverse-proxy deployment script with support for multiple
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
ACME_VERSION='3.1.2'
ACME_ARCHIVE_SHA256='a51511ad0e2912be45125cf189401e4ae776ca1a29d5768f020a1e35a9560186'
ACME_ARCHIVE_URL="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"

# These commands are persisted by acme.sh and therefore must be standalone:
# cron renewals cannot call functions defined only in this deployment script.
ACME_NGINX_PRE_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl stop nginx; elif command -v service >/dev/null 2>&1 && service nginx stop; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s quit; i=0; while kill -0 "$(cat /run/nginx.pid)" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done; ! kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; fi'
ACME_NGINX_POST_HOOK='if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; elif [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then :; else nginx; fi'
ACME_NGINX_RELOAD_CMD='if [ -s /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload; elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start nginx; elif command -v service >/dev/null 2>&1 && service nginx start; then :; else nginx; fi'

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
force_yes='no'
no_proxy_redirect='no'
upstream_tls_verify='yes'
manual_gh_proxy=''
format_cert_domain=''
resolver=''

# Streaming upstream arrays. Each --stream-domain appends one item.
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

show_help() {
    cat <<EOF
用法: $(basename "$0") [选项]

部署一个支持“主 Emby 域名 + 多个独立推流域名”的 Nginx 反向代理。
不带参数运行时进入交互模式。

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

管理选项:
      --remove <URL>           删除指定前端 URL 的配置
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

has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
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

parse_arguments() {
    local temp
    temp=$(getopt -o y:r:s:m:R:dD:hY --long you-domain:,r-domain:,stream-domain:,cert-domain:,resolver:,parse-cert-domain,dns:,cf-token:,cf-account-id:,gh-proxy:,remove:,yes,no-proxy-redirect,no-upstream-tls-verify,help -n "$(basename "$0")" -- "$@") || exit 1
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
    echo '──────────────────────────────────────────────'
}

install_dependencies() {
    local id_like='' os_id='' pm=''
    local -a required_packages=()
    local dependencies_ready=yes
    local required_command
    for required_command in nginx curl socat openssl envsubst tar sha256sum; do
        command -v "$required_command" >/dev/null 2>&1 || dependencies_ready=no
    done
    command -v crontab >/dev/null 2>&1 || dependencies_ready=no
    if [[ $upstream_tls_verify == yes && ! -r /etc/ssl/certs/ca-certificates.crt ]]; then
        dependencies_ready=no
    fi

    if [[ $dependencies_ready == yes ]]; then
        log_info "Nginx 和依赖已安装，跳过软件包安装。"
        $SUDO mkdir -p /etc/nginx/conf.d /etc/nginx/certs "$BACKUP_DIR"
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
        required_packages=(nginx curl ca-certificates socat cron openssl gettext-base tar coreutils)
        $SUDO apt-get update
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${required_packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        pm=dnf
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext)
        $SUDO dnf install -y "${required_packages[@]}"
    elif command -v yum >/dev/null 2>&1; then
        pm=yum
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext)
        $SUDO yum install -y "${required_packages[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        pm=pacman
        required_packages=(nginx curl ca-certificates socat cronie openssl gettext)
        $SUDO pacman -Sy --noconfirm "${required_packages[@]}"
    elif command -v apk >/dev/null 2>&1; then
        pm=apk
        required_packages=(nginx curl ca-certificates socat dcron openssl gettext)
        $SUDO apk add --no-cache "${required_packages[@]}"
    else
        log_error "不支持的系统，无法识别包管理器。ID=${os_id}, ID_LIKE=${id_like}"
        exit 1
    fi

    log_info "依赖安装完成，包管理器: $pm"
    $SUDO mkdir -p /etc/nginx/conf.d /etc/nginx/certs "$BACKUP_DIR"

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
    cert_path=$(sed -n "s/^Le_RealFullChainPath='\(.*\)'$/\1/p" <<<"$info" | head -n 1)
    [[ -n $cert_path && -s $cert_path ]]
}

acme_has_renewal_hooks() {
    local info
    info=$("$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null || true)
    grep -Eq '^Le_PreHook=.+$' <<<"$info" && grep -Eq '^Le_PostHook=.+$' <<<"$info"
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

    if [[ -z $dns_provider && $cert_exists == yes ]] && ! acme_has_renewal_hooks; then
        log_warn '现有 standalone 证书缺少续期停启 hook，将强制续签一次以补全。'
        need_issue=yes
        force_args+=(--force)
    fi

    if [[ $need_issue == yes ]]; then
        [[ $cert_exists == yes ]] || cleanup_stale_acme_record
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
            "$ACME_SH" --issue --dns "dns_${dns_provider}" "${domain_args[@]}" --keylength ec-256
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
        public_prefix="\$scheme://\$emby_public_host:\$server_port/__emby_stream/$((i + 1))"
        escaped_public_prefix="\$scheme:\\/\\/\$emby_public_host:\$server_port\/__emby_stream\/$((i + 1))"
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
        public_prefix="\$scheme://\$emby_public_host:\$server_port/__emby_stream/$((i + 1))"
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

    local main_proto main_authority main_upstream main_base_path
    main_proto=$(get_protocol "$r_http_frontend")
    main_authority="${r_domain}:${r_frontend_port}"
    main_base_path=${r_domain_path:-}
    main_upstream="${main_proto}://${main_authority}"

    local modern_http2=no
    nginx_supports_http2_directive && modern_http2=yes

    {
        echo '# Generated by deploy-stream-domains.sh'
        echo '# Main upstream and fixed streaming upstreams are explicitly listed.'
        echo 'server {'
        if [[ $no_tls == yes ]]; then
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
            printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$server_port%s/';\n" "$main_origin" "${front_path%/}"
            if [[ $main_origin_no_port != "$main_origin" ]]; then
                printf "        proxy_redirect '%s/' '\$scheme://\$emby_public_host:\$server_port%s/';\n" "$main_origin_no_port" "${front_path%/}"
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

    stage_file_removal "$conf_path"
    if ! test_and_reload_nginx; then
        rollback_config_changes || true
        restore_nginx_after_rollback
        log_error '删除后的 Nginx 配置测试或加载失败，已恢复原配置。'
        exit 1
    fi
    commit_config_changes

    if [[ -n $cert_path ]]; then
        refs=$($SUDO grep -RslF "$cert_path" /etc/nginx/conf.d 2>/dev/null || true)
        if [[ -z $refs ]]; then
            $SUDO rm -f -- "$cert_dir/cert" "$cert_dir/key"
            if ! $SUDO rmdir -- "$cert_dir" 2>/dev/null; then
                log_warn "证书目录中仍有其他文件，未递归删除: $cert_dir"
            fi
            if [[ -x $ACME_SH ]]; then
                "$ACME_SH" --remove -d "$cert_name" --ecc >/dev/null 2>&1 || true
            fi
        else
            log_warn "证书仍被其他站点引用，未删除: $cert_dir"
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
}

main() {
    parse_arguments "$@"
    require_root

    if [[ -n $domain_to_remove ]]; then
        remove_domain_config
        exit 0
    fi

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
        restore_nginx_after_rollback
        log_error 'Nginx 配置测试或加载失败，本次配置改动已回滚。'
        exit 1
    fi
}

main "$@"
