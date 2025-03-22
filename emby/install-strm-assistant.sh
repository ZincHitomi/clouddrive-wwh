#!/bin/bash

# 设置脚本执行时的错误处理
set -e

# 定义全局变量
GITHUB_OWNER="sjtuross"
GITHUB_REPO="StrmAssistant"
GITHUB_REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}"
PLUGIN_NAME="StrmAssistant.dll"
SAMPLE_PLUGIN="Emby.Webhooks.dll"
VERSION="latest"
RUN_URL=""
CONTAINER=""
LOCATION=""
RESTART=false
IS_DOCKER=false
GH_PROXY=""

GITHUB_TOKEN=${GITHUB_TOKEN:-""}

TEMP_FILE=""
UPDATED=false

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志记录函数
log() {
  local level="$1"
  shift
  local message="$@"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  case "$level" in
    INFO)
      echo -e "[$timestamp] [${GREEN}$level${NC}] $message"
      ;;
    WARN)
      echo -e "[$timestamp] [${YELLOW}$level${NC}] $message"
      ;;
    ERROR)
      echo -e "[$timestamp] [${RED}$level${NC}] $message"
      ;;
    *)
      echo -e "[$timestamp] [$level] $message"
      ;;
  esac
}

# 显示使用说明
show_usage() {
  echo "功能: 安装或更新 Emby 中的 StrmAssistant(又名 神医助手) 插件"
  echo
  echo "用法: $0 [选项]"
  echo "选项:"
  echo "  -v, --version VERSION       指定插件版本号（默认: latest）"
  echo "  -r, --run URL               指定Github Actions run链接"
  echo "  -tk, --token TOKEN          使用run链接时，需提供GitHub Token，必须具备 workflow 权限"
  echo "  -c, --container NAME        指定 Docker 容器名称。如果目标Emby是Docker容器，但不确定容器名称，可以指定 --docker 选项，省略此选项"
  echo "  -d, --docker                指定 Emby 部署方式为 Docker，如果指定了 --container 选项，可省略此选项，如未指定 --container 选项，脚本将会尽量自动获取容器和插件路径"
  echo "  -l, --location PATH         指定插件目录路径，如果是Docker版，一般可以省略，因为可以自动检测"
  echo "  -r, --restart               更新后重启 Docker 容器"
  echo "  -gp, --ghproxy              使用ghproxy代理加速下载，地址为https://mirror.ghproxy.com"
  echo "  -gph, --ghproxy-host URL    使用自定义ghproxy代理加速下载。如https://gh.myhost.io"
  echo "  -h, --help                  显示此帮助信息"
  echo
  echo "示例 - 更新容器插件: $0 -d"
  echo "示例 - 更新指定容器插件: $0 -c emby"
  echo "示例 - 更新插件到指定目录(这种方式兼容Docker版和本地版): $0 -l /var/packages/EmbyServer/var/plugins"
  echo "示例 - 指定版本、指定是Docker版但不指定容器名、更新后重启容器: $0 -v 1.0.0 -d -r"
  echo "示例 - 指定ghproxy加速下载: $0 -d -gp"
  echo "示例 - 指定自定义ghproxy域名加速下载: $0 -d -gph https://gh.myhost.io"
  echo
  echo "StrmAssistant Github: ${GITHUB_REPO_URL}"
  echo
  echo "脚本作者: 生瓜太保"
  echo "更新时间: 2025-03-22"
}

