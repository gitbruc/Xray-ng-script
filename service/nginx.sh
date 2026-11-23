#!/usr/bin/env bash
# =============================================================================
# 注释: 通过 Gemini-Neon 生成。
# 脚本名称: nginx.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 功能描述: 用于从源代码编译、安装、更新和卸载 Nginx 的脚本。
#           支持集成最新版 OpenSSL 和可选的 Brotli 压缩模块。
#           负责管理 Nginx 的 systemd 服务配置。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, gcc, make, awk, grep, sed, sort, tr, systemctl, jq,
#       dnf/yum/apt (用于安装编译依赖)
# 配置:
#   - ${TMPFILE_DIR}/: 用于下载和编译的临时工作目录
#   - ${NGINX_PATH}/: Nginx 的安装目录 (/usr/local/nginx)
#   - ${NGINX_LOG_PATH}/: Nginx 的日志目录 (/var/log/nginx)
#   - /etc/systemd/system/nginx.service: Nginx systemd 服务文件
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
# 相关链接:
#   - NGINX 官方文档: https://nginx.org/en/linux_packages.html
#   - NGINX 更新参考: https://zhuanlan.zhihu.com/p/193078620
#   - GCC 优化参考: https://github.com/kirin10000/Xray-script
#   - Brotli 模块参考: https://www.nodeseek.com/post-37224-1
#   - ngx_brotli 模块: https://github.com/google/ngx_brotli
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 注册一个退出时执行的清理函数 egress
trap egress EXIT

# 定义颜色代码，用于在终端输出带颜色的信息
readonly RED='\033[31m'    # 红色
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly NC='\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 定义项目中各个重要目录与配置文件的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主要配置文件路径

# 创建一个唯一的临时目录用于编译工作，并在脚本退出时清理
# 如果创建失败则退出脚本
readonly TMPFILE_DIR="$(mktemp -d -p "${PROJECT_ROOT}" -t nginxtemp.XXXXXXXX)" || exit 1

# 定义 Nginx 和其日志的安装/存储路径
readonly NGINX_PATH="/usr/local/nginx"   # Nginx 安装主目录
readonly NGINX_LOG_PATH="/var/log/nginx" # Nginx 日志目录

# --- 全局变量声明 ---
# 声明用于存储是否启用 Brotli 模块选项、语言参数和国际化数据的全局变量
declare is_enable_brotli="" # 存储用户是否选择启用 Brotli ('Y' 或 '')
declare LANG_PARAM=''       # (未在脚本中实际使用，可能是预留)
declare I18N_DATA=''        # 存储从 i18n JSON 文件中读取的全部数据
# 声明用于存储编译器优化标志的全局数组
declare -a cflags=() # 存储 GCC 编译优化选项

# =============================================================================
# 函数名称: egress
# 功能描述: 在脚本退出时执行的清理操作。
#           主要用于删除临时工作目录。
# 参数: 无
# 返回值: 无 (直接执行清理命令)
# =============================================================================
function egress() {
    local exit_code=$?
    # 如果 swap 文件存在，则关闭 swap（忽略未挂载时的报错）
    [[ -e "${TMPFILE_DIR}/swap" ]] && swapoff "${TMPFILE_DIR}/swap" 2>/dev/null || true
    # 删除临时工作目录
    rm -rf "${TMPFILE_DIR}"
    return "${exit_code}"
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
#           1. 从 config.json 读取语言设置。
#           2. 如果设置为 "auto"，则尝试从系统环境变量 $LANG 推断语言。
#           3. 根据确定的语言，加载对应的 JSON i18n 文件。
#           4. 将文件内容读入全局变量 I18N_DATA。
# 参数: 无
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# 退出码: 如果 i18n 文件不存在，则输出错误信息并退出脚本 (exit 1)
# =============================================================================
function load_i18n() {
    # 从配置文件中读取语言设置
    local lang=""
    if [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
        lang="$(jq -r '.language // "auto"' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    fi
    [[ -z "${lang}" || "${lang}" == "null" ]] && lang="auto"

    # 如果语言设置为 "auto"，则使用系统环境变量 LANG 的第一部分作为语言代码
    if [[ "$lang" == "auto" ]]; then
        lang="${LANG%%_*}"
        lang="${lang%%.*}"
        case "${lang}" in
        "" | C | POSIX) lang="en" ;;
        esac
    fi

    # 构造 i18n 文件的完整路径
    local i18n_file="${I18N_DIR}/${lang}.json"

    # 检查 i18n 文件是否存在
    if [[ ! -f "${i18n_file}" ]]; then
        # 文件不存在时，根据语言输出不同的错误信息
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        # 退出脚本，错误码为 1
        exit 1
    fi

    # 读取 i18n 文件的全部内容到全局变量 I18N_DATA
    I18N_DATA="$(jq '.' "${i18n_file}")"
}

# =============================================================================
# 函数名称: print_info
# 功能描述: 以绿色打印信息级别的提示消息。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function print_info() {
    # 从 i18n 数据中读取 "信息" 标题，然后用绿色打印消息
    local title="Info"
    [[ -n "${I18N_DATA}" ]] && title="$(echo "$I18N_DATA" | jq -r '.title.info // "Info"')"
    printf '%b[%s]%b %s\n' "${GREEN}" "${title}" "${NC}" "$*" >&2
}

