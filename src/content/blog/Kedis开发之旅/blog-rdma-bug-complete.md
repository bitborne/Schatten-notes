---
title: '一次 RDMA 主从同步的诡异 Bug：从内存屏障到初始化时序的深渊'
description: '同一内存地址，写入值为 1，读取值却为 0。本文记录了一次诡异的多线程 Bug 排查全过程：从怀疑 CPU 内存可见性、添加内存屏障，到最终发现竟是初始化顺序导致的竞态条件。涉及 x86_64 内存模型、Linux eventfd 机制、以及双 Channel 架构设计的深度思考。适合系统开发者、架构师阅读。'
pubDate: 2026-03-04
---

# 一次 RDMA 主从同步的诡异 Bug：从内存屏障到初始化时序的深渊

> 项目：[Kedis](https://github.com/bitborne/Kedis) - 一个基于 RDMA 的高性能 KV 存储系统
> 作者：[@bitborne](https://github.com/bitborne)
> 日期：2026-03-04

---

## 引言

在多线程系统开发中，有些 Bug 就像幽灵：你明明觉得代码逻辑没问题，但运行时就是表现异常。更可怕的是，这些 Bug 往往隐藏在"看起来最不可能出错"的地方——比如初始化顺序。

这篇文章记录我在实现 Kedis v3.0 架构时遇到的一个诡异问题：同一个内存地址，写入的值和读取的值竟然不一样。排查过程涉及 CPU 内存模型、eventfd 机制、以及一个被忽视的初始化时序问题。

如果你也写多线程代码，相信这篇文章能给你一些启示。

---

## 一、架构背景：双 Channel 主从同步

在深入 Bug 之前，先介绍 Kedis 的 v3.0 架构设计。

### 1.1 架构 overview

Kedis 是一个支持 RDMA 主从复制的 KV 存储系统。v3.0 架构采用**双 Channel 设计**：

```
┌─────────────────────────────────────────────────────────────┐
│                        从节点 (Slave)                        │
│  ┌──────────────────┐         ┌──────────────────────────┐ │
│  │   Main Channel   │         │     RDMA Channel         │ │
│  │   (io_uring)     │         │     (独立线程)            │ │
│  │                  │         │                          │ │
│  │  处理客户端命令   │◄───────►│  接收主节点存量数据        │ │
│  │  - 读命令穿透执行 │         │  - 独占写入引擎           │ │
│  │  - 写命令入队     │         │  - 完成后通知主线程       │ │
│  └──────────────────┘         └──────────────────────────┘ │
│           │                              │                  │
│           └──────────┬───────────────────┘                  │
│                      ▼                                      │
│              ┌──────────────┐                              │
│              │  KV Engine   │                              │
│              │  (数据引擎)   │                              │
│              └──────────────┘                              │
└─────────────────────────────────────────────────────────────┘
```

**设计要点**：
- **Main Channel**：使用 io_uring 处理客户端请求，支持读命令"穿透"执行
- **RDMA Channel**：独立线程通过 RDMA 接收主节点存量数据，**独占写引擎**
- **关键约束**：SYNCING 期间，Main Channel 不能并发写入引擎，否则会导致数据错乱

### 1.2 状态机设计

从节点有三种状态：

```c
#define SLAVE_STATE_IDLE     0   /* 空闲：未开始同步 */
#define SLAVE_STATE_SYNCING  1   /* 同步中：读穿透，写入队 */
#define SLAVE_STATE_READY    2   /* 就绪：正常执行所有命令 */
```

**状态流转**：

```
                    start_slave_sync()
IDLE ───────────────────────────────► SYNCING
  ▲                                    │
  │                                    │ RDMA 完成
  │         slave_sync_init()         ▼
  └──────────────────────────────── READY
              (重置状态)
```

### 1.3 SYNCING 期间的处理逻辑

当从节点处于 `SYNCING` 状态时，收到客户端命令的处理逻辑：

```c
if (sync_state == SLAVE_STATE_SYNCING) {
    if (is_write_command(cmd_name)) {
        /* 写命令：入积压队列，返回 QUEUED */
        slave_sync_enqueue(c->argc, c->argv);
        add_reply_status(c, "QUEUED");
        return 0;
    }
    /* 读命令：穿透执行（继续往下走） */
}
/* 执行命令（读命令或 READY 状态） */
switch (cmd) { ... }
```

**预期行为**：
- `ASET key value` → `+QUEUED`
- `AGET key` → 返回值（穿透执行）

但实际测试中，出现了诡异的现象...

---

## 二、排查篇：层层深入的 Debug 之旅

### 2.1 诡异现象

那是一个普通的周二。早上九点，我启动了新实现的 v3.0 架构。

按照设计，从节点在存量同步期间应该将写命令入队，返回 `+QUEUED`。但当我向从节点发送一条 `ASET key value` 时，客户端却迟迟没有响应。

直到两分钟后——当 RDMA 存量同步完成的那一刻——所有积压的响应突然一起涌了回来：

```
+OK
+OK
+OK
...
```

**问题出现了**：
1. 在 `SYNCING` 状态下，写命令应该返回 `+QUEUED`，但实际返回的是 `+OK`
2. 这些 `+OK` 被延迟到了同步结束后才到达

### 2.2 第一阶段：怀疑内存可见性

我的第一反应是：状态机判断逻辑写错了？

我检查了 `kvs_protocol()` 函数，SYNCING 状态的处理逻辑看起来是正确的：

```c
if (sync_state == SLAVE_STATE_SYNCING) {
    int is_write = is_write_command(cmd_name);
    if (is_write) {
        int ret = slave_sync_enqueue(c->argc, c->argv);
        if (ret == 0) {
            add_reply_status(c, "QUEUED");  // 应该返回 QUEUED
        }
        return 0;  // 提前返回，不会执行到 switch-case
    }
}
/* 执行命令（只有读命令会走到这里） */
```

如果 `sync_state` 真的是 `SYNCING`，代码会走进这个分支，返回 `QUEUED`，然后提前 `return`。但实际情况是代码执行到了后面的 switch-case，返回了 `OK`。

**这意味着：`sync_state` 的值不是 `SYNCING`。**

我在 `kvs_protocol()` 入口处加了一行关键日志：

```c
int sync_state = slave_sync_get_state();
kvs_logInfo("[kvs_protocol SLAVE] sync_state=%d (IDLE=%d, SYNCING=%d, READY=%d)\n",
            sync_state, SLAVE_STATE_IDLE, SLAVE_STATE_SYNCING, SLAVE_STATE_READY);
```

重新编译、运行，查看日志：

```
[2026-03-04 17:00:35] [INFO] [Slave Sync] 状态设置为 SYNCING (地址: 0x564854cd6b68, 值: 1)
[2026-03-04 17:00:38] [INFO] [kvs_protocol SLAVE] sync_state=0 (IDLE=0, SYNCING=1, READY=2)
[2026-03-04 17:00:38] [INFO] [kvs_protocol SLAVE] 状态为 IDLE，返回 LOADING
```

**看到了吗？** RDMA 线程在 `17:00:35` 把状态设置为 `SYNCING(1)`，但主线程在 `17:00:38` 读取到的却是 `IDLE(0)`。

同一时刻、同一个变量，值却不一样。

我的第一反应是：**CPU 内存可见性问题**。RDMA 线程在一个 CPU 核心上写入，主线程在另一个核心上读取，缓存不一致？

我检查了代码，`g_sync_state` 已经声明为 `volatile`：

```c
static volatile int g_sync_state = SLAVE_STATE_IDLE;
```

但 `volatile` 只能防止编译器优化，不能保证 CPU 缓存一致性。我尝试在赋值和读取处都加上内存屏障：

```c
/* 设置状态时 */
g_sync_state = SLAVE_STATE_SYNCING;
__sync_synchronize();  // 内存屏障

/* 读取状态时 */
__sync_synchronize();
int state = g_sync_state;
__sync_synchronize();
```

重新编译、测试。

**问题依然存在。** `sync_state` 还是 0。

### 2.3 第二阶段：同一个地址，不同的值

内存屏障都加了，为什么还是不行？我开始怀疑：是不是有两个同名的变量？链接时出现了重复定义？

我在关键位置打印变量地址：

```c
/* slave_sync.c: 设置状态时 */
kvs_logInfo("[Slave Sync] 状态设置为 SYNCING (地址: %p, 值: %d)\n",
            (void*)&g_sync_state, g_sync_state);

/* slave_sync.c: 读取状态时 */
kvs_logInfo("[slave_sync_get_state] 读取到状态: %d (地址: %p)\n",
            state, (void*)&g_sync_state);
```

日志输出：

```
[2026-03-04 17:11:43] [INFO] [Slave Sync] 状态设置为 SYNCING (地址: 0x564854cd6b68, 值: 1)
[2026-03-04 17:11:46] [INFO] [slave_sync_get_state] 读取到状态: 0 (地址: 0x564854cd6b68)
```

**地址完全一样：`0x564854cd6b68`。**

这就是最诡异的地方：同一个内存地址，RDMA 线程写入的值是 1，主线程读取的值却是 0。

那一刻我坐在电脑前，盯着屏幕上的两个 `0x564854cd6b68`，脑子里只有一个念头：**不可能，绝对不可能。如果不是内存可见性问题，那一定是有其他代码在"偷改"这个变量。**

### 2.4 第三阶段：谁在"偷改"我的状态？

我全局搜索所有给 `g_sync_state` 赋值的地方：

```bash
grep -n "g_sync_state\s*=" src/core/slave_sync.c
```

输出：

```
21:static volatile int g_sync_state = SLAVE_STATE_IDLE;
110:        g_sync_state = SLAVE_STATE_IDLE;
116:        g_sync_state = SLAVE_STATE_READY;
184:        g_sync_state = SLAVE_STATE_IDLE;
250:    g_sync_state = SLAVE_STATE_SYNCING;
261:        g_sync_state = SLAVE_STATE_IDLE;
```

第 250 行是 RDMA 线程设置 `SYNCING` 的地方，第 116 行是设置 `READY` 的地方。但第 184 行是什么？

我打开代码，第 184 行在 `slave_sync_init()` 函数中：

```c
int slave_sync_init(void) {
    /* ... 创建 eventfd ... */

    /* 初始化积压队列 */
    g_backlog.head = NULL;
    g_backlog.tail = NULL;
    g_backlog.count = 0;

    g_sync_state = SLAVE_STATE_IDLE;  // <-- 就是这一行！

    return g_event_fd;
}
```

**找到了！** `slave_sync_init()` 会把状态重置为 `IDLE`。

但问题是：`slave_sync_init()` 是什么时候被调用的？我明明是在 `start_slave_sync()` 之后才看到状态变成 `SYNCING` 的。

我追踪调用链：

```bash
grep -rn "slave_sync_init" src/
```

发现了关键线索：

```
src/network/proactor.c:239:    g_event_fd = slave_sync_init();
```

`proactor_start()` 中调用了 `slave_sync_init()`！

我打开 `main()` 函数查看启动顺序：

```c
/* main() 函数中的启动顺序 */
if (g_config.replica_mode == REPLICA_MODE_SLAVE) {
    start_slave_sync();  // <-- 设置 SYNCING
}
// ... 其他初始化 ...
proactor_start(port, kvs_protocol);  // <-- 重置为 IDLE！
```

**真相大白！**

执行顺序是：
1. `start_slave_sync()` → 创建 RDMA 线程 → 设置 `g_sync_state = SYNCING`
2. `proactor_start()` → 调用 `slave_sync_init()` → **重置 `g_sync_state = IDLE`**

这就是一切的原因。`slave_sync_init()` 的设计初衷是"初始化"，所以它把状态重置为 `IDLE`。但问题在于，**在 v3.0 架构中，初始化被拆成了两部分**：`slave_sync_init()` 创建 eventfd，`start_slave_sync()` 启动同步。而这两部分的调用顺序，恰好是反的。

更隐蔽的是，这种情况只在**配置了自动同步的从节点**上出现。如果是手动执行 `SYNC` 命令触发的同步，`slave_sync_init()` 早已在 `proactor_start()` 中执行过了，不会出现问题。

### 2.5 修复验证

找到根因后，修复就很简单了：调整初始化顺序，确保 `slave_sync_init()` 在 `start_slave_sync()` 之前调用。

修改后的启动顺序：

```c
if (g_config.replica_mode == REPLICA_MODE_SLAVE) {
    /* 先初始化从节点同步系统（创建 eventfd） */
    slave_sync_init();

    /* 再启动存量同步（创建 RDMA 线程） */
    start_slave_sync();
}
```

同时，给 `slave_sync_init()` 加上防御性检查：

```c
int slave_sync_init(void) {
    /* 【v3.0 修复】避免重复创建 eventfd */
    if (g_event_fd >= 0) {
        return g_event_fd;  // 已初始化，直接返回
    }

    /* 创建 eventfd... */
    g_event_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);

    /* ... */

    g_sync_state = SLAVE_STATE_IDLE;
    return g_event_fd;
}
```

重新编译、测试：

```
[2026-03-04 17:30:15] [INFO] [kvs_protocol SLAVE] sync_state=1 (IDLE=0, SYNCING=1, READY=2)
[2026-03-04 17:30:15] [INFO] [kvs_protocol SYNCING] 写命令 'ASET' 已入积压队列，返回 QUEUED
```

**终于对了！** `sync_state=1`，写命令入队，返回 `+QUEUED`。

从早上九点到下午六点，整整一天。晚饭前，这个问题终于解决了。

---

## 三、原理篇：底层技术深度解析

排查过程结束了，但问题背后的技术原理值得深入探讨。这一章我们来分析三个关键知识点：内存模型、eventfd、初始化时序。

### 3.1 x86_64 内存模型与 volatile 的真相

#### 3.1.1 volatile 的局限性

很多开发者认为 `volatile` 可以保证多线程间的内存可见性，但这是**错误的**。

`volatile` 在 C/C++ 中的语义只有两点：
1. **禁止编译器优化**：每次读取都从内存取值，不缓存到寄存器
2. **保证指令顺序**：不被编译器重排序

但 `volatile` **不保证 CPU 层面的内存可见性**。在多核 CPU 上，每个核心有自己的缓存（L1/L2），一个核心写入的数据，另一个核心不一定能立即看到。

#### 3.1.2 x86_64 的强内存模型

x86_64 架构是**强内存模型**（Strong Memory Model），这意味着：
- 单个核心的读写操作，对其他核心来说是**按程序顺序可见的**
- 不需要像 ARM 那样频繁的内存屏障

但"强"不等于"不需要同步"。x86_64 的 Store Buffer 机制会导致**Store-to-Load 重排序**：

```
Core 0: write A = 1      (写入 Store Buffer，立即返回)
Core 0: read B           (可能读到旧值)
```

这就是为什么即使加了 `volatile`，主线程还是可能读到旧值。

#### 3.1.3 内存屏障的作用

内存屏障（Memory Barrier）的作用是**强制刷新缓存**，确保：
1. **Store Barrier**：屏障前的所有写操作，对屏障后的读操作可见
2. **Load Barrier**：屏障后的读操作，能看到屏障前写操作的最新值
3. **Full Barrier**：同时保证 Store 和 Load 的顺序

GCC 提供的 `__sync_synchronize()` 是一个 Full Barrier，在 x86_64 下会生成 `mfence` 指令。

```asm
; mfence 指令
mfence  ; 确保所有内存操作完成，缓存同步
```

#### 3.1.4 为什么内存屏障没有解决问题？

回到我们的 Bug，内存屏障为什么没有解决问题？

因为问题的根源**不是内存可见性**，而是**有其他代码在修改同一个变量**。内存屏障只能保证缓存一致性，但无法阻止其他代码的写入。

这提醒我们：**加内存屏障之前，先确认问题的根源确实是内存可见性**。

### 3.2 Linux eventfd：内核态事件通知

#### 3.2.1 eventfd 是什么？

eventfd 是 Linux 提供的一种**轻量级事件通知机制**。它是一个 64 位计数器，支持以下操作：

- **write**：向计数器增加值
- **read**：读取并清零计数器
- **阻塞/非阻塞**：可以配置为阻塞等待或立即返回

```c
#include <sys/eventfd.h>

int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
uint64_t val = 1;
write(efd, &val, sizeof(val));  // 通知
read(efd, &val, sizeof(val));   // 接收通知
```

#### 3.2.2 eventfd 在 Kedis 中的应用

在 v3.0 架构中，eventfd 用于 RDMA 线程通知主线程同步完成：

```
RDMA 线程 (Core N)          主线程 (Core 0)
     |                            |
     |  1. 完成同步                |
     |  2. g_sync_state = READY    |
     |  3. write(eventfd, 1)       |
     |--------------------------->|
     |                            | 4. io_uring 检测到 eventfd 可读
     |                            | 5. 读取通知值
     |                            | 6. 回放积压队列
```

**关键特性**：eventfd 的通知不会丢失。即使主线程还没有注册 eventfd 到 io_uring，只要 eventfd 被写入，计数器就会保留值，等待读取。

#### 3.2.3 eventfd 与初始化时序

在我们的 Bug 中，eventfd 的通知机制本身没有问题。问题在于：**状态被重置为 IDLE 后，RDMA 线程的通知已经没意义了**。

这揭示了一个重要的设计原则：**事件通知机制的有效性，依赖于状态的一致性**。如果状态被意外修改，通知再及时也没用。

### 3.3 初始化时序：被忽视的竞态条件

#### 3.3.1 问题的本质

这个 Bug 的核心是**初始化时序问题**（Initialization Order Fiasco）。

在 v3.0 架构中，`slave_sync_init()` 有两个职责：
1. 创建 eventfd
2. 初始化状态为 IDLE

而 `start_slave_sync()` 的职责是：
1. 创建 RDMA 线程
2. 设置状态为 SYNCING

问题在于：**这两个函数的调用顺序错了**。

#### 3.3.2 为什么这个问题很难发现？

初始化时序问题有几个特点，导致它很难被发现：

1. **条件触发**：只在配置了自动同步时出现，手动触发同步不会触发
2. **日志误导**：状态设置日志看起来正常，只是被后续的初始化覆盖了
3. **时序窗口短**：从设置 SYNCING 到被重置为 IDLE，时间窗口很短（几毫秒）
4. **不崩溃**：不会段错误，不会死锁，只是行为不符合预期

#### 3.3.3 防御性编程

修复这类问题的关键是**防御性编程**：

1. **幂等性设计**：`slave_sync_init()` 应该可以安全地多次调用
2. **状态检查**：修改状态前，先检查当前状态是否允许修改
3. **明确职责**：初始化函数只做初始化，不要修改运行时状态

修复后的 `slave_sync_init()`：

```c
int slave_sync_init(void) {
    /* 避免重复初始化 */
    if (g_event_fd >= 0) {
        return g_event_fd;
    }

    /* 创建 eventfd */
    g_event_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (g_event_fd < 0) {
        return -1;
    }

    /* 初始化积压队列 */
    g_backlog.head = NULL;
    g_backlog.tail = NULL;
    g_backlog.count = 0;

    /* 只有初始状态才设置为 IDLE */
    if (g_sync_state == SLAVE_STATE_IDLE) {
        g_sync_state = SLAVE_STATE_IDLE;
    }

    return g_event_fd;
}
```

---

## 四、解决篇：代码与架构修复

### 4.1 修复方案概述

修复分为三个层面：

1. **调整初始化顺序**：确保 eventfd 在 RDMA 线程启动前创建
2. **防御性编程**：`slave_sync_init()` 检查是否已初始化，避免覆盖状态
3. **明确职责分离**：`slave_sync_init()` 只负责初始化，`start_slave_sync()` 只负责启动同步

### 4.2 代码实现

#### 4.2.1 调整后的 main() 函数

```c
/* main() 函数中的启动顺序 */

/* 4. 初始化同步模块（RDMA 主从复制） */
if (sync_module_init() < 0) {
    kvs_logError("[main] 同步模块初始化失败\n");
    return -1;
}

/* 5. 如果是从节点且配置了主节点，自动启动存量同步
 *
 * 【v3.0 架构调整】先初始化 slave_sync，再启动同步
 *
 * 原因：slave_sync_init() 创建 eventfd，用于 RDMA 线程通知主线程。
 * 如果先启动同步，RDMA 线程可能在 eventfd 创建前完成，导致通知丢失，
 * 积压队列无法回放。
 */
if (g_config.replica_mode == REPLICA_MODE_SLAVE &&
    g_config.master_host[0] != '\0') {

    /* 先初始化从节点同步系统（创建 eventfd） */
    extern int slave_sync_init(void);
    int event_fd = slave_sync_init();
    if (event_fd < 0) {
        kvs_logError("[main] 从节点同步系统初始化失败\n");
        return -1;
    }
    kvs_logInfo("[main] 从节点同步系统初始化完成，event_fd=%d\n", event_fd);

    /* 再启动存量同步（创建 RDMA 线程） */
    extern int start_slave_sync(void);
    if (start_slave_sync() < 0) {
        kvs_logError("[main] 自动同步启动失败\n");
    }
}

/* 6. 启动网络服务 */
proactor_start(port, kvs_protocol);
```

#### 4.2.2 防御性的 slave_sync_init()

```c
/* 初始化从节点同步系统 */
int slave_sync_init(void) {
    /* 【v3.0 修复】避免重复创建 eventfd
     * 如果已经初始化过，直接返回已有的 fd
     */
    if (g_event_fd >= 0) {
        kvs_logInfo("[Slave Sync] eventfd=%d 已存在，跳过重复初始化\n", g_event_fd);
        return g_event_fd;
    }

    /* 创建 eventfd */
    g_event_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (g_event_fd < 0) {
        kvs_logError("slave_sync_init: eventfd 创建失败: %s\n", strerror(errno));
        return -1;
    }

    /* 初始化积压队列 */
    g_backlog.head = NULL;
    g_backlog.tail = NULL;
    g_backlog.count = 0;

    /* 只有初始状态为 IDLE 时才保持 IDLE，否则不覆盖 */
    if (g_sync_state == SLAVE_STATE_IDLE) {
        g_sync_state = SLAVE_STATE_IDLE;
    } else {
        kvs_logInfo("[Slave Sync] 状态已经是 %d，保持现有状态不重置\n", g_sync_state);
    }

    kvs_logInfo("[Slave Sync] 初始化完成，event_fd=%d, 当前状态=%d\n",
                g_event_fd, g_sync_state);
    return g_event_fd;
}
```

#### 4.2.3 proactor_start() 中的适配

```c
/* 初始化从节点同步系统（如果是从节点） */
if (g_config.replica_mode == REPLICA_MODE_SLAVE) {
    extern int slave_sync_get_eventfd(void);
    g_event_fd = slave_sync_get_eventfd();

    if (g_event_fd < 0) {
        /* 尚未初始化，进行初始化 */
        extern int slave_sync_init(void);
        g_event_fd = slave_sync_init();
        kvs_logInfo("Proactor: 在 proactor_start 中初始化 eventfd=%d", g_event_fd);
    } else {
        kvs_logInfo("Proactor: 检测到 eventfd=%d 已初始化，直接注册到 io_uring", g_event_fd);
    }

    if (g_event_fd >= 0) {
        /* 创建 eventfd 对应的 conn 结构 */
        g_event_conn = kvs_calloc(1, sizeof(struct conn));
        if (g_event_conn) {
            g_event_conn->fd = g_event_fd;
            g_event_conn->state = ST_RECV;
            g_event_conn->rlen = 0;
            /* 注册 eventfd 到 io_uring */
            post_read_eventfd(&g_ring, g_event_fd, &g_event_buf);
            kvs_logInfo("Proactor: eventfd=%d 已注册到 io_uring", g_event_fd);
        }
    }
}
```

### 4.3 修复验证

重新编译后，测试日志：

```
[2026-03-04 17:30:15] [INFO] [main] 从节点同步系统初始化完成，event_fd=10
[2026-03-04 17:30:15] [INFO] [Slave Sync] 状态设置为 SYNCING (地址: 0x7f8b2c00a000, 值: 1)
[2026-03-04 17:30:15] [INFO] [kvs_protocol SLAVE] sync_state=1 (IDLE=0, SYNCING=1, READY=2)
[2026-03-04 17:30:15] [INFO] [kvs_protocol SYNCING] 命令: 'ASET', is_write=1, argc=3
[2026-03-04 17:30:15] [INFO] [kvs_protocol SYNCING] 检测到写命令 'ASET'，准备入队
[2026-03-04 17:30:15] [INFO] [kvs_protocol SYNCING] 写命令 'ASET' 已入积压队列，返回 QUEUED
```

**验证通过**：
- 状态正确：`sync_state=1`（SYNCING）
- 命令入队：`ASET` 已入积压队列
- 响应正确：返回 `+QUEUED`

---

## 五、反思篇：给其他开发者的启示

### 5.1 多线程 Debug 的方法论

这次排查经历让我总结了一些多线程 Debug 的方法论：

#### 5.1.1 日志是最好的调试器

在多线程环境下，GDB 单步调试往往不现实（会改变时序）。**详细的日志**是最好的调试工具。

关键日志应该包含：
- **时间戳**：精确到毫秒
- **线程标识**：哪个线程执行的操作
- **变量值和地址**：确认操作的是同一个变量
- **状态流转**：状态变化的前后值

#### 5.1.2 从现象到本质的排查路径

```
现象: 返回 +OK 而不是 +QUEUED
    ↓
怀疑: 状态判断逻辑错误
    ↓
验证: 加日志，发现 sync_state=0（不是 SYNCING）
    ↓
怀疑: 内存可见性问题
    ↓
验证: 加内存屏障，问题依旧
    ↓
怀疑: 变量地址不同（重复定义）
    ↓
验证: 打印地址，发现是同一个地址
    ↓
关键发现: 同一个地址，写入=1，读取=0
    ↓
结论: 有其他代码在"偷改"变量
    ↓
验证: grep 搜索，找到 slave_sync_init()
    ↓
根因: 初始化顺序错误
```

#### 5.1.3 不要过早优化，先确保正确

在排查过程中，我曾一度想优化内存屏障的使用，比如用更细粒度的屏障代替 Full Barrier。但事实证明，**问题的根源根本不是内存屏障**。

这提醒我们：**不要过早优化，先确保逻辑正确**。

### 5.2 状态机设计的最佳实践

#### 5.2.1 状态转换应该显式且可追踪

```c
/* 好的实践：状态转换函数 */
void slave_sync_set_state(int new_state) {
    kvs_logInfo("[State] %d -> %d\n", g_sync_state, new_state);
    g_sync_state = new_state;
    __sync_synchronize();  // 内存屏障
}
```

#### 5.2.2 避免隐式状态重置

```c
/* 坏的实践：初始化函数修改运行时状态 */
void init() {
    state = IDLE;  // 可能覆盖已有的状态！
}

/* 好的实践：初始化函数只初始化 */
void init() {
    if (already_initialized()) return;
    // 只做一次性初始化
}
```

#### 5.2.3 幂等性设计

所有初始化函数都应该支持**幂等调用**：多次调用和一次调用效果相同。

```c
int init(void) {
    if (initialized) return 0;  // 幂等性检查
    // 执行初始化
    initialized = 1;
    return 0;
}
```

### 5.3 初始化顺序的重要性

#### 5.3.1 依赖关系图

在设计阶段，画出模块间的依赖关系图：

```
eventfd 创建 -> RDMA 线程启动 -> 状态设置 SYNCING
                    ↓
              通知 eventfd
                    ↓
            io_uring 注册 eventfd
```

#### 5.3.2 启动顺序检查清单

对于多线程系统，建议有一个启动顺序检查清单：

1. [ ] 所有共享资源（eventfd、锁、队列）已创建
2. [ ] 所有线程间通信通道已建立
3. [ ] 状态机初始状态已设置
4. [ ] 工作线程已启动
5. [ ] 服务端口已监听

#### 5.3.3 防御性编程原则

1. **检查前置条件**：函数执行前，检查依赖是否满足
2. **不要假设调用顺序**：即使文档说明了调用顺序，代码也应该有保护
3. **快速失败**：如果前置条件不满足，立即报错，不要继续执行

```c
void start_sync(void) {
    if (g_event_fd < 0) {
        kvs_logError("eventfd 未创建，请先调用 slave_sync_init()\n");
        return -1;  // 快速失败
    }
    // 继续执行
}
```

### 5.4 对系统开发者的建议

1. **重视日志**：好的日志可以节省数小时的调试时间
2. **理解底层**：理解 CPU 内存模型、系统调用机制，有助于快速定位问题
3. **代码审查**：这类时序问题很难通过测试发现，代码审查是最有效的手段
4. **文档化设计**：架构设计应该文档化，包括启动顺序、状态流转等

---

## 六、结语

这次 Bug 排查从早上九点持续到下午六点，历时整整一天。表面上看，只是一个初始化顺序的问题；但深挖下去，涉及 CPU 内存模型、eventfd 机制、多线程状态机设计等多个知识点。

最让我印象深刻的是那个瞬间：**同一个内存地址 `0x564854cd6b68`，RDMA 线程写入的值是 1，主线程读取的值却是 0。** 这个诡异的现象打破了我对"内存可见性"的固有认知，也让我意识到：在多线程编程中，**永远不要假设代码的执行顺序**。

希望这篇文章能给你带来一些启发。如果你也在开发多线程系统，欢迎交流讨论。

---

## 附录

### A. 项目信息

- **项目**: [Kedis](https://github.com/bitborne/Kedis)
- **语言**: C
- **特性**: 基于 RDMA 的高性能 KV 存储系统
- **架构**: 双 Channel 主从同步（io_uring + RDMA）

### B. 关键代码文件

- [`src/core/slave_sync.c`](https://github.com/bitborne/Kedis/blob/main/src/core/slave_sync.c) - 从节点同步实现
- [`src/core/kvstore.c`](https://github.com/bitborne/Kedis/blob/main/src/core/kvstore.c) - 主逻辑和状态机
- [`src/network/proactor.c`](https://github.com/bitborne/Kedis/blob/main/src/network/proactor.c) - io_uring 网络层

### C. 相关阅读

1. [Linux eventfd(2) 手册](https://man7.org/linux/man-pages/man2/eventfd.2.html)
2. [Memory Barriers: a Hardware View for Software Hackers](https://www.cl.cam.ac.uk/~pes20/weakmemory/cacm.pdf)
3. [io_uring: 异步 I/O 的未来](https://kernel.dk/io_uring.pdf)

### D. 调试技巧速查表

| 问题 | 排查方法 |
|-----|---------|
| 多线程变量值不一致 | 打印变量地址，确认是同一个变量 |
| 怀疑内存可见性 | 加 `volatile` + 内存屏障，观察是否解决 |
| 状态被意外修改 | `grep` 搜索所有赋值点，检查调用顺序 |
| 时序问题 | 加时间戳日志，观察事件发生的先后顺序 |
| 初始化顺序错误 | 画依赖关系图，明确模块间的依赖 |

---

*如果这篇文章对你有帮助，欢迎在 [GitHub](https://github.com/bitborne/Kedis) 上给项目点个 Star ⭐*