# 解析命令行参数
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -v | --version)
      VERSION="$2"
      shift 2
      ;;
    -r | --run)
      RUN_URL="$2"
      # https://github.com/sjtuross/StrmAssistant/actions/runs/14007790472
      if [[ ! "$RUN_URL" =~ ^https://github\.com/.+/actions/runs/[0-9]+$ ]]; then
        log "ERROR" "错误: 无效的 Github Actions run 链接。"
        exit 1
      fi
      shift 2
      ;;
    -tk | --token)
      GITHUB_TOKEN="$2"
      if [[ -z "$GITHUB_TOKEN" ]]; then
        log "ERROR" "错误: GitHub Token 不能为空。"
        exit 1
      fi
      shift 2
      ;;
    -c | --container)
      CONTAINER="$2"
      IS_DOCKER=true
      shift 2
      ;;
    -d | --docker)
      IS_DOCKER=true
      shift
      ;;
    -l | --location)
      LOCATION="$2"
      shift 2
      ;;
    -r | --restart)
      RESTART=true
      shift
      ;;
    -gp | --ghproxy)
      GH_PROXY="https://mirror.ghproxy.com"
      shift
      ;;
    -gph | --ghproxy-host)
      GH_PROXY="$2"
      shift 2
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    *)
      log "ERROR" "错误: 未知选项 $1"
      show_usage
      exit 1
      ;;
    esac
  done
}

# 检查必要的命令是否存在
check_dependencies() {
  # 如果是docker版，才检查docker命令
  if [[ $IS_DOCKER == true ]]; then
    local cmds=("curl" "jq" "docker")
  else
    local cmds=("curl" "jq")
  fi
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log "ERROR" "错误: 未找到命令 '$cmd'。请确保已安装。"
      exit 1
    fi
  done

  # 如果指定了 RUN_URL，需要确保有可以解压的命令（unzip 或 7z）和 jq
  if [[ -n "$RUN_URL" ]]; then
    if ! command -v unzip &>/dev/null && ! command -v 7z &>/dev/null; then
      log "ERROR" "错误: 未找到解压命令 'unzip' 或 '7z'。请确保已安装。"
      exit 1
    fi

    if ! command -v jq &>/dev/null; then
      log "ERROR" "错误: 未找到命令 'jq'。请确保已安装。"
      exit 1
    fi
  fi
}

# 获取文件权限
get_permission() {
  # 某些系统默认没有`stat`命令，如OpenWrt
  if ! command -v stat &>/dev/null; then
    return 1
  fi

  # macOS
  if [[ $(uname) == "Darwin" ]]; then
    echo $(stat -f "%Lp" "$1")
    return
  fi

  # linux
  echo $(stat -c "%a" "$1")
}

# 获取文件所有者和所属组
get_user_group() {
  # 某些系统默认没有`stat`命令，如OpenWrt
  if ! command -v stat &>/dev/null; then
    return 1
  fi

  # macOS
  if [[ $(uname) == "Darwin" ]]; then
    echo $(stat -f "%Su:%Sg" "$1")
    return
  fi

  # linux
  echo $(stat -c "%U:%G" "$1")
}

# 获取 Emby Docker 容器
get_emby_container() {
  local containers
  # 不使用`ancestor`筛选，兼容一些特殊情况
  # containers=$(docker ps --format '{{.Names}}' --filter ancestor=emby/embyserver)
  containers=$(docker ps -a --format '{{.Names}} {{.Image}}' | grep -i emby)

  if [[ -z "$containers" ]]; then
  log "ERROR" "错误: 未找到名称或所用镜像包含「emby」容器。"
    exit 1
  fi

  if [[ $(echo "$containers" | wc -l) -eq 1 ]]; then
    CONTAINER=$containers
  else
    echo "找到多个疑似 Emby 容器，请输入数字选择(如果没有，请按 Ctrl+C 结束脚本，然后指定参数「-c 容器名称」运行): "
    IFS=$'\n'
    select container in $containers; do
      if [[ -n "$container" ]]; then
        CONTAINER=$(echo "$container" | cut -d ' ' -f 1)
        break
      fi
    done
    unset IFS  # 恢复默认IFS
  fi

    log "INFO" "选择的 Emby 容器: $CONTAINER"
}

