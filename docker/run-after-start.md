# 重启后自动重启其他容器

方案2: [利用docker events重启其他容器](https://github.com/northsea4/clouddrive-wwh/blob/main/docker/on-start-do-sth.md)。

## 概述


- 环境
  - DSM 7.1.1
  - Docker 20.10.3
  - CloudDrive2 0.7.8

- 需求
  - 重启CloudDrive2后，其他容器对挂载目录的实时监控失效，需要重启其他容器才能恢复监控。

- 原理
  - 使用CloudDrive2自带的`run_after_start`设置，可以在启动/重启服务后执行命令或脚本。
  - 映射`/var/run/docker.sock`到CloudDrive2容器内，通过`unix-socket`调用操作其他容器。


## 流程

### 1.修改systemsettings.json

修改CloudDrive2的配置目录下的`systemsettings.json`文件。

- 添加 "run_after_start": "sh /Config/run-after-start.sh" 。
- 记得上一行末尾要有一个英文逗号。

```json
{
  "dir_cache_ttl_secs": 60,
  "max_preprocess_tasks": 2,
  "max_process_tasks": 2,
  "read_downloader_timeout_secs": 30,
  "temp_file_location": "/Config/temp",
  "sync_with_cloud": true,
  "overwrite_old_cloud_data": false,
  "upload_delay_secs": 10,
  "process_black_list": [],
  "max_download_speed_kbyps": 0.0,
  "max_upload_speed_kbyps": 0.0,
  "default_115_client_platform_string": "linux",
  "upload_ignored_extensions": [
    "@eadir",
    "ds_store"
  ],
  "update_channel": "Beta",
  "file_log_level": "Error",
  "backup_log_level": "Info",
  "terminal_log_level": "Error",
  "device_name": "dsm-docker",
  "run_after_start": "sh /Config/run-after-start.sh"
}
```


### 2.添加run-after-start.sh

在CloudDrive2配置目录下新建一个`run-after-start.sh`文件，内容如下:

```sh
#!/bin/sh

echo "CloudDrive2 - $0"

OTHER_RESTART_DELAY_SECONDS=${OTHER_RESTART_DELAY_SECONDS:-10}

OTHER_CONTAINER_NAMES=${OTHER_CONTAINER_NAMES:-""}

OTHER_APK_MIRROR=${OTHER_APK_MIRROR:-""}

if [ -z "$OTHER_CONTAINER_NAMES" ]; then
  echo "OTHER_CONTAINER_NAMES is empty, nothing to do."
  exit 0
fi

# 安装curl
if ! [ -x "$(command -v curl)" ]; then
  # 如果指定了APK_MIRROR，则替换为指定的APK_MIRROR
  if [ -n "$OTHER_APK_MIRROR" ]; then
    cp /etc/apk/repositories /etc/apk/repositories.bak
    sed -i "s/dl-cdn.alpinelinux.org/${OTHER_APK_MIRROR}/g" /etc/apk/repositories
  fi

  echo "curl not found, installing..."
  apk add curl

  if [ -n "$OTHER_APK_MIRROR" ]; then
    mv /etc/apk/repositories.bak /etc/apk/repositories
    rm -f /etc/apk/repositories.bak
  fi
fi

# 将逗号分隔的容器名称转换为换行符分隔
containers=$(echo $OTHER_CONTAINER_NAMES | tr ',' '\n')

restart_required=false

for container_name in $containers; do
  echo "Checking if container $container_name is running..."

  # 检测容器是否运行
  curl -s --unix-socket /var/run/docker.sock http://localhost/containers/$container_name/json | grep '"Running":true'

  if [ $? -eq 0 ]; then
    restart_required=true
    echo "Container $container_name is running, scheduling restart..."
  else
    echo "Container $container_name is not running, skip restart."
  fi
done

if [ "$restart_required" = true ]; then
  echo "Delaying for $OTHER_RESTART_DELAY_SECONDS seconds before restarting containers..."
  sleep $OTHER_RESTART_DELAY_SECONDS

  for container_name in $containers; do
    echo "Restarting container $container_name..."
    # TODO 有点慢，原因未知
    curl -s -X POST --unix-socket /var/run/docker.sock http://localhost/containers/$container_name/restart
    if [ $? -eq 0 ]; then
      echo "Container $container_name restarted successfully."
    else
      echo "Failed to restart container $container_name."
    fi
  done
else
  echo "No containers need to be restarted."
fi
```


### 3.设置容器环境变量和映射

- yml仅作示例，重点是确保设置示例中有`[*]`注释的环境变量(3个)和映射(1个)。

```yml
version: '3'

services:
  clouddrive2:
    image: cloudnas/clouddrive2-unstable:latest
    container_name: clouddrive2
    environment:
      - TZ=Asia/Shanghai
      - CLOUDDRIVE_HOME=/Config
      # [*] 启用run_after_start脚本
      - ENABLE_RUN_AFTER_START=true
      # [*] 需要重启的容器。多个容器名称用英文逗号隔开，不能有空白
      - OTHER_CONTAINER_NAMES=auto_symlink,nas-tools
      # [*] 重启其他容器前等待的秒数
      - OTHER_RESTART_DELAY_SECONDS=10
      # 可选，容器apk镜像源域名，比如阿里云镜像源: mirrors.aliyun.com
      # - OTHER_APK_MIRROR=mirrors.aliyun.com
    volumes:
      - ./config:/Config
      - /volume2:/volume2:rshared
      - /volume3:/volume3:shared
      # [*] 把docker.sock映射到容器内
      - /var/run/docker.sock:/var/run/docker.sock:ro
    devices:
      - /dev/fuse:/dev/fuse
    ports:
      - 19798:19798
    privileged: true
    restart: unless-stopped
    network_mode: bridge
    pid: host
```

## 总结

- 只针对Linux + Docker环境。
- 只能处理重启服务这种情况，其他比如"卸载再挂载"操作，暂时不考虑。