# =============================================================================
# 函数名称: print_warn
# 功能描述: 以黄色打印警告级别的提示消息。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function print_warn() {
    # 从 i18n 数据中读取 "警告" 标题，然后用黄色打印消息
    local title="Warn"
    [[ -n "${I18N_DATA}" ]] && title="$(echo "$I18N_DATA" | jq -r '.title.warn // "Warn"')"
    printf '%b[%s]%b %s\n' "${YELLOW}" "${title}" "${NC}" "$*" >&2
}

# =============================================================================
# 函数名称: print_error
# 功能描述: 以红色打印错误级别的提示消息，并退出脚本。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2，然后 exit 1)
# =============================================================================
function print_error() {
    # 从 i18n 数据中读取 "错误" 标题，然后用红色打印消息
    local title="Error"
    [[ -n "${I18N_DATA}" ]] && title="$(echo "$I18N_DATA" | jq -r '.title.error // "Error"')"
    printf '%b[%s]%b %s\n' "${RED}" "${title}" "${NC}" "$*" >&2
    # 打印错误信息后退出脚本，错误码为 1
    exit 1
}

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# 参数:
#   $1: 要检查的命令名称
# 返回值: 0-命令存在 1-命令不存在 (由命令检查工具的退出码决定)
# =============================================================================
function cmd_exists() {
    local cmd="$1" # 获取命令名称参数

    # 尝试使用不同的方法检查命令是否存在
    if eval type type >/dev/null 2>&1; then
        # 使用 type 命令检查
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        # 使用 command -v 命令检查
        command -v "$cmd" >/dev/null 2>&1
    else
        # 使用 which 命令检查
        which "$cmd" >/dev/null 2>&1
    fi
}

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 参数: 无
# 返回值: 操作系统名称 (echo 输出: debian/ubuntu/centos/amazon/...)
# =============================================================================
function _os() {
    local os="" # 声明局部变量存储操作系统名称

    # 检查 Debian/Ubuntu 系列
    if [[ -f "/etc/debian_version" ]]; then
        # 读取 /etc/os-release 文件并提取 ID 字段
        source /etc/os-release && os="${ID}"
        # 输出检测到的操作系统名称
        printf -- "%s" "${os}" && return
    fi

    # 检查 Red Hat/CentOS 系列
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        # 输出检测到的操作系统名称
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# 参数: 无
# 返回值: 完整的操作系统版本信息 (echo 输出)
# =============================================================================
function _os_full() {
    # 检查 Red Hat/CentOS 系列
    if [[ -f /etc/redhat-release ]]; then
        # 从 /etc/redhat-release 文件中提取发行版名称和版本号
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi

    # 检查通用的 os-release 文件
    if [[ -f /etc/os-release ]]; then
        # 从 /etc/os-release 文件中提取 PRETTY_NAME 字段
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi

    # 检查 LSB (Linux Standard Base) 发布文件
    if [[ -f /etc/lsb-release ]]; then
        # 从 /etc/lsb-release 文件中提取 DESCRIPTION 字段
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# 参数: 无
# 返回值: 操作系统的主版本号 (echo 输出)
# =============================================================================
function _os_ver() {
    # 调用 _os_full 函数获取完整版本信息，然后提取其中的数字和点
    local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
    # 输出主版本号 (第一个点号前的部分)
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: _error_detect
# 功能描述: 执行命令并检查其退出状态，如果失败则打印错误并退出。
# 参数:
#   $1: 要执行的命令字符串
# 返回值: 无 (执行成功或失败后退出)
# =============================================================================
function replace_placeholder() {
    local text="$1"
    local placeholder="$2"
    local replacement="$3"
    local out=""
    while [[ "${text}" == *"${placeholder}"* ]]; do
        out+="${text%%"${placeholder}"*}${replacement}"
        text="${text#*"${placeholder}"}"
    done
    printf '%s' "${out}${text}"
}

function _error_detect() {
    local cmd="$1" # 获取要执行的命令
    local exec_tpl="$(echo "$I18N_DATA" | jq -r '.nginx.compile.executing')"
    print_info "$(replace_placeholder "${exec_tpl}" '${cmd}' "${cmd}")"
    eval "${cmd}"
    if [[ $? -ne 0 ]]; then
        local fail_tpl="$(echo "$I18N_DATA" | jq -r '.nginx.compile.fail_exec_cmd')"
        print_error "$(replace_placeholder "${fail_tpl}" '${cmd}' "${cmd}")"
    fi
}

# =============================================================================
# 函数名称: _version_ge
# 功能描述: 比较两个版本号字符串，判断第一个是否大于等于第二个。
# 参数:
#   $1: 第一个版本号
#   $2: 第二个版本号
# 返回值: 0-第一个版本 >= 第二个版本 1-否则 (由 test 命令决定)
# =============================================================================
function _version_ge() {
    # 使用 sort -rV (版本号逆序排序) 来比较版本
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}

# =============================================================================
# 函数名称: _version_gt
# 功能描述: 比较两个版本号字符串，判断第一个是否严格大于第二个。
# 参数:
#   $1: 第一个版本号
#   $2: 第二个版本号
# 返回值: 0-第一个版本 > 第二个版本 1-否则
# =============================================================================
function _version_gt() {
    [[ "$1" != "$2" ]] && _version_ge "$1" "$2"
}

# =============================================================================
# 函数名称: _install
# 功能描述: 根据操作系统类型安装指定的软件包。
# 参数:
#   $@: 要安装的软件包名称列表
# 返回值: 无 (执行包管理器命令安装软件)
# =============================================================================
function _install() {
    local packages_name="$@"    # 获取所有要安装的包名
    local installed_packages="" # 存储已安装的包列表

    case "$(_os)" in # 根据操作系统类型进行分支处理
    centos)
        # 检查是否使用 dnf 包管理器 (较新版本 CentOS/Fedora)
        if cmd_exists "dnf"; then
            # 添加必要的 dnf 插件和 EPEL 源
            packages_name="dnf-plugins-core epel-release epel-next-release ${packages_name}"
            installed_packages="$(dnf list installed 2>/dev/null)" # 获取已安装包列表
            # 针对 CentOS 9 的特殊处理
            if [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 9 ]]; then
                # 启用 EPEL 和 Remi 仓库
                if [[ "${packages_name}" =~ geoip\-devel ]] && ! echo "${installed_packages}" | grep -iwq "geoip-devel"; then
                    dnf update -y
                    # 安装 EPEL 和 EPEL-Next 源
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm"
                    _error_detect "dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm"
                    # 启用 Remi 模块化仓库
                    _error_detect "dnf config-manager --set-enabled remi-modular"
                    # 刷新包信息
                    _error_detect "dnf update --refresh"
                    # 安装 GeoIP-devel，指定使用 Remi 仓库
                    dnf update -y
                    _error_detect "dnf --enablerepo=remi install -y GeoIP-devel"
                fi
            # 针对 CentOS 8 的特殊处理
            elif [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 8 ]]; then
                # 禁用可能冲突的 container-tools 模块流
                if ! dnf module list 2>/dev/null | grep container-tools | grep -iwq "\[x\]"; then
                    _error_detect "dnf module disable -y container-tools"
                fi
            fi
            dnf update -y # 更新包列表
            # 遍历并安装每个包（如果尚未安装）
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "dnf install -y "${package_name}""
                fi
            done
        else
            # 使用 yum 包管理器 (较旧版本 CentOS)
            packages_name="epel-release yum-utils ${packages_name}"
            installed_packages="$(yum list installed 2>/dev/null)"
            yum update -y
            for package_name in ${packages_name}; do
                if ! echo "${installed_packages}" | grep -iwq "${package_name}"; then
                    _error_detect "yum install -y "${package_name}""
                fi
            done
        fi
        ;;
    # 处理 Debian 和 Ubuntu 系统
    ubuntu | debian)
        local -a missing_pkgs=()
        for package_name in ${packages_name}; do
            if ! dpkg-query -W -f='${Status}\n' "${package_name}" 2>/dev/null | grep -q "install ok installed"; then
                missing_pkgs+=("${package_name}")
            fi
        done
        if ((${#missing_pkgs[@]} > 0)); then
            _error_detect "apt-get update -y"
            _error_detect "DEBIAN_FRONTEND=noninteractive apt-get install -y ${missing_pkgs[*]}"
        fi
        ;;
    esac
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# 参数: 无
# 返回值: 无 (受支持则继续，不受支持则 print_error 退出)
# =============================================================================
function check_os() {
    # 检查是否能识别操作系统
    [[ -z "$(_os)" ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_os')"

    # 根据识别到的操作系统进行版本检查
    case "$(_os)" in
    ubuntu)
        # Ubuntu 需要 20.04 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 20 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_ubuntu')"
        ;;
    debian)
        # Debian 需要 10 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 10 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_debian')"
        ;;
    centos)
        # CentOS/RHEL 需要 7 或更高版本
        [[ -n "$(_os_ver)" && "$(_os_ver)" -lt 7 ]] && print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_centos')"
        ;;
    *)
        # 其他识别到但不支持的系统
        print_error "$(echo "$I18N_DATA" | jq -r '.nginx.os.unsupported_os')"
        ;;
    esac
}

# =============================================================================
# 函数名称: swap_on
# 功能描述: 创建并启用临时 swap 空间。
# 参数:
#   $1: 请求的 swap 大小 (MB)
# 返回值: 无 (执行 swap 文件创建和启用)
# =============================================================================
function swap_on() {
    local mem="${1:-0}"
    if [[ "${mem}" =~ ^[0-9]+$ ]] && ((mem > 0)); then
        if dd if=/dev/zero of="${TMPFILE_DIR}/swap" bs=1M count="${mem}" status=none 2>/dev/null; then
            chmod 0600 "${TMPFILE_DIR}/swap"
            if ! (mkswap "${TMPFILE_DIR}/swap" >/dev/null 2>&1 && swapon "${TMPFILE_DIR}/swap" 2>/dev/null); then
                rm -f "${TMPFILE_DIR}/swap"
                print_warn "当前虚拟化环境不支持挂载临时 swap，已跳过并继续编译。"
            fi
        fi
    fi
}

# =============================================================================
# 函数名称: backup_files
# 功能描述: 备份指定目录下的所有 .so 动态模块文件。
# 参数:
#   $1: 要备份的目录路径
#   $2: 可选的日期后缀 (默认为当天 YYYY-MM-DD)
# 返回值: 无 (执行文件备份操作)
# =============================================================================
function backup_files() {
    local backup_dir="$1"                         # 获取要备份的目录路径
    local current_date="${2:-$(date +%F)}"        # 获取当前日期 (YYYY-MM-DD)
    [[ ! -d "${backup_dir}" ]] && return 0        # 目录不存在则直接返回
    # 仅遍历目录中的 .so 文件，避免重复备份历史日期文件
    for file in "${backup_dir}/"*.so; do
        if [[ -f "$file" ]]; then                                          # 检查是否为普通文件
            local file_name="$(basename "$file")"                          # 获取文件名
            local backup_file="${backup_dir}/${file_name}_${current_date}" # 构造备份文件名
            mv -f "$file" "$backup_file"                                   # 重命名文件以进行备份
            echo "$(echo "$I18N_DATA" | jq -r '.nginx.backup_files.backup'): ${file} -> ${backup_file}。"
        fi
    done
}

# =============================================================================
# 函数名称: compile_dependencies
# 功能描述: 安装编译 Nginx 所需的依赖包。
# 参数: 无
# 返回值: 无 (调用 _install 安装依赖)
# =============================================================================
function compile_dependencies() {
    # 打印安装依赖信息
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.install_deps')"
    # 安装基础工具和库
    _install ca-certificates curl wget gcc make git openssl tzdata socat
    case "$(_os)" in
    centos)
        # 安装 CentOS 特定的工具和开发库
        _install bind-utils gcc-c++ perl-IPC-Cmd perl-Getopt-Long perl-Data-Dumper perl-Time-Piece
        _install pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel geoip-devel perl-ExtUtils-Embed gperftools-devel perl-devel brotli-devel
        # 检查并安装 Perl 模块 FindBin
        if ! perl -e "use FindBin" &>/dev/null; then
            _install perl-FindBin
        fi
        ;;
    debian | ubuntu)
        # 安装 Debian/Ubuntu 特定的工具和开发库
        _install dnsutils g++ perl-base perl
        _install libpcre2-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev libgoogle-perftools-dev libperl-dev libbrotli-dev
        ;;
    esac
}