# 获取容器插件目录的在宿主机上的绝对路径
get_container_plugin_dir() {
  LOCATION=$(docker inspect "$CONTAINER" | jq -r '.[0].Mounts[] | select(.Destination == "/config") | .Source')
  if [[ -z "$LOCATION" ]]; then
  log "ERROR" "错误: 无法找到容器的 /config 挂载点。"
    exit 1
  fi
  LOCATION="$LOCATION/plugins"

  log "INFO" "插件目录: $LOCATION"
}

# 下载插件
download_plugin() {
  local download_url
  local temp_file

  if [[ -n "$GH_PROXY" ]]; then
    GH_PROXY="${GH_PROXY%/}/"
  fi

  if [[ "$VERSION" == "latest" ]]; then
    download_url=$(curl -s -L "https://api.github.com/repos/sjtuross/StrmAssistant/releases/latest" | jq -r '.assets[] | select(.name == "StrmAssistant.dll") | .browser_download_url')
    download_url="${GH_PROXY}${download_url}"
  else
    # 确保版本号前面有`v`
    if [[ "${VERSION:0:1}" != "v" ]]; then
      VERSION="v$VERSION"
    fi
    download_url="${GH_PROXY}https://github.com/sjtuross/StrmAssistant/releases/download/$VERSION/StrmAssistant.dll"
  fi

  if [[ -z "$download_url" ]]; then
    log "ERROR" "错误: 无法获取下载 URL。"
    exit 1
  fi

  log "INFO" "下载 URL: $download_url"

  temp_file=$(mktemp)
  if curl -L "$download_url" -o "$temp_file"; then
    log "INFO" "插件下载成功。"
  else
    log "ERROR" "错误: 插件下载失败。"
    rm -f "$temp_file"
    exit 1
  fi

  TEMP_FILE="$temp_file"
}

# 根据运行链接获取 Artifact 下载链接
# 参数: 运行链接 (示例: https://github.com/sjtuross/StrmAssistant/actions/runs/123)
# 返回: Artifact 下载链接 (示例: https://api.github.com/repos/sjtuross/StrmAssistant/actions/artifacts/123/zip)
get_artifact_url_via_run() {
  local run_url=$1
  local artifact_url

  if [[ -z "$run_url" ]]; then
    log "ERROR" "错误: 未指定 Github Actions 运行链接。"
    exit 1
  fi

  # 提取运行 ID
  local run_id
  run_id=$(echo "$run_url" | sed -E 's|.*/([0-9]+)/?.*|\1|')
  if [[ -z "$run_id" ]]; then
    log "ERROR" "错误: 无法提取运行 ID。"
    exit 1
  fi
  # log "INFO" "提取到运行 ID: $run_id"

  # 获取 Artifact 下载链接
  artifact_url=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$GITHUB_API_URL/actions/runs/$run_id/artifacts" | jq -r '.artifacts[0].archive_download_url')
  if [[ -z "$artifact_url" ]]; then
    log "ERROR" "错误: 无法获取 Artifact 下载链接。"
    exit 1
  fi
  
  echo "$artifact_url"
}

# 解压zip文件。尝试 unzip 和 7z 命令
unzip_file() {
  local zip_file=$1
  local target_dir=$2
  
  # 尝试使用 unzip 命令解压
  if command -v unzip &>/dev/null; then
    unzip -q "$zip_file" -d "$target_dir"
    if [[ $? -ne 0 ]]; then
      log "ERROR" "错误: unzip 解压失败。"
      return 1
    fi
  fi

  # 如果 unzip 失败，尝试使用 7z 命令解压
  if command -v 7z &>/dev/null; then
    7z x "$zip_file" -o"$target_dir" -y
    if [[ $? -ne 0 ]]; then
      log "ERROR" "错误: 7z 解压失败。"
      return 1
    fi
  fi

  # 如果 unzip 和 7z 都不可用，提示错误
  if ! command -v unzip &>/dev/null && ! command -v 7z &>/dev/null; then
    log "ERROR" "错误: unzip 和 7z 都不可用，无法解压 zip 文件。"
    return 1
  fi
}

