#!/bin/sh

# JUST FOR TEST

# 基础URL
NT_BASE_URL=${NT_BASE_URL:-"http://192.168.1.10:3000"}

# API密钥。「设置 - 基础设置 - 安全 - API密钥」，如果开启了「设置 - 基础设置 - 安全 - 验证外部请求的API密钥」则需要填写该值
NT_API_KEY=${NT_API_KEY:-""}

# 用户名
NT_USERNAME=${NT_USERNAME:-"admin"}

# 密码
NT_PASSWORD=${NT_PASSWORD:-"password"}

# 需要处理的「源目录」路径列表，使用英文逗号分隔。留空表示处理全部同步
NT_SOURCE_PATHS=${NT_SOURCE_PATHS:-""}


# 登录获取token
result=$(curl -s -X 'POST' \
  ${NT_BASE_URL}/api/v1/user/login \
  -H 'accept: application/json' \
  -H "Authorization: Bearer ${NT_API_KEY}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=${NT_USERNAME}&password=${NT_PASSWORD}")

token=$(echo $result | jq -r '.data.token')
# echo "token: ${token}"


# 查询全部同步任务
result=$(curl -s -X 'POST' \
  ${NT_BASE_URL}/api/v1/sync/directory/list \
  -H 'accept: application/json' \
  -H "Authorization: ${token}" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "")


# 遍历同步目录(result)
echo $result | jq -r '.data.result | keys | .[]' | while read id; do
  # 源目录路径
  from=$(echo $result | jq -r ".data.result[\"${id}\"].from")
  # 状态
  enabled=$(echo $result | jq -r ".data.result[\"${id}\"].enabled")

  if [ "$enabled" != "true" ]; then
    continue
  fi

  echo "id: ${id}, from: ${from}"  

  # 遍历NT_SOURCE_PATHS，判断是否包含from，如果包含，则执行同步
  echo $NT_SOURCE_PATHS | tr ',' '\n' | while read path; do
    # 如果没有指定源目录路径，或者指定的源目录路径包含from，则执行同步
    if [ "$path" = *"$from"* ] || [ -z "$NT_SOURCE_PATHS" ]; then
      echo "重启监控: ID: ${id}, 源目录: ${from}"

      result=$(curl -s -X 'POST' \
        ${NT_BASE_URL}/api/v1/sync/directory/status \
        -H 'accept: application/json' \
        -H "Authorization: ${token}" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "sid=${id}&flag=enable&checked=1")

      echo $result | jq
    fi
  done
done