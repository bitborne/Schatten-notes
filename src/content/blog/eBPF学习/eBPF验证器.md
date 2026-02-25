---
title: 'eBPF验证器'
description: ''
pubDate: 2026-02-23
---

# eBPF Verifier 实战案例：两个高性能优化故事

## 案例一：数据库监控工具的 1000% 性能提升

### 0. 什么场景遇到了什么问题

**场景**：使用 eBPF 进行数据库活动监控（Database Activity Monitoring），实时捕获 MySQL 等数据库的查询流量。

**问题**：
- 无 SSL 流量：可处理 **5,500 QPS**，无丢包
- **SSL/TLS 流量**：仅 **500-600 QPS** 就出现严重丢包
- CPU 占用飙升至 2+ 核心，ring buffer 快速填满

**根本原因**：SSL 加密数据被拆分为极小的碎片（4-40 字节），每个碎片都触发一个 ring buffer 事件，造成 **6000% 的内存开销**。

---

### 1. 问题分析

#### 1.1 数据碎片化的代价

| 项目                      | 数值                      |
| ------------------------- | ------------------------- |
| 单个 SSL 响应碎片         | 4-40 字节（典型 20 字节） |
| 每个事件的元数据开销      | ~200 字节                 |
| 每个事件的 payload 缓冲区 | 1024 字节（固定分配）     |
| **实际占用**              | 1224 字节                 |
| **有效数据占比**          | 1.6%（20/1224）           |

**计算**：100 个碎片 → 100 × 1224 = **122 KB** ring buffer 占用

#### 1.2 显而易见的解决方案：内核端累加

**思路**：在内核中累积小碎片，攒满 1KB 再一次性发送到用户空间。

**预期效果**：100 个碎片 → 1 × 1224 = **1.2 KB**（100 倍减少）

#### 1.3 eBPF Verifier 的阻碍

**累加逻辑需要**：

 ```c
accumulation_buffer[current_offset] = fragment_data;
current_offset += fragment_size;
 ```

**实际代码**：
```c
bpf_probe_read_user(&buffer[offset], size, source_ptr);
```

**Verifier 拒绝理由**：

- Verifier 无法跟踪变量之间的关系
- 它看到 `offset` 最大 1023，`size` 最大 1024
- 最坏情况：1023 + 1024 = 2047 > 1024（缓冲区大小）
- **拒绝**："无法证明内存访问安全"

**这就是经典的 "A + B Problem"**：Verifier 知道 A 的范围，知道 B 的范围，但无法证明 `A + B < C`。

---

### 2. 解决方案

#### 2.1 核心洞察

> 既然 Verifier 看"最坏情况"，那就让最坏情况也安全。

#### 2.2 具体实现：过度分配缓冲区

**不减少使用上限，而是扩大分配空间**：

```c
#define MAX_FLUSH_SIZE 1024    // 实际使用/发送的数据量
#define BUFFER_SIZE 2048       // 分配 2KB（2倍大小）

// Verifier 计算：
// 最坏情况：offset = 1023, size = 1024
// 总和：2047 < 2048 (BUFFER_SIZE) ✅ 通过！
```

**权衡**：
- 内存代价：每个连接多 1KB（10,000 连接 = 10MB）
- 收益：吞吐量从 500 QPS 提升到 5,500+ QPS（**1000% 提升**）

#### 2.3 辅助技巧：位掩码确保索引安全

该掩码确保 `offset` 永远不会超过 `BUFFER_SIZE - 1`，这是验证器可以静态验证的

```c
// 不使用：buffer[offset] = data;
// 使用：
buffer[offset & (BUFFER_SIZE - 1)] = data;
```

**要求**：`BUFFER_SIZE` 必须是 2 的幂（1024, 2048, 4096...）

**实际代码**：

```c
bpf_probe_read_user(&buffer[offset & (BUFFER_SIZE - 1)], size, source_ptr);
```



#### 2.4 累加器结构设计