# 下载插件（通过Artifact链接)
download_artifact() {
  local run_url=$1
  local temp_file

  if [[ -z "$run_url" ]]; then
    log "ERROR" "错误: 未指定 Artifact 下载链接。"
    exit 1
  fi

  # 如果没有提供 Github Token，提示错误
  if [[ -z "$GITHUB_TOKEN" ]]; then
    log "ERROR" "错误: 需要提供 GitHub Token。请设置环境变量 GITHUB_TOKEN。"
    exit 1
  fi

  local artifact_url=$(get_artifact_url_via_run "$run_url")
  if [[ -z "$artifact_url" ]]; then
    log "ERROR" "错误: 无法获取 Artifact 下载链接。"
    exit 1
  fi

  log "INFO" "Artifact 下载链接: $artifact_url"

  temp_dir=$(mktemp -d)
  temp_zip="$temp_dir/artifact.zip"

  # curl -L \
  #   -H "Accept: application/vnd.github+json" \
  #   -H "Authorization: Bearer xxxx" \
  #   -H "X-GitHub-Api-Version: 2022-11-28" \
  #   https://api.github.com/repos/sjtuross/StrmAssistant/actions/artifacts/123/zip
  #   https://github.com/sjtuross/StrmAssistant/actions/runs/123
  
  if curl -H "Authorization: Bearer $GITHUB_TOKEN" -H "X-GitHub-Api-Version: 2022-11-28" -L "$artifact_url" -o "$temp_zip"; then
    log "INFO" "Artifact 下载成功。"

    ls -hl "$temp_zip"
    
    # 解压 zip 文件
    if unzip_file "$temp_zip" "$temp_dir"; then
      log "INFO" "Artifact 解压成功。"
      
      # 查找 StrmAssistant.dll 文件
      dll_file=$(find "$temp_dir" -name "$PLUGIN_NAME" -type f)
      
      if [[ -n "$dll_file" ]]; then
        log "INFO" "找到 $PLUGIN_NAME 文件。"
        temp_file=$(mktemp)
        cp "$dll_file" "$temp_file"
        TEMP_FILE="$temp_file"
      else
        log "ERROR" "错误: 在解压后的文件中未找到 $PLUGIN_NAME。"
        rm -rf "$temp_dir"
        exit 1
      fi
    else
      log "ERROR" "错误: Artifact 解压失败。"
      rm -rf "$temp_dir"
      exit 1
    fi
  else
    log "ERROR" "错误: Artifact 下载失败。"
    rm -rf "$temp_dir"
    exit 1
  fi
  
  # 清理临时目录
  rm -rf "$temp_dir"
}


