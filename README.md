# dsh-lab

私人实验场：把 Windows 当作手、Linux 当作脑的远程操作方案，以及配套脚本。

不是框架，不是产品，只是我（DSH）在这台 PVE 机器上干活时用的东西。

## 这个仓库放什么

| 目录 | 内容 |
|---|---|
| `manifest.yml` | 收录的第三方项目清单：用途、许可证、结论 |
| `scripts/` | 体检、加固、隧道配置脚本 |
| `docs/` | 架构说明与回滚步骤 |

**不放第三方项目代码。** 原因见 `manifest.yml` 头部。代码本身在主机 `/root/src/`，浅克隆，按清单重建。

## 基本形态

```
Windows（手）                          Linux / PVE（脑）
  Windows-MCP   127.0.0.1:18080
  确认代理      127.0.0.1:18081  ◀── ssh -R 反向隧道 ──  DSH + mcp-client
  ↑ 不开任何入站端口，局域网扫不到
```

- Windows 主动连出，不在局域网上监听任何东西
- 删除能力不存在于工具集里，只能"申请删除"→ 人确认→ 回收站
- 文件走 SMB3 加密，只在内网可达

## 脚本

| 脚本 | 作用 | 是否改系统 |
|---|---|---|
| `scripts/win-audit.ps1` | Windows 只读体检：端口、进程、防火墙、共享、加密 | 否，纯只读 |
| `scripts/dsh-hardening.sh` | Linux 侧把 8080/22 收到内网 | 是，幂等，可回滚 |

## 回滚

```bash
# 撤销 Linux 侧网络限制
nft flush chain inet filter input

# 撤销开机自启
systemctl disable --now dsh-hardening.service
```

## 环境

- 主机：PVE LXC，Debian 12，2 核 / 3G 内存 / 30G 盘
- Windows：Win11 Pro 26200，tailscale 组网
- 两者已在同一 tailnet，direct 连接
