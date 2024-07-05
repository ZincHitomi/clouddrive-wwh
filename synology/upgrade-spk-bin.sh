#!/bin/bash

set -e

# 帮助
help() {
  echo "Usage: $0 [version]"
  echo "  version: 目标CloudDrive2 版本，如 0.7.5"
}

# 输入参数
while [[ $# -gt 0 ]]
do
  key="$1"
  case $key in
    -h|--help)
      help
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# 必须root权限执行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本"
  exit
fi

# 版本。如果没有通过参数传入，则询问输入
if [ -z "$1" ]; then
  read -p "请输入目标 CloudDrive2 版本: " version
else
  version=$1
fi

if [ -z "$version" ]; then
  echo "❌ 请输入 CloudDrive2 版本"
  exit 1
fi

# 架构
arch=$(uname -m)
# 如果是arm64，设置为aarch64
if [ "$arch" == "arm64" ]; then
  arch="aarch64"
fi

echo "停止 CloudDrive2 套件"
synopkgctl stop CloudDrive2

echo "进入 CloudDrive2 套件目录"
cd /var/packages/CloudDrive2/target

echo "备份 clouddrive 目录"
bak_dir="clouddrive-bak"
if [ -d $bak_dir ]; then
  read -p "备份目录 $bak_dir 已存在，是否删除？ (y/n) " rm_bak
  if [ "$rm_bak" == "y" ]; then
    rm -rf $bak_dir
    mv clouddrive $bak_dir
  else
    echo "跳过备份"
  fi
else
  mv clouddrive $bak_dir
fi

echo "下载新版文件..."
url="https://github.com/cloud-fs/cloud-fs.github.io/releases/download/v${version}/clouddrive-2-linux-${arch}-${version}.tgz"
filename="clouddrive-2-linux-${arch}-${version}.tgz"
curl -L -o $filename "$url"

echo "解压缩..."
# 注意！tgz不能使用`--strip-components=1`去除顶层目录。这里实际得到`clouddrive-2-linux-${arch}-${version}`目录
tar -zxf $filename
dir_name=$(basename $filename .tgz)
mv $dir_name clouddrive

echo "修改目录权限..."
chown -R CloudDrive2:CloudDrive2 clouddrive

echo "移除临时文件..."
rm $filename

echo "删除备份文件..."
rm -rf $bak_dir

# 询问是否启动套件
read -p "是否启动CloudDrive2套件? (y/n) " start_package
if [ "$start_package" == "y" ]; then
  echo "启动 CloudDrive2 套件"
  synopkgctl start CloudDrive2
fi

echo "更新完成。Enjoy!"
