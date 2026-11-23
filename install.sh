#!/usr/bin/env bash
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: install.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 功能描述: Xray-script 项目的安装引导脚本。
#           负责检查和安装系统依赖、下载项目文件、处理命令行参数、
#           初始化配置、设置语言以及启动主菜单。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, jq, sed, awk, grep
# 配置:
#   - 从 GitHub 下载项目文件到指定目录
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取/设置语言和版本信息
# Xray 官方链接:
#   - Xray-core: https://github.com/XTLS/Xray-core
#   - REALITY: https://github.com/XTLS/REALITY
#   - XHTTP: https://github.com/XTLS/Xray-core/discussions/4113
# Xray 配置模板:
#   - Xray 配置示例: https://github.com/chika0801/Xray-examples
#   - 最优组合示例: https://github.com/lxhao61/integrated-examples
#   - xhttp 五合一配置: https://github.com/XTLS/Xray-core/discussions/4118
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 定义颜色代码，用于在终端输出带颜色的信息
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly RED='\033[31m'    # 红色
readonly NC='\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录绝对路径和文件名
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0")"                          # 当前脚本文件名

# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主配置文件路径

# --- 全局变量声明 ---
# 声明用于存储国际化数据、项目根目录和快速安装选项的全局变量
declare -A I18N_DATA=(
    ['error']='错误'
    ['root']='请使用 root 权限运行该脚本'
    ['supported']='不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    ['ubuntu']='不支持当前版本，请切换到 Ubuntu 16+ 重试'
    ['debian']='不支持当前版本，请切换到 Debian 9+ 重试'
    ['centos']='不支持当前版本，请切换到 CentOS 7+ 重试'
    ['tip']='更新提示'
    ['new']='发现有新脚本, 是否更新'
    ['now']='是否更新 [Y/n] '
    ['promptly']='请及时更新脚本'
    ['completed']='更新完成'
    ['download']='正在下载'
    ['failed']='下载失败'
    ['downloaded']='文件已下载到'
)                        # 默认的国际化数据 (中文)
declare PROJECT_ROOT=''  # 项目安装根目录 (动态设置)
declare I18N_DIR=''      # 国际化文件目录 (动态设置)
declare CORE_DIR=''      # 核心脚本目录 (动态设置)
declare SERVICE_DIR=''   # 服务配置目录 (动态设置)
declare CONFIG_DIR=''    # 配置文件目录 (动态设置)
declare TOOL_DIR=''      # 工具脚本目录 (动态设置)
declare QUICK_INSTALL='' # 存储快速安装选项 (如 --vision, --xhttp)
declare SCRIPT_CONFIG='' # 存储脚本配置内容
declare LANG_PARAM=''    # 存储命令行指定的语言参数
declare FORCE_CHECK_DEPS=0 # 是否强制检查/安装依赖 (0/1)
declare -a ORIGINAL_ARGS=() # 保存原始启动参数，用于自动更新后重启传递

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
# 函数名称: parse_args
# 功能描述: 解析命令行参数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (直接修改全局变量 QUICK_INSTALL, PROJECT_ROOT, LANG_PARAM)
# =============================================================================
function parse_args() {
    # 遍历所有命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
        # 如果参数是语言设置
        --lang=*)
            LANG_PARAM="${1}"
            ;;
        --check-deps)
            FORCE_CHECK_DEPS=1
            ;;
        esac
        shift # 移动到下一个参数
    done
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
# 参数: 无
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# =============================================================================
function load_i18n() {
    local lang="${LANG_PARAM#*=}" # 从 LANG_PARAM 中提取语言代码

    # 如果存在脚本配置文件，则尝试从文件中获取语言代码
    if [[ -z "${lang}" && -f "${SCRIPT_CONFIG_PATH}" ]]; then
        # 尝试从脚本配置文件中获取语言代码
        if cmd_exists "jq"; then
            lang="$(jq -r '.language // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
        fi
    fi

    # 如果语言设置为 "auto"，则提取系统环境变量 LANG 的语言代码，C/POSIX 回退至 en
    if [[ "$lang" == "auto" ]]; then
        lang="${LANG%%_*}"
        lang="${lang%%.*}"
        case "${lang}" in
        "" | C | POSIX) lang="en" ;;
        esac
    fi

    # 如果语言设置为 "en"，则加载英文提示信息
    if [[ "$lang" == "en" ]]; then
        I18N_DATA=(
            ['error']='Error'
            ['root']='This script must be run as root'
            ['supported']='Not supported OS'
            ['ubuntu']='Not supported OS, please change to Ubuntu 18+ and try again.'
            ['debian']='Not supported OS, please change to Debian 9+ and try again.'
            ['centos']='Not supported OS, please change to CentOS 7+ and try again.'
            ['tip']='Update Notice'
            ['new']='A new version of the script is available. Do you want to update?'
            ['now']='Update now? [Y/n]'
            ['promptly']='Please update the script promptly.'
            ['completed']='Update completed'
            ['download']='Downloading'
            ['failed']='Download failed'
            ['downloaded']='The file has been downloaded to'
        )
    fi
}