# =============================================================================
# 函数名称: gen_cflags
# 功能描述: 生成优化的 C 编译器标志 (CFLAGS)。
# 参数: 无
# 返回值: 无 (直接修改全局数组 cflags)
# =============================================================================
function gen_cflags() {
    # 初始化 cflags 数组，包含基本优化
    cflags=('-g0' '-O3') # -g0: 不生成调试信息; -O3: 最高级别优化
    # 缓存一次 gcc 帮助输出，避免重复调用 15 次外部进程
    local gcc_help="$(gcc -v --help 2>&1)"
    if grep -qw -- '-fstack-reuse' <<<"${gcc_help}"; then
        cflags+=('-fstack-reuse=all')
    fi
    if grep -qw -- '-fdwarf2-cfi-asm' <<<"${gcc_help}"; then
        cflags+=('-fdwarf2-cfi-asm')
    fi
    if grep -qw -- '-fplt' <<<"${gcc_help}"; then
        cflags+=('-fplt')
    fi
    if grep -qw -- '-ftrapv' <<<"${gcc_help}"; then
        cflags+=('-fno-trapv')
    fi
    if grep -qw -- '-fexceptions' <<<"${gcc_help}"; then
        cflags+=('-fno-exceptions')
    elif grep -qw -- '-fhandle-exceptions' <<<"${gcc_help}"; then
        cflags+=('-fno-handle-exceptions')
    fi
    if grep -qw -- '-funwind-tables' <<<"${gcc_help}"; then
        cflags+=('-fno-unwind-tables')
    fi
    if grep -qw -- '-fasynchronous-unwind-tables' <<<"${gcc_help}"; then
        cflags+=('-fno-asynchronous-unwind-tables')
    fi
    if grep -qw -- '-fstack-check' <<<"${gcc_help}"; then
        cflags+=('-fno-stack-check')
    fi
    if grep -qw -- '-fstack-clash-protection' <<<"${gcc_help}"; then
        cflags+=('-fno-stack-clash-protection')
    fi
    if grep -qw -- '-fstack-protector' <<<"${gcc_help}"; then
        cflags+=('-fno-stack-protector')
    fi
    if grep -qw -- '-fcf-protection=' <<<"${gcc_help}"; then
        cflags+=('-fcf-protection=none')
    fi
    if grep -qw -- '-fsplit-stack' <<<"${gcc_help}"; then
        cflags+=('-fno-split-stack')
    fi
    if grep -qw -- '-fsanitize' <<<"${gcc_help}"; then
        : >"${TMPFILE_DIR}/temp.c"
        if gcc -E -fno-sanitize=all "${TMPFILE_DIR}/temp.c" >/dev/null 2>&1; then
            cflags+=('-fno-sanitize=all')
        fi
        rm -f "${TMPFILE_DIR}/temp.c"
    fi
    if grep -qw -- '-finstrument-functions' <<<"${gcc_help}"; then
        cflags+=('-fno-instrument-functions')
    fi
}