```
Per-connection accumulator:
├─ Metadata snapshot（只保存一次）
│  ├─ Connection ID, Thread ID, Protocol, Direction
├─ Buffer state
│  └─ Current fill level (0 ~ MAX_FLUSH_SIZE)
└─ Accumulation buffer (2 * MAX_FLUSH_SIZE 字节分配)
```

**刷新策略**：
- 缓冲区满（1KB）时刷新
- 连接上下文变化时刷新（保证数据一致性）
- 连接关闭时刷新

---

### 3. 结果对比

| 指标         | 优化前                       | 优化后                | 改进      |
| ------------ | ---------------------------- | --------------------- | --------- |
| **吞吐量**   | 500-600 QPS                  | 5,500+ QPS            | **1000%** |
| **CPU 使用** | 2+ cores @ 500 QPS           | 1.6 cores @ 5,500 QPS | 更高效    |
| **内存开销** | 无（但浪费 95% ring buffer） | ~20MB（10K 连接）     | 可接受    |
| **丢包率**   | 严重                         | 零                    | 解决      |

---

### 4. 核心教训

> **在 eBPF 中，"正确"不等于"可验证"。你的代码逻辑必须匹配 Verifier 的静态分析能力。**

- Verifier 无法跟踪变量间的关系（如 `offset + size < bound`）
- 解决方案不是更多运行时检查，而是**重构数据结构**
- 有时需要**过度分配**来满足静态证明的要求

---

## 案例二：TC 流量镜像工具的 Verifier 绕过技巧

### 0. 什么场景遇到了什么问题

**场景**：使用 eBPF TC（Traffic Control）程序进行网络流量镜像，捕获 TCP 数据包 payload 并发送到用户态分析。

**问题代码**：
```c
static __always_inline void send_chunk(struct __sk_buff *skb, 
                                       __u32 offset, 
                                       __u32 chunk_len,  // Verifier 认为范围 0~255
                                       int data_offset)
{
    if (chunk_len == 0 || chunk_len > CHUNK_SIZE)  // 运行时检查, 验证器不知道
        return;
    
    // ...
    bpf_skb_load_bytes(skb, data_offset + offset, e->data, chunk_len);
    // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    // ERROR: R4 invalid zero-sized read: u64=[0,255]
}
```

**错误信息**：
```
R4 invalid zero-sized read: u64=[0,255]
processed 563 insns ...
```

**核心矛盾**：
- 人类逻辑：`if (chunk_len == 0) return` 已经排除了 0
- Verifier 逻辑：跨函数调用时丢失范围信息，认为 `chunk_len` 可能是 0

---

### 1. 问题分析

#### 1.1 为什么发送 Header 不报错？

| 操作           | 数据来源                 | 是否需要 `bpf_skb_load_bytes`   |
| -------------- | ------------------------ | ------------------------------- |
| `ip->saddr`    | 结构体字段（已验证指针） | ❌ 直接访问                      |
| `tcp->source`  | 结构体字段（已验证指针） | ❌ 直接访问                      |
| `payload` 内容 | skb 深层数据（可能跨页） | ✅ 必须使用 `bpf_skb_load_bytes` |

**`bpf_skb_load_bytes`** 是特殊辅助函数，Verifier 对其参数有严格要求：
- 第 4 个参数（读取长度）**绝对不能为 0**
- 必须是编译期可证明的常量或范围

#### 1.2 为什么是 255 而不是其他值？

```c
#define CHUNK_SIZE 256
```

**Verifier 的悲观分析**：
- `chunk_len` 是 `__u32` 类型
- 经过 `chunk_len > CHUNK_SIZE` 检查后，Verifier 不确定是否执行了赋值
- 看到 `& 0xFF`（隐式），认为范围是 **0~255**（8 位最大值）

**注意**：256 需要 9 位（`0x100`），但 Verifier 看到 `chunk_len` 可能从减法 `payload_len - offset` 来，那个可能溢出，所以保守地认为最大 255。

