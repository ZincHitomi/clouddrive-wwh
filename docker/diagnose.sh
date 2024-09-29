#!/bin/bash

SCRIPT_NAME=$0
if [[ "$SCRIPT_NAME" != *.sh ]]; then
  SCRIPT_NAME="diagnose.sh"
fi

# 设置颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数：打印普通日志
print_log() {
  echo -e "${GREEN}⚪ $1${NC}"
}

# 函数：打印错误信息
print_error() {
  echo -e "${RED}❌ $1${NC}"
}

# 函数：打印警告信息
print_warning() {
  echo -e "${YELLOW}❗ $1${NC}"
}

# 函数：打印成功信息
print_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

# 函数：打印建议
print_advice() {
  echo -e "${BLUE}💡 修复建议: $1${NC}"
}

# 函数：检查命令是否存在
check_command() {
  if ! command -v $1 &>/dev/null; then
    print_error "$1 命令未找到。请确保已安装该命令。"
    exit 1
  fi
}

# ==========end none-biz utils==========

CONTAINER=""
MOUNT_POINTS=()

STATUS_OK=true
PID_OK=true
VOLUMES_OK=true
TIMEZONE_OK=true

# 有些系统可能没有sudo命令
SUDO_CMD="sudo"
if ! command -v sudo &>/dev/null; then
  SUDO_CMD=""
fi

# 函数: 获取系统挂载点列表
get_mount_points() {
  echo "⏳ 正在获取系统挂载点列表..."

  # 清空数组,以防函数被多次调用
  MOUNT_POINTS=()

  while read line; do
    fileSystem=$(echo $line | awk '{print $1}')
    mount_point=$(echo $line | awk '{print $6}')

    # 排除一些文件系统
    if [[ $fileSystem != *"CloudFS"* ]]; then
      MOUNT_POINTS+=("$mount_point")
    fi
  done < <(df -h | tail -n +2)

  print_success "获取系统挂载点列表成功\n"
}

# 函数: 获取Docker数据目录
get_docker_root_dir() {
  echo $(docker info -f '{{.DockerRootDir}}')
}

# 函数: 获取Docker数据目录所在的挂载点
get_docker_root_dir_mount_point() {
  echo $(get_mount_point $(get_docker_root_dir))
}

# 函数: 获取映射关系中的宿主机路径对应的挂载点
compute_mount_point() {
  local target_mount_point="/"

  local former_path=$1

  while true; do
    for i in ${!MOUNT_POINTS[@]}; do
      mp=${MOUNT_POINTS[$i]}
      if [[ $former_path == "$mp" ]]; then
        target_mount_point=$mp
        break 2
      fi
    done

    former_path=$(dirname $former_path)

    if [[ $former_path == "/" ]]; then
      break
    fi
  done

  echo $target_mount_point
}

# 函数: 获取挂载点的共享挂载类型
compute_shared_type() {
  local the_path="$1"
  local mount_point=$(get_mount_point "$the_path")
  if [[ -z "$mount_point" ]]; then
    echo ""
    return
  fi

  # 如果等于Docker数据目录所在的挂载点，则返回"rshared"
  # 只有当路径完全等于挂载点时，才需要"rshared/rslave"
  docker_root_dir_mount_point=$(get_docker_root_dir_mount_point)
  if [[ "$mount_point" == "$docker_root_dir_mount_point" && "$the_path" == "$mount_point" ]]; then
    echo "rshared"
  else
    echo "shared"
  fi
}

# 函数: 设置挂载点为共享挂载
make_shared() {
  local mount_point=$1
  $SUDO_CMD mount --make-shared $mount_point
  if [ $? -eq 0 ]; then
    print_success "已设置挂载点 $mount_point 为共享挂载"
  else
    print_error "设置挂载点 $mount_point 为共享挂载失败"
  fi
}

# 函数: 设置映射关系中的宿主机路径对应的挂载点为共享挂载
make_shared_by_path() {
  local mount_point=$(compute_mount_point $1)
  if [[ -z "$mount_point" ]]; then
    echo false
  else
    make_shared $mount_point
  fi
}

# 函数: 判断路径对应的挂载点是否为共享挂载
check_been_made_shared() {
  local then_path=$1
  if [[ -z "$then_path" ]]; then
    print_error "请提供路径"
    return 1
  fi

  # 是否存在
  if [[ ! -d "$then_path" ]]; then
    print_error "路径 $then_path 不存在或不是目录"
    return 1
  fi

  local mount_point=$(compute_mount_point "$then_path")

  # 检查挂载点是否存在
  if [[ ! -d "$mount_point" ]]; then
    print_error "挂载点 $mount_point 不存在或不是目录"
    return 1
  fi

  # 使用 grep 检查挂载信息
  if cat /proc/self/mountinfo | grep "$mount_point" | grep -q 'shared:'; then
    return 0
  else
    return 1
  fi
}

