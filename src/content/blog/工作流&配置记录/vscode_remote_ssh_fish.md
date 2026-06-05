---
title: '远端服务器默认 fish 导致 VS Code Remote SSH 超时问题解决'
description: '总结在 VS Code Remote SSH 连接远程默认 shell 为 fish 时导致超时问题的解决方案与配置经验。'
pubDate: '2026-06-05'
---

# 远端服务器默认 fish 导致 VS Code Remote SSH 超时问题解决

在使用 **VS Code Remote SSH** 连接远程服务器时，如果远程用户的默认 shell 是 **fish**，常会出现如下问题：

- SSH 认证成功，但 VS Code 远程服务器启动失败  
- 日志显示 `Connecting with SSH timed out`  
- 远程 shell 输出可能被 VS Code 启动脚本误解析  

这是因为 **fish shell 的语法与传统 POSIX shell 不兼容**，且 fish 会在非交互式 shell 中执行 `config.fish`，导致 VS Code 的初始化脚本被破坏。

---

## 解决方案总结

经过实践验证，以下三步组合可完全解决该问题：

### 1. 在本地 VS Code 配置中指定远程平台

在 **`settings.json`** 中添加：

```json
"remote.SSH.remotePlatform": {
    "106.75.252.110": "linux"
}
```

> 作用：避免 VS Code 在 fish shell 环境下自动探测平台时失败。

------

### 2. 精简远程 fish 配置

编辑远程服务器的 **`~/.config/fish/config.fish`**，保持最小配置，例如：

```fish
# 清空默认问候语
set fish_greeting ""
```

> 注意：**不要在非交互 shell 中执行初始化命令**（如 `starship init`、`tmux`、`fastfetch` 等），否则会破坏 VS Code 远程启动流程。

------

### 3. 修改本地 VS Code SSH 设置

将 **Local Server** 模式关闭：

```json
{
    "remote.SSH.useLocalServer": false
}
```

> 作用：绕过因 fish shell 导致的本地 server 初始化阻塞问题。

------

## 总结

通过以上组合配置：

1. 明确远程平台类型
2. 避免 fish 在非交互模式下输出或执行命令
3. 关闭本地 server 启动

即可稳定使用 VS Code Remote SSH 连接远程默认 shell 为 fish 的用户，彻底避免超时问题。

> 经验提示：对于其他非 POSIX shell（如 tcsh、csh），类似方法也适用。

