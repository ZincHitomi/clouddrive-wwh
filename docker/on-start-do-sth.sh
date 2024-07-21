#!/bin/bash

# 初始化变量
MONITOR_CONTAINER=""
OTHER_CONTAINERS=""
DELAY=10

# 函数: 显示使用说明
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --container, -c   指定需要监控的容器"
    echo "  --containers, -cs 指定其他需要操作的容器，多个使用英文逗号分隔"
    echo "  --delay, -d       指定延时多久后才操作其他容器（秒）。默认为 10 秒"
    echo "  --help, -h        显示此帮助信息"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --container|-c)
            MONITOR_CONTAINER="$2"
            shift 2
            ;;
        --containers|-cs)
            OTHER_CONTAINERS="$2"
            shift 2
            ;;
        --delay|-d)
            DELAY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            usage
            exit 1
            ;;
    esac
done

# 检查必要参数
if [[ -z "$MONITOR_CONTAINER" || -z "$OTHER_CONTAINERS" ]]; then
    echo "错误: 必须指定监控容器和其他需要操作的容器。"
    usage
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - 脚本启动"
echo "监控容器: $MONITOR_CONTAINER"
echo "其他容器: $OTHER_CONTAINERS"
echo "延迟时间: $DELAY 秒"

# 监控指定容器
docker events --filter container="$MONITOR_CONTAINER" --filter event=start | while read event
do
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 检测到 $MONITOR_CONTAINER 启动"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 等待 $DELAY 秒"
    sleep $DELAY
    
    IFS=',' read -ra CONTAINER_ARRAY <<< "$OTHER_CONTAINERS"
    for container in "${CONTAINER_ARRAY[@]}"; do
        if docker inspect --format='{{.State.Running}}' $container 2>/dev/null | grep -q "true"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 重启容器: $container"
            docker restart $container
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 容器 $container 未运行，跳过"
        fi
    done
done