# 函数: 判断volumes中是否至少有一个挂载传播为`shared`或`rshared`的映射
check_shared_volumes() {
  local container="$1"
  # 使用 docker inspect 获取容器信息并提取 Mounts 部分
  mounts=$(docker inspect -f '{{json .Mounts}}' "$container")

  # 检查是否成功获取到 Mounts 信息
  if [[ $? -ne 0 ]]; then
    print_error "无法获取容器 $container 的 Mounts 信息"
    exit 1
  fi

  # shared或rshared的映射数量
  local shared_count=0

  # Q: 为什么最后 $shared_count 还是0？
  # A: while 循环是在一个管道中运行的，这会创建一个子shell。在子shell中对变量的修改不会影响到父shell中的变量。
  #    在这个子shell中， shared_count 的值确实被增加了，但这个增加只在子shell中有效。
  #    当子shell结束后，父shell中的 shared_count 仍然保持原来的值（0）。
  # local 在这个子shell中，shared_count=0
  #
  # echo "$mounts" | jq -c '.[]' | while read -r mount; do
  #   shared_count=$((shared_count + 1))
  # done
  # echo "$shared_count"

  # 使用 jq 解析 JSON 并遍历 Mounts
  while read -r mount; do
    propagation=$(echo "$mount" | jq -r '.Propagation')
    
    if [ "$propagation" == "shared" ] || [ "$propagation" == "rshared" ]; then
      shared_count=$((shared_count + 1))

      source=$(echo "$mount" | jq -r '.Source')
      destination=$(echo "$mount" | jq -r '.Destination')
      print_log "检测映射: $source:$destination:$propagation"
      # 判断对应挂载点是否为共享挂载
      mount_point=$(compute_mount_point "$source")
      if [[ -z "$mount_point" ]]; then
        VOLUMES_OK=false
        print_error "获取不到 $source 对应的挂载点"
      else
        print_log "$source 对应的挂载点是 $mount_point"
        check_been_made_shared "$mount_point"
        if [[ $? -eq 0 ]]; then
          print_success "挂载点 $mount_point 是共享挂载"
        else
          VOLUMES_OK=false
          print_error "$mount_point 不是共享挂载"
          print_advice "执行命令以下命令:"
          echo "sudo mount --make-shared $mount_point"
          echo "docker restart $container"
          print_advice "将以下命令添加到系统启动脚本中:"
          echo "sudo mount --make-shared $mount_point"
        fi
        echo
      fi
    fi
  done < <(echo "$mounts" | jq -c '.[]')

  if [[ $shared_count -gt 0 ]]; then
    print_success "容器设置了至少一个挂载传播为 shared 或 rshared 的映射"
  else
    print_error "容器缺少设置挂载传播为 shared 或 rshared 的映射"
    VOLUMES_OK=false
  fi
}

# 函数：选择容器
select_container() {
  local containers=$(docker ps -a --format "{{.Names}} {{.Image}}" | grep clouddrive2)
  if [[ -z "$containers" ]]; then
    print_error "未找到名称或所用镜像名称包含 clouddrive2 的容器。"
    echo "💡 可以通过参数 -c 指定容器名称，如 $SCRIPT_NAME -c clouddrive2"
    exit 1
  fi

  # 计算容器数量
  local container_count=$(echo "$containers" | wc -l)

  if [[ "$container_count" -eq 1 ]]; then
    # 如果只有一个容器，直接返回
    echo $(echo "$containers" | cut -d ' ' -f 1)
    return
  fi

  echo "❓ 请选择要诊断的容器:" >&2
  IFS=$'\n'
  select container in $containers; do
    if [[ -n "$container" ]]; then
      echo $(echo "$container" | cut -d ' ' -f 1)
      break
    else
      print_error "无效的选择。请重试。"
    fi
  done
  unset IFS # 恢复默认IFS
}

# 函数：检查容器状态
check_container_status() {
  local container="$1"
  local status=$(docker inspect -f '{{.State.Status}}' $container 2>/dev/null)
  if [[ "$status" == "running" ]]; then
    print_success "容器 $1 状态正常: $status"
  else
    STATUS_OK=false
    print_error "容器 $1 状态不是运行中: $status"
    print_advice "尝试启动或重启容器，或检查容器日志以获取更多信息。"
  fi
}

