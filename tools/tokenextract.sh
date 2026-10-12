#!/bin/bash
# 提取米家设备 Token —— 官方 PiotrMachowski/Xiaomi-cloud-tokens-extractor
# 用法: bash tools/tokenextract.sh
# 说明: 交互式输入小米账号/密码; 支持区域选择(cn=国区)与二维码登录。
#       运行结束后在终端输出表中找到充电器那一行, 复制 TOKEN 列(24位hex)填进 App。
set -e

TOOL_DIR="$HOME/.cuktech-tools"
PY="$TOOL_DIR/bin/python3"
SCRIPT="$TOOL_DIR/xiaomi-extractor/token_extractor.py"

if [ ! -f "$SCRIPT" ]; then
  echo "工具未找到, 请先让 AI 安装"
  exit 1
fi

exec "$PY" "$SCRIPT" "$@"