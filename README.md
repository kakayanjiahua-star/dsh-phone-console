# dsh-phone-console

> 把 Windows 上的 **DeepSeek Harness Desktop** 变成手机可遥控的 agent：
> **实时看任务进度 → 手机下任务 → 任务完成推到手机**，家里 WiFi / 外出 5G / 换网络都能用。

[English](README.en.md) · 中文

![preview](docs/preview.png)

*左：会话列表 + 实时状态；右：实时直播（思考 / 工具调用 / 逐字输出）。示例为**合成假数据**，不含任何个人信息。*

---

## 它能做什么

用手机（本项目在 iPhone 12 Pro Max 上落地）远程操作电脑上的 DSH：

- 📺 **实时观察**：点开会话就能看到 agent 的思考过程、工具调用、逐字输出、任务清单进度
- ⌨️ **下任务**：手机直接发消息、新建会话、停止生成
- ❓ **回答问题**：agent 中途提问时，手机上直接选项/填写
- 🔔 **完成提醒**：本轮任务结束 / agent 提问时，**Bark 推送**到手机，**点通知直达会话**
- 🌐 **不受网络束缚**：在家 WiFi、在外 5G、电脑换 WiFi 都能连（公网隧道）
- 🛡️ **地址漂移自愈**：电脑 IP 变化时，自动把新地址推到你手机

## 为什么需要这个项目

DSH Desktop **本身已内置**手机网关（配对二维码 + 手机页面 + 实时流），但实际用起来有 7 个坑：

1. 无通知——任务跑完了不告诉你
2. 电脑 IP 一变（换 WiFi / DHCP），手机就"打不开"，而且**没人告诉你新地址**
3. 网关入口只放行 RFC1918，**Tailscale 的 100.64/10 被 403 拦掉**
4. PowerShell 5.1 不支持 `-NoProxy`，导致监视器**静默失败**
5. `.ps1` 不带 BOM 时，中文在 5.1 下直接语法报错
6. 隧道一开，局域网地址会被 **302 跳到公网地址**（公网不通时"局域网也打不开"）
7. iOS 用 Chrome 打不开、必须 Safari + `http://`

本项目把这些问题**全部解决并脚本化**。

## 架构

```
┌──────────┐   ①局域网 http://<PC-IP>:43127
│  iPhone  │   ②公网隧道 https://xxx.trycloudflare.com   ┌────────────────────────┐
│  Safari  │──③Tailscale http://100.x.y.z:43127 ────────▶│  DSH Desktop (Windows) │
│ (DSH     │                                             │  ├ LanMobileBridge     │
│  Mobile) │◀── SSE 实时流 / 受限 RPC ────────────────────│  │   0.0.0.0:43127      │
└──────────┘                                             │  ├ Harness (agent)     │
     ▲                                                   │  └ hooks-codex 桥      │
     │  Bark 推送（任务完成 / 需要回答，含直达链接）        └───────────┬────────────┘
     └──────────────────────────────────────────────────────────────┘
                          ds-phone-notify.ps1
```

## 快速开始

```powershell
# 1) 克隆
git clone https://github.com/kakayanjiahua-star/dsh-phone-console.git
cd dsh-phone-console

# 2) 一键安装（复制脚本、写配置、挂 hooks、注册自启）
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -InstallDir "D:\dsh"

# 3) 填推送凭据（iPhone 装免费 Bark，首页那串 ~22 位字符就是 key）
notepad D:\dsh\ds-phone-notify.json

# 4) 电脑 DSH Desktop 按 Ctrl+Shift+M → 手机扫码 → 电脑点「允许」
```

详见 [`SKILL.md`](SKILL.md)（面向 AI agent 的完整操作手册）与
[`references/setup-guide.zh.md`](references/setup-guide.zh.md)（面向人的图文步骤）。

## 三条接入路径怎么选

| 路径 | 手机要装 App | 换网络/5G | 稳定度 | 说明 |
|---|---|---|---|---|
| 局域网 | ❌ | ❌ 必须同一 WiFi | 低 | IP 会随路由器/DHCP 变，**别做主入口** |
| **公网隧道**（推荐） | **❌** | ✅ | 中 | 链接每次重启会变，但**监视器会自动推新链接给你** |
| Tailscale | ✅（**中国区 App Store 无此 App**） | ✅ | 高 | 地址永久固定，适合能装到 App 的用户 |

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | AI agent 用的完整技能说明（含陷阱清单、验证清单） |
| `scripts/install.ps1` | 一键安装：部署脚本、挂 hooks 桥、注册开机自启 |
| `scripts/ds-mobile-bridge.ps1` | 常驻监视器：自动开隧道 + 地址变化推送 + URL 缓存 |
| `scripts/ds-phone-notify.ps1` | 推送脚本：Bark / ntfy + 直达链接 + 本地日志 |
| `scripts/ds-balance-watch.ps1` | 余额哨兵：查模型账户余额，低于阈值推手机 + 桌面气泡（配 `ds-balance-watch.json`） |
| `scripts/ds-hooks.json` | Codex hooks 配置（Stop / PostToolUse） |
| `scripts/ds-patch-cgnat.ps1` | 放行 Tailscale 网段（应用升级后需重打） |
| `references/setup-guide.zh.md` | 面向用户的图文步骤 |
| `references/troubleshooting.zh.md` | 一页维护手册（打不开时照做） |

## 实测环境

- Windows 11 + DSH Desktop 0.7.2 / 0.8.0（Harness 0.1.2-alpha）
- iPhone 12 Pro Max（iOS 26.x，Safari）
- 中国移动宽带 + 5G；电脑侧有代理（mihomo/Clash）

## 发布前隐私闸门（版本化提交钩子）

仓库自带 `.githooks/pre-commit`：提交时会扫描**暂存内容**，命中即拒绝提交 ——
真实 Bark key / ntfy topic、GitHub token、`sk-` 密钥、64 位十六进制串、
Tailscale `100.64/10` 与内网地址、私人 Windows 用户路径、邮箱、个人账号名。

克隆后**启用一次**：

```bash
git config core.hooksPath .githooks
```

确有需要时可用 `git commit --no-verify` 跳过（不建议）。
经验：**一旦密钥推错，仅补一个"修复提交"不够**——密钥仍在历史里，必须 `git commit --amend`
（或 `git filter-repo`）后强推，并轮换该密钥。

## 安全

网关拥有**文件读写与命令执行**能力。请只在可信网络暴露，公网隧道 URL 含 5 分钟有效的一次性配对
token 并需电脑端人工「允许」。**不要提交 `ds-phone-notify.json`**（推送 key），`.gitignore` 已排除。

## License

MIT

---

<a id="english"></a>
## English

**dsh-phone-console** turns **DeepSeek Harness Desktop** on Windows into a phone-controllable agent:
watch agent tasks live, dispatch new tasks, answer agent questions, and get **push notifications with a
tap-through link** when a task finishes — over home Wi-Fi, 5G, or a Cloudflare/Tailscale tunnel.

The DSH Desktop app already ships the phone gateway (QR pairing + mobile page + live SSE stream). This
project adds what's missing in practice: **completion notifications, address-drift self-healing, a
persistent tunnel monitor, and a documented set of seven real-world pitfalls** (PowerShell 5.1
`-NoProxy`, UTF-8 BOM, the RFC1918-only gateway guard blocking `100.64/10`, LAN→tunnel 302 redirects,
iOS Safari-only access, and more).

See [`SKILL.md`](SKILL.md) for the full agent-facing playbook.