# 函数：检查 PID 模式
check_pid_mode() {
  local container="$1"
  local pid_mode=$(docker inspect -f '{{.HostConfig.PidMode}}' $container 2>/dev/null)
  if [[ "$pid_mode" == "host" ]]; then
    print_success "容器 $container 的 PID 模式正确: $pid_mode"
  else
    PID_MODE_OK=false
    print_error "容器 $container 的 PID 模式不正确: $pid_mode"
    print_advice "在 docker-compose.yml 文件中添加 'pid: host' 配置，然后重新创建容器。"
  fi
}

# 函数：检查 时区
check_timezone() {
  local container="$1"
  local timezone=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' $container | grep "^TZ=" 2>/dev/null)
  if [[ "$timezone" == "TZ=Asia/Shanghai" ]]; then
    print_success "容器 $container 的时区正确: $timezone"
  else
    TIMEZONE_OK=false
    print_error "容器 $container 的时区不正确: $timezone"
    print_advice "在 docker-compose.yml 文件中的 environment 下添加 'TZ=Asia/Shanghai'，然后重新创建容器。"
  fi
}

# 函数: 整理结果
summary_diagnosis() {
  print_log "诊断结果:"
  if [[ $STATUS_OK == true && $PID_OK == true && $VOLUMES_OK == true && $TIMEZONE_OK == true ]]; then
    print_success "未检测到异常。"
  else
    print_error "检测到异常！概要如下: "
  fi

  if [[ $STATUS_OK == false ]]; then
    print_error "  - 容器运行状态异常"
  else
    print_success "  - 容器运行状态正常"
  fi
  if [[ $PID_OK == false ]]; then
    print_error "  - 容器 PID 模式异常"
  else
    print_success "  - 容器 PID 模式正常"
  fi
  if [[ $VOLUMES_OK == false ]]; then
    print_error "  - 容器映射和挂载点设置异常"
  else
    print_success "  - 容器映射和挂载点设置正常"
  fi
  if [[ $TIMEZONE_OK == false ]]; then
    print_error "  - 容器时区设置异常"
  else
    print_success "  - 容器时区设置正常"
  fi
  echo
  print_log "具体请查阅上方的诊断日志"
}

# 显示使用说明
show_usage() {
  echo "功能: 对 CloudDrive2 容器进行简单的诊断。"
  echo
  echo "诊断项目:"
  echo "  1. 检查容器运行状态"
  echo "  2. 检查 PID 模式"
  echo "  3. 检查容器时区"
  echo "  4. 检查映射和挂载点设置"
  echo
  echo "用法: $SCRIPT_NAME [选项]"
  echo "选项:"
  echo "  -c, --container NAME        指定 Docker 容器名称，可选"
  echo "  -h, --help                  显示此帮助信息"
  echo
  echo "示例 - 无参数使用: $SCRIPT_NAME"
  echo "示例 - 指定容器: $SCRIPT_NAME -c clouddrive2"
  echo
  echo "Github：https://github.com/northsea4/clouddrive-wwh"
  echo
  echo "作者: 生瓜太保"
  echo "更新: 2024-09-23"
}

# 解析命令行参数
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -c | --container)
      CONTAINER="$2"
      shift 2
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    *)
      echo "错误：未知选项 $1"
      show_usage
      exit 1
      ;;
    esac
  done
}

# 函数: 检查容器是否存在，或容器的镜像名称不是`cloudnas/clouddrive2`开头
check_container() {
  local container="$1"

  if [[ -z "$container" ]]; then
    print_error "未指定容器"
    exit 1
  fi

  if ! docker inspect "$container" >/dev/null 2>&1; then
    print_error "未找到容器 $container"
    exit 1
  fi

  local image=$(docker inspect -f '{{.Config.Image}}' "$container")
  if ! [[ "$image" =~ "cloudnas/clouddrive2" ]]; then
    print_error "容器 $container 镜像不是 cloudnas/clouddrive2*"
    exit 1
  fi
}

# 主函数
main() {
  # 检查必需的命令
  check_command docker
  check_command jq

  # 解析命令行参数
  parse_arguments "$@"

  # 如果没有指定容器，则列出可选容器
  if [ -z "$CONTAINER" ]; then
    CONTAINER=$(select_container)
  fi

  check_container "$CONTAINER"

  print_log "开始诊断容器: $CONTAINER"
  echo

  # 检查容器状态
  check_container_status "$CONTAINER"
  echo

  # 检查 PID 模式
  check_pid_mode "$CONTAINER"
  echo

  # 检查容器时区
  check_timezone "$CONTAINER"
  echo

  get_mount_points

  # 检查挂载传播
  check_shared_volumes "$CONTAINER"
  echo

  # 整理结果
  summary_diagnosis
}

# 执行主函数
main "$@"