# 设置权限(参数: 目标文件 示例文件)
set_permission() {
  local target_file=$1
  local sample_file=$2
  local permission="644"
  
  local current_user_group=$(get_user_group "$target_file")
  local target_user_group=""

  if [[ -f "$sample_file" ]]; then
    permission=$(get_permission "$sample_file")
    if [[ -z "$permission" ]]; then
      log "WARN" "警告: 无法获取示例文件 "${sample_file}" 的权限，将使用默认权限: $permission"
    else
      log "INFO" "获取到示例文件 "${sample_file}" 的权限为 $permission"
    fi

    target_user_group=$(get_user_group "$sample_file")
    if [[ -z "$target_user_group" ]]; then
      log "WARN" "警告: 无法获取示例文件 "${sample_file}" 的所有者和所属组，将使用当前用户和组"
    else
      log "INFO" "获取到示例文件 "${sample_file}" 的所有者和所属组为 $target_user_group"
    fi
  else
    log "WARN" "警告: 示例文件 "${sample_file}" 不存在，将使用默认权限: $permission"
  fi

  # 临时关闭错误处理
  set +e

  chmod "$permission" "$target_file"
  if [[ $? -ne 0 ]]; then
    log "WARN" "警告: 无法设置 ${target_file} 权限为 $permission，尝试使用 sudo 设置"
    sudo chmod "$permission" "$target_file"
    if [[ $? -ne 0 ]]; then
      log "ERROR" "错误: 无法设置 ${target_file} 权限为 $permission"
    else
      log "INFO" "已设置 ${target_file} 权限为 $permission"
    fi
  else
    log "INFO" "已设置 ${target_file} 权限为 $permission"
  fi

  if [[ -n "$target_user_group" && "$current_user_group" != "$target_user_group" ]]; then
    chown "$target_user_group" "$target_file"
    if [[ $? -ne 0 ]]; then
      log "WARN" "警告: 无法设置 ${target_file} 的所有者和所属组为 $permission，尝试使用 sudo 设置"
      sudo chown "$target_user_group" "$target_file"
      if [[ $? -ne 0 ]]; then
        log "ERROR" "错误: 无法设置 ${target_file} 的所有者和所属组为 $target_user_group"
      else
        log "INFO" "已设置 ${target_file} 的所有者和所属组为 $target_user_group"
      fi
    else
      log "INFO" "已设置 ${target_file} 的所有者和所属组为 $target_user_group"
    fi
  fi

  # 重新开启错误处理
  set -e
}

# 更新插件
update_plugin() {
  local temp_file=$1
  local target_file="$LOCATION/$PLUGIN_NAME"

  # sha1sum "$temp_file"
  # [[ -f "$target_file" ]] && sha1sum "$target_file"

  if [[ -f "$target_file" ]]; then
    if cmp -s "$temp_file" "$target_file"; then
      log "INFO" "插件文件未发生变化，无需更新。"
      rm -f "$temp_file"
      return
    fi
  fi

  mv -f "$temp_file" "$target_file"

  set_permission "$target_file" "$LOCATION/$SAMPLE_PLUGIN"

  log "INFO" "插件更新成功。"

  UPDATED=true
}

# 重启 Docker 容器
restart_container() {
  if [[ $UPDATED == false ]]; then
    return 0
  fi

  if [[ -n "$CONTAINER" ]]; then
    if [[ $RESTART == true ]]; then
      log "INFO" "重启 Emby 容器..."
      docker restart "$CONTAINER"
      log "INFO" "Emby 容器已重启。"
    else
      read -p "是否要重启 Emby 容器？(y/N) " answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        log "INFO" "重启 Emby 容器..."
        docker restart "$CONTAINER"
        log "INFO" "Emby 容器已重启。"
      fi
    fi
  fi
}

# 函数: 询问插件目录路径
prompt_plugin_dir() {
  read -p "请输入插件目录路径: " LOCATION

  while [[ -z "$LOCATION" ]]; do
    read -p "请输入插件目录路径: " LOCATION
  done

  while [[ ! -d "$LOCATION" ]]; do
    read -p "插件目录路径不存在，请重新输入: " LOCATION
  done
}

# 主函数
main() {
  parse_arguments "$@"

  check_dependencies

  # 如果指定是docker版，但没有指定容器名称，则自动获取
  if [[ $IS_DOCKER == true && -z "$CONTAINER" ]]; then
    get_emby_container
  fi

  # 如果不是Docker版，且没有指定插件目录路径，则询问输入
  if [[ $IS_DOCKER == false && -z "$LOCATION" ]]; then
    prompt_plugin_dir
  fi

  # 如果指定是docker版，但没有指定插件目录路径，则自动获取
  if [[ $IS_DOCKER == true && -z "$LOCATION" ]]; then
    get_container_plugin_dir
  fi

  # 下载插件
  if [[ -n "$RUN_URL" ]]; then
    download_artifact "$RUN_URL"
  else
    download_plugin
  fi

  update_plugin "$TEMP_FILE"

  restart_container

  log "INFO" "插件更新完成。"
}

# 执行主函数
main "$@"