# =============================================================================
# 函数名称: _error
# 功能描述: 以红色打印错误信息并退出脚本。
# 参数:
#   $@: 错误消息内容
# 返回值: 无 (直接打印到标准错误输出 >&2，然后 exit 1)
# =============================================================================
function _error() {
    # 用红色打印错误标题和消息到标准错误输出
    printf '%b[%s]%b %s\n' "${RED}" "${I18N_DATA['error']}" "${NC}" "$*" >&2
    # 退出脚本，错误码为 1
    exit 1
}

function persist_script_config() {
    [[ -n "${SCRIPT_CONFIG}" ]] || _error "Refusing to write empty config"
    printf '%s\n' "${SCRIPT_CONFIG}" | jq -e '.' >/dev/null 2>&1 || _error "Refusing to write invalid JSON config"
    local tmp_file="${SCRIPT_CONFIG_PATH}.tmp.$$"
    printf '%s\n' "${SCRIPT_CONFIG}" >"${tmp_file}" && mv -f "${tmp_file}" "${SCRIPT_CONFIG_PATH}" && sleep 1
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# 参数: 无
# 返回值: 无 (如果不支持则调用 _error 退出)
# =============================================================================
function check_os() {
    local os_ver="$(_os_ver)"
    # 检查操作系统类型和版本
    case "$(_os)" in
    # CentOS 系列
    centos)
        # 检查版本号是否大于等于 7
        if [[ "${os_ver}" =~ ^[0-9]+$ ]] && ((10#${os_ver} < 7)); then
            _error "${I18N_DATA['centos']}"
        fi
        ;;
    # Ubuntu 系列
    ubuntu)
        # 检查版本号是否大于等于 16
        if [[ "${os_ver}" =~ ^[0-9]+$ ]] && ((10#${os_ver} < 16)); then
            _error "${I18N_DATA['ubuntu']}"
        fi
        ;;
    # Debian 系列
    debian)
        # 检查版本号是否大于等于 9
        if [[ "${os_ver}" =~ ^[0-9]+$ ]] && ((10#${os_ver} < 9)); then
            _error "${I18N_DATA['debian']}"
        fi
        ;;
    # 其他不支持的操作系统
    *)
        _error "${I18N_DATA['supported']}"
        ;;
    esac
}

# =============================================================================
# 函数名称: check_dependencies
# 功能描述: 检查必要的依赖软件是否已安装。
# 参数: 无
# 返回值: 0-所有依赖都已安装 1-有依赖缺失 (由命令检查结果决定)
# =============================================================================
function check_dependencies() {
    # 定义基础必需的软件包列表
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")
    local missing_packages=() # 声明数组存储缺失的包

    # 根据操作系统类型检查特定的软件包
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    debian | ubuntu)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    esac

    # 如果缺失包列表为空，则返回 0 (成功)
    [[ ${#missing_packages[@]} -eq 0 ]]
}

# =============================================================================
# 函数名称: install_dependencies
# 功能描述: 根据操作系统类型安装必要的依赖包。
# 参数: 无
# 返回值: 无 (执行包管理器命令安装软件)
# =============================================================================
function install_dependencies() {
    # 定义基础必需的软件包列表
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")

    # 根据操作系统类型添加特定的软件包并执行安装
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 检查是否使用 dnf 包管理器 (较新版本)
        if cmd_exists "dnf"; then
            # 安装 EPEL 与插件仓库（qrencode/jq 等包依赖 EPEL）
            dnf install -y epel-release dnf-plugins-core || true
            local -a missing_pkgs=()
            for pkg in "${packages[@]}"; do
                rpm -q "$pkg" &>/dev/null || missing_pkgs+=("$pkg")
            done
            if ((${#missing_pkgs[@]} > 0)); then
                dnf install -y "${missing_pkgs[@]}" || for pkg in "${missing_pkgs[@]}"; do dnf install -y "${pkg}"; done
            fi
        else
            # 使用 yum 包管理器 (较旧版本)
            yum install -y epel-release yum-utils || true
            local -a missing_pkgs=()
            for pkg in "${packages[@]}"; do
                rpm -q "$pkg" &>/dev/null || missing_pkgs+=("$pkg")
            done
            if ((${#missing_pkgs[@]} > 0)); then
                yum install -y "${missing_pkgs[@]}" || for pkg in "${missing_pkgs[@]}"; do yum install -y "${pkg}"; done
            fi
        fi
        ;;
    ubuntu | debian)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        local -a missing_pkgs=()
        for pkg in "${packages[@]}"; do
            if ! dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
                missing_pkgs+=("$pkg")
            fi
        done
        if ((${#missing_pkgs[@]} > 0)); then
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_pkgs[@]}" || for pkg in "${missing_pkgs[@]}"; do
                DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
            done
        fi
        ;;
    esac
}

# =============================================================================
# 函数名称: download_github_files
# 功能描述: 从 GitHub API 下载指定目录的文件。
# 参数:
#   $1: 本地目标目录
#   $2: GitHub API 项目 URL
# 返回值: 无 (执行文件下载和解压过程)
# =============================================================================
function download_github_files() {
    local target_dir="$1"     # 本地目标目录
    local github_api_url="$2" # GitHub API 项目 URL
    local tmp_tar=""

    # 创建目标目录与临时归档文件
    mkdir -p "${target_dir}"
    tmp_tar="$(mktemp -t xray-script.XXXXXX.tar.gz)" || _error "${I18N_DATA['failed']}: mktemp"

    # 打印开始下载的信息
    echo -e "${GREEN}[${I18N_DATA['download']}]${NC} ${github_api_url}" >&2
    # 先完整下载到临时文件再解压，避免半截解压污染目录且不改变脚本工作目录
    if ! curl -fsSL --connect-timeout 15 --max-time 120 -o "${tmp_tar}" "${github_api_url}"; then
        rm -f "${tmp_tar}"
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
    if ! tar -xzf "${tmp_tar}" --strip-components=1 -C "${target_dir}"; then
        rm -f "${tmp_tar}"
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
    rm -f "${tmp_tar}"
    chmod +x "${target_dir}/install.sh" "${target_dir}/core/"*.sh "${target_dir}/service/"*.sh "${target_dir}/tool/"*.sh 2>/dev/null || true
}

# =============================================================================
# 函数名称: download_xray_script_files
# 功能描述: 下载 Xray-script 项目的全部文件。
# 参数:
#   $1: 本地目标根目录
# 返回值: 无 (调用 download_github_files 下载项目)
# =============================================================================
function download_xray_script_files() {
    local target_dir="$1" # 本地目标根目录
    # 定义 GitHub API 项目 URL
    local script_github_api="https://api.github.com/repos/gitbruc/Xray-ng-script/tarball/main"

    # 调用 download_github_files 下载项目
    download_github_files "${target_dir}" "${script_github_api}"
}

# =============================================================================
# 函数名称: check_xray_script_version
# 功能描述: 检查本地安装的 Xray-script 版本与 GitHub 上的最新版本是否一致。
#           如果不一致，则提示用户。
# 参数: 无 (直接使用全局变量 PROJECT_ROOT)
# 返回值: 无 (打印版本检查信息到标准输出)
# =============================================================================
function check_xray_script_version() {
    # 定义 GitHub URL 和本地版本文件路径
    local script_config_github_url="https://raw.githubusercontent.com/gitbruc/Xray-ng-script/main/config.json"
    local is_update='n' # 初始化更新标志为 'n' (不更新)

    # 读取本地版本号
    local local_version="$(jq -r '.version // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    # 从 GitHub 获取远程版本号（带超时限制，网络异常时直接跳过避免误报更新）
    local remote_version="$(curl -fsSL --connect-timeout 10 --max-time 20 "$script_config_github_url" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
    [[ -n "${remote_version}" && "${remote_version}" != "null" ]] || return 0

    # 比较本地和远程版本号
    if [[ "${local_version}" != "${remote_version}" ]]; then
        # 如果不一致，则提示用户有新版本
        echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['new']} (${local_version} -> ${remote_version})"
        # 询问用户是否更新
        read -rp "${I18N_DATA['now']}" -e -i "Y" is_update || is_update='n'

        # 根据用户选择决定是否更新
        case "${is_update,,}" in # ${is_update,,} 转换为小写
        y | yes)
            # 如果用户选择更新
            cd "${HOME}" || true
            # 清理并重建干净的临时目录
            local temp_dir="${SCRIPT_CONFIG_DIR}/xray-script-temp"
            rm -rf "${temp_dir}"
            mkdir -vp "${temp_dir}"
            # 下载最新文件到临时目录
            download_xray_script_files "${temp_dir}"
            # 删除旧的项目目录并原子替换
            rm -rf "${PROJECT_ROOT}"
            mv -f "${temp_dir}" "${PROJECT_ROOT}"
            # 若引导脚本位于项目目录之外且为真实 .sh 文件，同步更新该引导脚本（避免同路径自删）
            local restart_script="${PROJECT_ROOT}/install.sh"
            if [[ -f "${CUR_DIR}/${CUR_FILE}" && "${CUR_FILE}" == *.sh && "${CUR_DIR}/${CUR_FILE}" != "${PROJECT_ROOT}/install.sh" ]]; then
                cp -f "${PROJECT_ROOT}/install.sh" "${CUR_DIR}/${CUR_FILE}"
                chmod +x "${CUR_DIR}/${CUR_FILE}"
                restart_script="${CUR_DIR}/${CUR_FILE}"
            fi
            # 使用 jq 原子更新配置文件中的版本号
            SCRIPT_CONFIG="$(jq --arg v "${remote_version}" '.version = $v' "${SCRIPT_CONFIG_PATH}")"
            persist_script_config
            # 打印更新完成信息
            echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['completed']}"
            # 携带原始参数重启脚本
            exec bash "${restart_script}" "${ORIGINAL_ARGS[@]}"
            ;;
        *)
            # 如果用户选择不更新，则提示及时更新
            echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}"
            ;;
        esac
    fi
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 解析命令行参数。
#           2. 加载国际化数据。
#           3. 检查 root 权限。
#           4. 检查操作系统。
#           5. 检查并安装依赖。
#           6. 处理项目目录和配置。
#           7. 启动主脚本。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成整个安装流程)
# =============================================================================
function main() {
    ORIGINAL_ARGS=("$@")
    # 解析命令行参数
    parse_args "$@"
    # 加载国际化数据
    load_i18n

    # 检查是否以 root 权限运行
    [[ $EUID -ne 0 ]] && _error "${I18N_DATA['root']}"

    # 检查操作系统
    check_os

    local is_first_run=0
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        is_first_run=1
    fi

    # 仅首次运行或显式强制时检查/安装依赖
    if [[ "${is_first_run}" -eq 1 || "${FORCE_CHECK_DEPS}" -eq 1 ]]; then
        if ! check_dependencies; then
            install_dependencies
        fi
        if ! check_dependencies; then
            install_dependencies
        fi
        if ! cmd_exists 'curl' || ! cmd_exists 'jq' || ! cmd_exists 'tar'; then
            _error "Required dependencies (curl/jq/tar) are still missing after installation"
        fi
    fi

    # 检查脚本配置目录和配置文件是否存在，如果不存在则原子下载并校验默认配置
    mkdir -p "${SCRIPT_CONFIG_DIR}"
    if [[ ! -s "${SCRIPT_CONFIG_PATH}" ]]; then
        local config_url="https://raw.githubusercontent.com/gitbruc/Xray-ng-script/main/config.json"
        local tmp_cfg="${SCRIPT_CONFIG_PATH}.tmp.$$"
        if ! curl -fsSL --connect-timeout 15 --max-time 30 -o "${tmp_cfg}" "${config_url}" || ! jq -e '.' "${tmp_cfg}" >/dev/null 2>&1; then
            rm -f "${tmp_cfg}"
            _error "${I18N_DATA['failed']}: ${config_url}"
        fi
        mv -f "${tmp_cfg}" "${SCRIPT_CONFIG_PATH}"
    fi

    # 处理命令行参数中的快速安装和自定义目录选项
    while [[ $# -gt 0 ]]; do
        case "$1" in
        # 快速安装选项
        --vision | --xhttp | --fallback)
            QUICK_INSTALL="${1}"
            ;;
        # 自定义安装目录选项
        -d)
            [[ $# -ge 2 && -n "$2" ]] || _error "Missing directory path after -d"
            shift
            PROJECT_ROOT="${1}"
            ;;
        esac
        shift
    done

    # 从脚本配置文件中读取已记录的安装路径
    local script_path="$(jq -r '.path // empty' "${SCRIPT_CONFIG_PATH}")"
    # 如果配置文件中没有记录路径，且命令行也未指定，则使用默认路径
    if [[ -z "${script_path}" && -z "${PROJECT_ROOT}" ]]; then
        PROJECT_ROOT='/usr/local/xray-script' # 设置默认项目根目录
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        persist_script_config
    # 如果配置文件中已有记录的路径，则使用该路径
    elif [[ -n "${script_path}" ]]; then
        PROJECT_ROOT="${script_path}"
    # 如果配置文件中没有路径，但命令行指定了路径，则使用命令行指定的路径并更新配置文件
    elif [[ -n "${PROJECT_ROOT}" ]]; then
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")"
        persist_script_config
    fi

    # 设置各个子目录的路径
    I18N_DIR="${PROJECT_ROOT}/i18n"
    CORE_DIR="${PROJECT_ROOT}/core"
    SERVICE_DIR="${PROJECT_ROOT}/service"
    CONFIG_DIR="${PROJECT_ROOT}/config"
    TOOL_DIR="${PROJECT_ROOT}/tool"

    # 检查项目根目录是否存在
    if [[ -d "${PROJECT_ROOT}" ]]; then
        # 如果存在，则检查版本更新
        check_xray_script_version
    else
        # 如果不存在，则下载项目文件
        download_xray_script_files "${PROJECT_ROOT}"
    fi

    # 检查配置文件中的语言设置
    local lang="$(jq -r '.language // empty' "${SCRIPT_CONFIG_PATH}")"
    if [[ -z "${lang}" && -z "${LANG_PARAM}" ]]; then
        # 如果语言未设置且未通过命令行指定，则运行菜单脚本选择语言
        bash "${CORE_DIR}/menu.sh" '--language'
        case $? in
        130) exit 130 ;;     # Ctrl+C 取消
        2) LANG_PARAM="en" ;; # 选择英文
        *) LANG_PARAM="zh" ;; # 默认中文
        esac
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        persist_script_config
    elif [[ "${LANG_PARAM}" =~ ^--lang= ]]; then
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM#*=}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
        persist_script_config
    fi

    # 启动主脚本，并传递快速安装选项
    if [[ -n "${QUICK_INSTALL}" ]]; then
        bash "${CORE_DIR}/main.sh" "${QUICK_INSTALL}"
    else
        bash "${CORE_DIR}/main.sh"
    fi
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
