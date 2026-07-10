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
if [[ $(id -u) -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo -e "${RED}错误: 此脚本需要 root 权限，或者系统必须安装 sudo。${NC}" >&2
        exit 1
    fi
    SUDO='sudo'
fi

BACKUP_DIR='/etc/nginx/backup'
ACME_SH="${HOME}/.acme.sh/acme.sh"

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
    echo >&2
    log_error "脚本在第 ${line_number} 行中止，退出码: ${exit_code}"
    exit "$exit_code"
}
trap 'handle_error $LINENO' ERR

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
      --gh-proxy <URL>         GitHub Raw 加速前缀
      --no-proxy-redirect      不改写未显式配置的普通重定向

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

is_in_china() {
    local loc=''
    loc=$(curl -m 3 -fsSL https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="loc"{print $2; exit}') || true
    [[ $loc == CN ]]
}

setup_download_urls() {
    local raw_host='raw.githubusercontent.com'
    local url_prefix="https://${raw_host}"
    local acme_raw="${url_prefix}/acmesh-official/acme.sh/master/acme.sh"
    local effective_proxy=${manual_gh_proxy:-${GH_PROXY:-}}

    if [[ -z $effective_proxy ]] && is_in_china; then
        effective_proxy='https://gh.llkk.cc/'
    fi
    if [[ -n $effective_proxy && $effective_proxy != */ ]]; then
        effective_proxy="${effective_proxy}/"
    fi

    if [[ -n $effective_proxy ]]; then
        ACME_INSTALL_URL="${effective_proxy}${acme_raw}"
        log_info "使用 GitHub 代理: $effective_proxy"
    else
        ACME_INSTALL_URL=$acme_raw
    fi
}

has_ipv6() {
    command -v ip >/dev/null 2>&1 && ip -6 addr show scope global 2>/dev/null | grep -q inet6
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

    if [[ $authority =~ ^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$ ]]; then
        domain="[${BASH_REMATCH[1]}]"
        port=${BASH_REMATCH[3]:-}
    elif [[ $authority =~ ^([A-Za-z0-9._-]+)(:([0-9]+))?$ ]]; then
        domain=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[3]:-}
    else
        return 1
    fi

    if [[ -n $port ]] && (( port < 1 || port > 65535 )); then
        return 1
    fi

    if [[ -n $path ]]; then
        # Paths are supported, but configuration-breaking characters are not.
        if [[ $path == *\"* || $path == *"'"* || $path == *';'* || $path == *'{'* || $path == *'}'* || $path == *$'\r'* || $path == *$'\n'* ]]; then
            return 1
        fi
        path=${path%%\?*}
        path=${path%%\#*}
        [[ $path == / ]] && path=''
        while [[ $path == */ && $path != / ]]; do path=${path%/}; done
    fi

    printf '%s|%s|%s|%s\n' "$proto" "$domain" "$port" "$path"
}

is_ip_address() {
    local address=${1#[}
    address=${address%]}
    [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $address == *:* ]]
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
    temp=$(getopt -o y:r:s:m:R:dD:hY --long you-domain:,r-domain:,stream-domain:,cert-domain:,resolver:,parse-cert-domain,dns:,cf-token:,cf-account-id:,gh-proxy:,remove:,yes,no-proxy-redirect,help -n "$(basename "$0")" -- "$@") || exit 1
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
            -h|--help) show_help; exit 0 ;;
            --) shift; break ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done

    [[ -n $you_domain_full ]] && process_url_input "$you_domain_full" you
    [[ -n $r_domain_full ]] && process_url_input "$r_domain_full" r

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
    if is_ip_address "$you_domain"; then
        format_cert_domain=${you_domain//[\[\]]/}
    elif [[ -n $cert_domain ]]; then
        format_cert_domain=$cert_domain
    elif [[ $parse_cert_domain == yes && $you_domain == *.*.* ]]; then
        format_cert_domain=${you_domain#*.}
    else
        format_cert_domain=$you_domain
    fi

    if [[ -n $manual_resolver ]]; then
        resolver="$manual_resolver valid=60s"
    else
        resolver=$(get_resolver_host)
        if ! has_ipv6; then
            resolver+=" ipv6=off"
        fi
        resolver+=" valid=60s"
    fi
}

display_summary() {
    prepare_summary_values
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
    for required_command in nginx curl socat openssl envsubst; do
        command -v "$required_command" >/dev/null 2>&1 || dependencies_ready=no
    done
    command -v crontab >/dev/null 2>&1 || dependencies_ready=no

    if [[ $dependencies_ready == yes ]]; then
        log_info "Nginx 和依赖已安装，跳过软件包安装。"
        $SUDO mkdir -p /etc/nginx/conf.d /etc/nginx/certs "$BACKUP_DIR"
        $SUDO rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default 2>/dev/null || true
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
        required_packages=(nginx curl ca-certificates socat cron openssl gettext-base)
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
    $SUDO rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable nginx >/dev/null 2>&1 || true
        $SUDO systemctl start nginx >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        $SUDO rc-update add nginx default >/dev/null 2>&1 || true
        $SUDO rc-service nginx start >/dev/null 2>&1 || true
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

    $SUDO cp "$tmp" "$main_conf"
    rm -f "$tmp"
    log_success "已向 nginx.conf 添加 /etc/nginx/conf.d/*.conf"
}

install_acme() {
    [[ $no_tls == yes ]] && return 0
    if [[ -x $ACME_SH ]]; then
        return 0
    fi

    setup_download_urls
    log_info "安装 acme.sh..."
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL "$ACME_INSTALL_URL" -o "$tmp"; then
        rm -f "$tmp"
        log_error "下载 acme.sh 失败: $ACME_INSTALL_URL"
        return 1
    fi
    sh "$tmp" --install-online
    rm -f "$tmp"
    "$ACME_SH" --set-default-ca --server letsencrypt
}

acme_cert_is_issued() {
    "$ACME_SH" --info -d "$format_cert_domain" --ecc 2>/dev/null | grep -q RealFullChainPath
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

    if is_ip_address "$you_domain"; then
        issue_extra+=(--certificate-profile shortlived --days 6)
        [[ $you_domain == *:* ]] && issue_extra+=(--listen-v6)
        dns_provider=''
    elif [[ $format_cert_domain != "$you_domain" ]]; then
        domain_args+=(-d "*.${format_cert_domain}")
    fi

    if ! acme_cert_is_issued; then
        cleanup_stale_acme_record
        log_info "申请证书: $format_cert_domain"
        if [[ -n $dns_provider ]]; then
            if [[ $dns_provider == cf ]]; then
                [[ -n $cf_token ]] && export CF_Token=$cf_token
                [[ -n $cf_account_id ]] && export CF_Account_ID=$cf_account_id
                if [[ (-z ${CF_Token:-} || -z ${CF_Account_ID:-}) && -t 0 ]]; then
                    read -r -p 'Cloudflare Token: ' CF_Token
                    read -r -p 'Cloudflare Account ID: ' CF_Account_ID
                    export CF_Token CF_Account_ID
                fi
            fi
            "$ACME_SH" --issue --dns "dns_${dns_provider}" "${domain_args[@]}" --keylength ec-256
        else
            if [[ $format_cert_domain != "$you_domain" ]] && ! is_ip_address "$you_domain"; then
                log_error "泛域名证书必须通过 -D 指定 DNS API 模式。"
                return 1
            fi

            local nginx_was_running=no
            if pgrep -x nginx >/dev/null 2>&1; then
                nginx_was_running=yes
                log_info "Standalone 验证需要占用 80 端口，暂时停止 Nginx。"
                if command -v systemctl >/dev/null 2>&1; then
                    $SUDO systemctl stop nginx
                elif command -v rc-service >/dev/null 2>&1; then
                    $SUDO rc-service nginx stop
                else
                    $SUDO nginx -s stop || true
                fi
            fi

            local issue_status=0
            "$ACME_SH" --issue --standalone "${domain_args[@]}" --keylength ec-256 "${issue_extra[@]}" || issue_status=$?

            if [[ $nginx_was_running == yes ]]; then
                if command -v systemctl >/dev/null 2>&1; then
                    $SUDO systemctl start nginx || true
                elif command -v rc-service >/dev/null 2>&1; then
                    $SUDO rc-service nginx start || true
                fi
            fi

            (( issue_status == 0 )) || return "$issue_status"
        fi
    fi

    $SUDO mkdir -p "$cert_dir"
    "$ACME_SH" --install-cert -d "$format_cert_domain" --ecc \
        --fullchain-file "$cert_dir/cert" \
        --key-file "$cert_dir/key" \
        --reloadcmd "$SUDO nginx -s reload"
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
        public_prefix="\$scheme://\$server_name:\$server_port/__emby_stream/$((i + 1))"
        escaped_public_prefix="\$scheme:\\/\\/\$server_name:\$server_port\/__emby_stream\/$((i + 1))"
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
        public_prefix="\$scheme://\$server_name:\$server_port/__emby_stream/$((i + 1))"
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
    cat > /tmp/00-emby-connection-map.conf <<'EOF'
map $http_upgrade $emby_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    $SUDO cp /tmp/00-emby-connection-map.conf "$map_conf"
    rm -f /tmp/00-emby-connection-map.conf

    local clean_domain=${you_domain//[\[\]]/}
    local conf_path="/etc/nginx/conf.d/${clean_domain}.${you_frontend_port}.conf"
    local tmp_conf
    tmp_conf=$(mktemp)

    local front_path=${you_domain_path:-/}
    [[ $front_path == */ ]] || front_path="${front_path}/"

    local main_proto main_authority main_upstream main_base_path
    main_proto=$(get_protocol "$r_http_frontend")
    main_authority="${r_domain}:${r_frontend_port}"
    main_base_path=${r_domain_path:-}
    main_upstream="${main_proto}://${main_authority}"

    {
        echo '# Generated by deploy-stream-domains.sh'
        echo '# Main upstream and fixed streaming upstreams are explicitly listed.'
        echo 'server {'
        if [[ $no_tls == yes ]]; then
            echo "    listen ${you_frontend_port};"
            echo "    listen [::]:${you_frontend_port};"
        else
            echo "    listen ${you_frontend_port} ssl http2;"
            echo "    listen [::]:${you_frontend_port} ssl http2;"
        fi
        echo "    server_name ${you_domain};"
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
            echo "        rewrite ^/__emby_stream/${id}/(.*)\$ ${base_path}/\$1 break;"
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
        echo "    location ${front_path} {"
        echo "        set \$emby_main_upstream '${main_upstream}';"
        if [[ $front_path != / ]]; then
            echo "        rewrite ^${front_path}(.*)\$ ${main_base_path}/\$1 break;"
        elif [[ -n $main_base_path ]]; then
            echo "        rewrite ^/(.*)\$ ${main_base_path}/\$1 break;"
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
            printf "        proxy_redirect '%s/' '\$scheme://\$server_name:\$server_port%s/';\n" "$main_origin" "${front_path%/}"
            if [[ $main_origin_no_port != "$main_origin" ]]; then
                printf "        proxy_redirect '%s/' '\$scheme://\$server_name:\$server_port%s/';\n" "$main_origin_no_port" "${front_path%/}"
            fi
        } >> "$tmp_conf"
    fi

    {
        echo '    }'
        echo '}'
    } >> "$tmp_conf"

    backup_file "$conf_path"
    $SUDO cp "$tmp_conf" "$conf_path"
    rm -f "$tmp_conf"
    log_success "配置文件已生成: $conf_path"
}

test_and_reload_nginx() {
    log_info '测试 Nginx 配置...'
    if ! $SUDO nginx -t; then
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl restart nginx
    elif command -v rc-service >/dev/null 2>&1; then
        $SUDO rc-service nginx restart
    else
        $SUDO nginx -s reload
    fi
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

    if [[ $force_yes != yes ]]; then
        if [[ ! -t 0 ]]; then
            log_error '非交互删除必须使用 --yes。'
            exit 1
        fi
        local answer
        read -r -p "确认删除 $conf_path？请输入 yes: " answer
        [[ $answer == yes ]] || { log_info '已取消。'; exit 0; }
    fi

    local cert_path cert_dir cert_name refs
    cert_path=$($SUDO awk '/ssl_certificate[[:space:]]+/ {gsub(/;/, "", $2); print $2; exit}' "$conf_path")
    $SUDO rm -f "$conf_path"

    if [[ -n $cert_path ]]; then
        cert_dir=$(dirname "$cert_path")
        cert_name=$(basename "$cert_dir")
        refs=$($SUDO grep -RslF "$cert_path" /etc/nginx/conf.d 2>/dev/null || true)
        if [[ -z $refs ]]; then
            $SUDO rm -rf "$cert_dir"
            if [[ -x $ACME_SH ]]; then
                "$ACME_SH" --remove -d "$cert_name" --ecc >/dev/null 2>&1 || true
            fi
        else
            log_warn "证书仍被其他站点引用，未删除: $cert_dir"
        fi
    fi

    test_and_reload_nginx
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
        local protocol
        protocol=$(get_protocol "$no_tls")
        log_success '部署成功！'
        echo -e "${GREEN}访问地址: ${protocol}://${you_domain}:${you_frontend_port}${you_domain_path}${NC}"
    else
        log_error 'Nginx 配置测试失败。请检查 /etc/nginx/conf.d/ 下的配置和错误日志。'
        exit 1
    fi
}

main "$@"