# =============================================================================
# 函数名称: source_compile
# 功能描述: 下载源码并编译 Nginx。
# 参数: 无
# 返回值: 无 (执行下载、配置和编译过程)
# =============================================================================
function fetch_latest_nginx_version() {
    curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/nginx/nginx/tags?per_page=100" |
        jq -r '.[].name // empty' |
        grep -E '^release-[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -rV | head -n 1 | sed 's/^release-/nginx-/'
}

function fetch_latest_openssl_tag() {
    local tag=""
    tag="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/openssl/openssl/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')"
    if [[ ! "${tag}" =~ ^openssl-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        tag="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/openssl/openssl/tags?per_page=100" |
            jq -r '.[].name // empty' |
            grep -E '^openssl-[0-9]+\.[0-9]+\.[0-9]+$' |
            sort -rV | head -n 1)"
    fi
    printf '%s\n' "${tag}"
}

function source_compile() {
    local nginx_version="${1:-}"
    local openssl_tag="${2:-}"

    cd "${TMPFILE_DIR}" || print_error "无法进入临时目录: ${TMPFILE_DIR}"
    if [[ -z "${nginx_version}" || -z "${openssl_tag}" ]]; then
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.fetch_versions')"
        [[ -z "${nginx_version}" ]] && nginx_version="$(fetch_latest_nginx_version)"
        [[ -z "${openssl_tag}" ]] && openssl_tag="$(fetch_latest_openssl_tag)"
    fi
    # GitHub 归档解压后的目录名格式为 openssl-openssl-x.y.z
    local openssl_version="openssl-${openssl_tag}"

    # 校验版本号是否成功获取
    if [[ -z "${nginx_version}" || -z "${openssl_tag}" ]]; then
        print_error "获取 Nginx 或 OpenSSL 最新版本号失败，请检查网络连接或 GitHub API 限流。"
    fi

    # 生成编译器优化标志
    gen_cflags

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.download_nginx')"
    _error_detect "curl -fsSL --connect-timeout 15 --max-time 120 -o '${nginx_version}.tar.gz' 'https://nginx.org/download/${nginx_version}.tar.gz'"
    _error_detect "tar -zxf '${nginx_version}.tar.gz'"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.download_openssl')"
    _error_detect "curl -fsSL --connect-timeout 15 --max-time 180 -o '${openssl_version}.tar.gz' 'https://github.com/openssl/openssl/archive/${openssl_tag}.tar.gz'"
    _error_detect "tar -zxf '${openssl_version}.tar.gz'"

    # 如果启用了 Brotli，则浅克隆并初始化 ngx_brotli 子模块
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.fetch_brotli')"
        _error_detect "git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/google/ngx_brotli '${TMPFILE_DIR}/ngx_brotli'"
    fi

    # 进入 Nginx 源码目录
    cd "${TMPFILE_DIR}/${nginx_version}" || print_error "无法进入源码目录: ${nginx_version}"

    # 对 Nginx 源码进行一些 sed 修改，以优化 Perl 模块的编译
    sed -i "s/OPTIMIZE[ \\t]*=>[ \\t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    sed -i 's/NGX_PERL_CFLAGS="$CFLAGS `$NGX_PERL -MExtUtils::Embed -e ccopts`"/NGX_PERL_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf
    sed -i 's/NGX_PM_CFLAGS=`$NGX_PERL -MExtUtils::Embed -e ccopts`/NGX_PM_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf

    # 执行 Nginx 的 configure 脚本，设置各种编译选项和模块
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.configure')"
    local -a configure_args=(
        --prefix="${NGINX_PATH}"
        --user=root
        --group=root
        --with-threads
        --with-file-aio
        --with-http_ssl_module
        --with-http_v2_module
        --with-http_v3_module
        --with-http_realip_module
        --with-http_addition_module
        --with-http_xslt_module=dynamic
        --with-http_image_filter_module=dynamic
        --with-http_geoip_module=dynamic
        --with-http_sub_module
        --with-http_dav_module
        --with-http_flv_module
        --with-http_mp4_module
        --with-http_gunzip_module
        --with-http_gzip_static_module
        --with-http_auth_request_module
        --with-http_random_index_module
        --with-http_secure_link_module
        --with-http_degradation_module
        --with-http_slice_module
        --with-http_stub_status_module
        --with-http_perl_module=dynamic
        --with-mail=dynamic
        --with-mail_ssl_module
        --with-stream
        --with-stream_ssl_module
        --with-stream_realip_module
        --with-stream_geoip_module=dynamic
        --with-stream_ssl_preread_module
        --with-google_perftools_module
        --with-compat
        --with-cc-opt="${cflags[*]}"
        --with-openssl="../${openssl_version}"
        --with-openssl-opt="${cflags[*]}"
    )
    if [[ "${is_enable_brotli}" =~ ^[Yy]$ ]]; then
        configure_args+=(--add-module="../ngx_brotli")
    fi

    ./configure "${configure_args[@]}" || print_error "Nginx ./configure 失败，请检查依赖库与编译环境。"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.swap')"
    # 创建并启用 512MB swap 空间以辅助编译
    swap_on 512

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.compile.start_compile')"
    # 使用所有 CPU 核心并行编译
    _error_detect "make -j$(nproc)"
}

# =============================================================================
# 函数名称: source_install
# 功能描述: 编译并安装 Nginx。
# 参数: 无
# 返回值: 无 (执行编译和安装过程)
# =============================================================================
function source_install() {
    source_compile # 先执行编译
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.install.start_install')"
    _error_detect "make install"                      # 执行安装 (将文件复制到 --prefix 指定的目录)
    mkdir -p "${NGINX_LOG_PATH}"                      # 创建日志目录
    ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx # 创建软链接以便全局使用 nginx 命令
}

# =============================================================================
# 函数名称: source_update
# 功能描述: 检查并更新 Nginx (如果需要)。
# 参数: 无
# 返回值: 0-操作正常完成（无论是否需要更新）
# =============================================================================
function source_update() {
    cmd_exists "nginx" || print_error "当前系统未检测到已安装的 Nginx，请先执行 --install。"

    # 若旧版 nginx.service 仍包含会删除 Xray 套接字或收紧权限为 711 的语句，自动迁移修复
    if [[ -f /etc/systemd/system/nginx.service ]] && grep -Eq '(rm -rf /dev/shm/nginx$|chmod 711 /dev/shm/nginx$)' /etc/systemd/system/nginx.service; then
        print_warn "检测到旧版 nginx.service 会清理 /dev/shm/nginx 或重置权限为 711，正在自动修复 systemd 服务配置..."
        systemctl_config_nginx
    fi

    # 如果未手动传 --brotli，自动检测当前 Nginx 是否已编译 Brotli 并继承该状态
    if [[ -z "${is_enable_brotli}" ]] && nginx -V 2>&1 | grep -q "ngx_brotli"; then
        is_enable_brotli='Y'
        print_info "检测到当前 Nginx 已启用 ngx_brotli 模块，更新时将自动保留。"
    fi

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.fetch_versions')"
    local latest_nginx_version="$(fetch_latest_nginx_version)"
    local latest_openssl_version="$(fetch_latest_openssl_tag)"

    if [[ -z "${latest_nginx_version}" || -z "${latest_openssl_version}" ]]; then
        print_error "获取 Nginx 或 OpenSSL 最新版本号失败，请检查网络连接或 GitHub API 限流。"
    fi

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.read_current_versions')"
    # 获取当前安装的 Nginx 和 OpenSSL 版本
    local current_version_nginx="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
    local current_version_openssl="$(nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}')"

    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.check_update')"
    # 使用 _version_gt 函数严格比较版本，仅在任一组件存在更高版本时才进行更新
    if _version_gt "${latest_nginx_version#*-}" "${current_version_nginx}" || _version_gt "${latest_openssl_version#*-}" "${current_version_openssl}"; then
        # 直接复用刚查询到的版本号，避免二次调用 GitHub API 触发限流
        source_compile "${latest_nginx_version}" "${latest_openssl_version}"
        print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.start_update')"

        local current_date="$(date +%F)"
        # 备份旧的 nginx 二进制文件
        mv -f "${NGINX_PATH}/sbin/nginx" "${NGINX_PATH}/sbin/nginx_${current_date}" || print_error "备份旧版 Nginx 失败。"
        # 备份旧的动态模块
        backup_files "${NGINX_PATH}/modules" "${current_date}"
        # 复制新编译的 nginx 二进制文件和动态模块
        cp -f objs/nginx "${NGINX_PATH}/sbin/nginx" || print_error "写入新版 Nginx 二进制失败。"
        mkdir -p "${NGINX_PATH}/modules"
        if compgen -G "objs/*.so" >/dev/null; then
            cp -f objs/*.so "${NGINX_PATH}/modules/" || print_error "写入新版动态模块失败。"
        fi
        # 更新软链接
        ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx

        # 测试新版本二进制文件与当前配置的兼容性，失败则自动回滚
        if ! "${NGINX_PATH}/sbin/nginx" -t >/dev/null 2>&1; then
            mv -f "${NGINX_PATH}/sbin/nginx_${current_date}" "${NGINX_PATH}/sbin/nginx"
            for bak in "${NGINX_PATH}/modules/"*.so_"${current_date}"; do
                [[ -f "$bak" ]] && mv -f "$bak" "${bak%_${current_date}}"
            done
            print_error "新版 Nginx 配置校验 (nginx -t) 失败，已自动回滚到旧版本。"
        fi

        # 同步更新脚本配置中的 Nginx 版本记录
        if [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
            local new_ver="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
            local updated_cfg=""
            if [[ -n "${new_ver}" ]] && updated_cfg="$(jq --arg v "${new_ver}" '.nginx.version = $v' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)" && [[ -n "${updated_cfg}" ]]; then
                local tmp_cfg="${SCRIPT_CONFIG_PATH}.tmp.$$"
                printf '%s\n' "${updated_cfg}" >"${tmp_cfg}" && mv -f "${tmp_cfg}" "${SCRIPT_CONFIG_PATH}"
            fi
        fi

        # 如果 Nginx 服务正在运行，则执行平滑升级
        if systemctl is-active --quiet nginx; then
            print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.smooth_upgrade')"
            local old_pid=""
            [[ -f "/run/nginx.pid" ]] && old_pid="$(cat /run/nginx.pid)"

            if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
                # 启动新的 Nginx 主进程 (旧进程仍在运行)
                kill -USR2 "${old_pid}"

                # 等待最多 5 秒，确保旧主进程重命名 .oldbin 且新主进程生成新 PID 文件
                local wait_count=0
                while [[ ! -f "/run/nginx.pid.oldbin" || ! -f "/run/nginx.pid" || "$(cat /run/nginx.pid 2>/dev/null)" == "${old_pid}" ]] && [[ ${wait_count} -lt 25 ]]; do
                    sleep 0.2
                    wait_count=$((wait_count + 1))
                done

                # 检查旧主进程与新主进程是否均已就绪
                if [[ -f "/run/nginx.pid.oldbin" && -f "/run/nginx.pid" && "$(cat /run/nginx.pid)" != "${old_pid}" ]]; then
                    # 优雅地关闭旧工作进程
                    kill -WINCH "${old_pid}"
                    sleep 1
                    # 优雅地退出旧主进程
                    kill -QUIT "${old_pid}"
                else
                    print_warn "平滑升级等待新主进程超时，转为执行 systemctl restart nginx。"
                    systemctl restart nginx
                fi
            else
                print_info "$(echo "$I18N_DATA" | jq -r '.nginx.update.no_old_process')"
                systemctl restart nginx
            fi
        fi
        return 0
    else
        print_info "当前 Nginx (${current_version_nginx}) 与 OpenSSL (${current_version_openssl}) 已是最新版本，无需更新。"
        return 0
    fi
}

# =============================================================================
# 函数名称: purge_nginx
# 功能描述: 完全卸载 Nginx。
# 参数: 无
# 返回值: 无 (执行卸载操作)
# =============================================================================
function purge_nginx() {
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.purge.start_purge')"
    systemctl -q is-active nginx && systemctl stop nginx || true
    systemctl -q is-enabled nginx && systemctl disable nginx || true
    rm -rf "${NGINX_PATH}"                   # 删除安装目录
    rm -f /usr/sbin/nginx                    # 删除软链接
    rm -f /etc/systemd/system/nginx.service  # 删除 systemd 服务文件
    rm -rf "${NGINX_LOG_PATH}"               # 删除日志目录
    systemctl daemon-reload                  # 重新加载 systemd 配置
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.purge.purged')"
}

# =============================================================================
# 函数名称: systemctl_config_nginx
# 功能描述: 配置 Nginx 的 systemd 服务文件。
#           仅清理 tcmalloc 子目录，不删除 /dev/shm/nginx 且保持 1777 权限，
#           避免重启 Nginx 时误删 Xray 的 UDS 套接字或破坏 User=xray 写入权限。
# 参数: 无
# 返回值: 无 (创建服务文件并重新加载 systemd)
# =============================================================================
function systemctl_config_nginx() {
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.configure')"
    # 使用 here document 创建服务文件内容
    cat >/etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
# 准备共享内存目录并仅重置 tcmalloc 子目录（保留 Xray 的 UDS 套接字与 1777 权限）
ExecStartPre=/bin/mkdir -p /dev/shm/nginx
ExecStartPre=/bin/chmod 1777 /dev/shm/nginx
ExecStartPre=/bin/rm -rf /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/mkdir -p /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chmod 1777 /dev/shm/nginx/tcmalloc
# 测试配置文件
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
# 启动 Nginx
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
# 重载 Nginx
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
# 停止 Nginx
ExecStop=/bin/kill -s QUIT \$MAINPID
# 停止后仅清理 tcmalloc 子目录，避免误删运行中的 Xray UDS 套接字
ExecStopPost=/bin/rm -rf /dev/shm/nginx/tcmalloc
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload # 重新加载 systemd 配置以使新服务生效
    print_info "$(echo "$I18N_DATA" | jq -r '.nginx.service.complete')"
}

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本使用帮助信息。
# 参数: 无
# 返回值: 无 (打印帮助信息到标准输出并 exit 0)
# =============================================================================
function show_help() {
    # 从 i18n 数据中读取帮助信息的各个部分
    local usage="$(echo "$I18N_DATA" | jq -r '.nginx.help.usage' | sed "s|\${script_name}|$0|")"
    local options_title="$(echo "$I18N_DATA" | jq -r '.nginx.help.options_title')"
    local opt_install="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_install')"
    local opt_update="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_update')"
    local opt_brotli="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_brotli')"
    local opt_purge="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_purge')"
    local opt_help="$(echo "$I18N_DATA" | jq -r '.nginx.help.opt_help')"

    # 使用 here document 打印帮助信息
    cat <<EOF
${usage}
${options_title}:
  --install    ${opt_install}
  --update     ${opt_update}
  --brotli     ${opt_brotli}
  --purge      ${opt_purge}
  --help       ${opt_help}
EOF
    # 退出脚本，状态码为 0 (成功)
    exit 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 检查操作系统。
#           2. 解析命令行参数。
#           3. 根据参数执行安装、更新或卸载操作。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成 Nginx 管理)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    # 首先检查操作系统兼容性
    check_os

    # 初始化 action 变量
    local action=''

    # 使用 while 循环解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
        # 处理主要操作参数
        --install | --update | --purge)
            action="${1#--}" # 移除 '--' 前缀，获取操作名称 (install/update/purge)
            ;;
        # 处理 Brotli 选项
        --brotli)
            is_enable_brotli='Y' # 设置启用 Brotli 的标志
            ;;
        # 处理帮助选项
        --help)
            show_help # 显示帮助信息并退出
            ;;
        # 处理无效选项
        *)
            print_error "$(echo "$I18N_DATA" | jq -r '.nginx.main.invalid_option' | sed "s|\${option}|$1|")"
            ;;
        esac
        shift # 移动到下一个参数
    done

    [[ -z "${action}" ]] && show_help

    # 根据解析出的 action 执行相应的操作
    case "${action}" in
    install)
        compile_dependencies   # 安装依赖
        source_install         # 编译并安装
        systemctl_config_nginx # 配置 systemd 服务
        ;;
    update)
        compile_dependencies # 安装/更新依赖 (如果需要)
        source_update        # 检查并更新
        ;;
    purge)
        purge_nginx # 卸载
        ;;
    esac
}

# --- 脚本执行入口 ---
# 调用 main 函数，并将所有命令行参数传递给它
main "$@"