#### 1.3 跨函数调用的信息丢失

```c
// 主循环
if (chunk_len == 0) break;  // 这里的检查
send_chunk(skb, offset, chunk_len, data_offset);  // 调用后 Verifier 忘记了这个保证
```

**Verifier 的函数间分析能力有限**，它不会记住"这个 `chunk_len` 已经被检查过不为 0"。

---

### 2. 解决方案

#### 2.1 核心技巧：位运算强制范围

**不依赖运行时检查，而是用位运算让 Verifier 静态推导出范围**：

```c
#pragma unroll
for (int i = 0; i < 1000; i++) {
    __u32 cur_offset = i * CHUNK_SIZE;
    if (cur_offset >= payload_len) break;

    __u32 remaining = payload_len - cur_offset;
    __u32 chunk_len = remaining > CHUNK_SIZE ? CHUNK_SIZE : remaining;

    // 关键技巧：通过位运算强制 Verifier 看到确定范围
    __u32 final_len = ((chunk_len - 1) & 0xFF) + 1;
    // 结果：无论输入是什么，final_len 范围一定是 [1, 256]

    struct packet_event *de = bpf_ringbuf_reserve(&rb, sizeof(*de), 0);
    if (!de) continue;

    // 填充事件数据...
    
    // 现在 Verifier 确定 final_len ∈ [1, 256]，不为零 ✅
    bpf_skb_load_bytes(skb, data_offset + cur_offset, de->data, final_len);
    bpf_ringbuf_submit(de, 0);
}
```

#### 2.2 数学原理（Verifier 视角）

| 步骤 | 表达式          | Verifier 推导的范围           |
| ---- | --------------- | ----------------------------- |
| 输入 | `chunk_len`     | 任意 `__u32`（0~0xFFFFFFFF）  |
| 减 1 | `chunk_len - 1` | 可能下溢，但 Verifier 不 care |
| 掩码 | `& 0xFF`        | **确定为 0~255**              |
| 加 1 | `+ 1`           | **确定为 1~256**              |

**关键**：`& 0xFF` 是位掩码，Verifier **100% 确定**结果不会超过 256。

#### 2.3 与案例一的对比

| 特性              | 案例一（数据库监控）                                   | 案例二（TC 镜像）    |
| ----------------- | ------------------------------------------------------ | -------------------- |
| **核心问题**      | `offset + size` 可能溢出                               | `chunk_len` 可能为零 |
| **Verifier 限制** | 无法证明加法不溢出                                     | 跨函数丢失非零保证   |
| **解决策略**      | **过度分配**（2KB 装 1KB）                             | **位运算强制范围**   |
| **共同点**        | 都不依赖运行时检查，而是重构代码让安全属性**静态可证** |                      |

---

### 3. 核心教训

> **不要试图让 Verifier "理解"你的运行时检查，而是用位运算和代码结构让安全属性"显而易见"。**

- Verifier 是**静态分析器**，它信任**位掩码**、**常量**、**明确的类型转换**
- Verifier **不信任**跨函数的运行时条件判断
- **位运算 > 条件判断**：`& (SIZE-1)` 比 `if (x < SIZE)` 更容易被验证

---

## 两个案例的共性总结

| 原则              | 说明                                                   |
| ----------------- | ------------------------------------------------------ |
| **静态 > 动态**   | Verifier 只认编译期可证明的安全，不认运行时检查        |
| **悲观分析**      | Verifier 假设变量取最坏情况的值                        |
| **重构而非解释**  | 不要试图"解释"代码安全，要重构代码让安全显而易见       |
| **过度分配/限制** | 案例一用 2KB 空间证明 1KB 安全，案例二用位掩码证明非零 |
| **位运算是朋友**  | `& (2^n - 1)` 是告诉 Verifier 范围的最可靠方式         |

**最终哲学**：

> eBPF 编程不是写"正确的代码"，而是写"Verifier 能证明正确的代码"。这是针对静态分析器的编程艺术。