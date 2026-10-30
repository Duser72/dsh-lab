#!/bin/bash
# DSH 加固：8080 只允许 tailscale 访问，丢弃 eth0（局域网）入站
# 幂等：重复执行不会重复添加规则
set -uo pipefail

command -v nft >/dev/null || exit 0

# 表/链可能尚未由 tailscaled 建立
nft list table inet filter >/dev/null 2>&1 || nft add table inet filter
nft list chain inet filter input >/dev/null 2>&1 || \
  nft add chain inet filter input '{ type filter hook input priority filter; policy accept; }'

if ! nft list chain inet filter input 2>/dev/null | grep -q 'iifname "eth0" tcp dport 8080'; then
  nft add rule inet filter input iifname "eth0" tcp dport 8080 counter drop
  echo "added: drop eth0 -> 8080"
else
  echo "already present: drop eth0 -> 8080"
fi

if ! nft list chain inet filter input 2>/dev/null | grep -q 'iifname "eth0" tcp dport 22'; then
  nft add rule inet filter input iifname "eth0" tcp dport 22 counter drop
  echo "added: drop eth0 -> 22"
else
  echo "already present: drop eth0 -> 22"
fi
