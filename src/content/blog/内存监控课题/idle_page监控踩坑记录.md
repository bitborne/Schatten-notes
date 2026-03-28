---
title: 'Idle Page 监控系统实现文档'
description: '记录 Idle Page Monitor 的设计决策、实现细节和已知问题，涵盖系统架构、核心组件与踩坑经验。'
pubDate: '2026-03-27'
---

# Idle Page 监控系统实现文档

本文档记录 Idle Page Monitor 的设计决策、实现细节和已知问题。

---

## 1. 系统架构

### 1.1 整体结构

```
┌─────────────────────────────────────────────────────────────┐
│  IdlePageMonitor (单例)                                      │
│  ├─ IdlePageTimer    (timerfd + epoll)                     │
│  ├─ TaskQueue        (无锁环形队列)                         │
│  ├─ Worker Thread    (采样任务执行)                         │
│  ├─ MmapPagemap      (PFN 查询)                            │
│  │   ├─ 本地 /proc/self/pagemap                            │
│  │   └─ PFN Helper (socket 回退)                           │
│  ├─ MmapPageIdle     (bitmap 操作)                         │
│  └─ ProcMapsParser   (内存区域解析)                         │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 核心组件说明

| 组件 | 职责 | 关键实现 |
|------|------|----------|
| IdlePageTimer | 高精度定时触发 | timerfd_create + epoll_wait |
| TaskQueue | 任务队列（SPSC） | 无锁环形队列，CAS 操作 head/tail |
| MmapPagemap | 虚拟地址转 PFN | /proc/self/pagemap 或 Helper socket |
| MmapPageIdle | 标记/查询页状态 | /sys/kernel/mm/page_idle/bitmap |

---

## 2. 采样周期设计

### 2.1 双任务模型

每个完整采样周期包含两个任务：

```cpp
// timer 回调
timer_.init(interval_ms, [this]() {
    uint64_t seq = sequence_id_.fetch_add(1);
    
    SampleTask task;
    task.timestamp_us = get_timestamp_us();
    task.sequence_id = seq / 2;  // START 和 END 共享 sequence_id
    
    if (seq % 2 == 0) {
        task.type = TaskType::SAMPLE_START;  // 设置 idle
    } else {
        task.type = TaskType::SAMPLE_END;    // 读取访问状态
    }
    
    task_queue_.enqueue(task);
});
```

- `SAMPLE_START`：将所有监控页的 bitmap bit 设为 1（标记 idle）
- `SAMPLE_END`：读取 bitmap，bit = 0 表示期间被访问过，bit = 1 表示未被访问

sequence_id = seq / 2 的设计使得 START #N 和 END #N 具有相同的标识，便于关联分析。

### 2.2 周期时序

假设 interval_ms = 100：

| 时间 | seq | 任务 | 操作 |
|------|-----|------|------|
| t=0ms | 0 | START #0 | 设置所有页为 idle |
| t=100ms | 1 | END #0 | 读取状态，输出日志 |
| t=100ms | 2 | START #1 | 开始下一周期 |
| t=200ms | 3 | END #1 | 读取状态 |

完整采样周期 = 2 × interval_ms = 200ms

---

## 3. 权限处理

### 3.1 权限需求分析

| 资源 | 文件系统权限 | SELinux | 备注 |
|------|-------------|---------|------|
| `/sys/kernel/mm/page_idle/bitmap` | root:root 0600 | 需要 sysfs 权限 | 可 chmod 666 |
| `/proc/self/pagemap` | root:root 0400 | 需要 root | procfs，chmod失效 |

- 非 root 进程无法直接访问 `/proc/self/pagemap`。
- chmod 可临时使 非 root 进程访问 `bitmap`。

### 3.2 解决方案：PFN Helper

采用进程分离架构：

```
Game Process (untrusted_app)
├─ 可以访问 bitmap（chmod 666 + setenforce 0 后）
└─ 无法访问 pagemap
        │
        │ Unix Domain Socket
        ▼
PFN Helper (root)
└─ 可以访问 /proc/<pid>/pagemap
```

**Helper 协议**：
- 请求：8 字节虚拟地址（uintptr_t）
- 响应：8 字节 PFN（uint64_t），0 表示无效

**启动脚本** (`pre.sh`)：
```bash
adb root
adb shell setenforce 0
adb shell chmod 666 /sys/kernel/mm/page_idle/bitmap
adb shell "/data/local/tmp/pfn_helper $(pidof com.example.demo_so)" &
```

### 3.3 降级处理

当 root 权限不可用时，系统进入降级模式：

```cpp
bool page_idle_available = page_idle_.open();
if (!page_idle_available) {
    // 继续运行，但无法获取访问状态
    // 日志中所有页的 accessed 字段标记为 -1 (unknown)
}
```

---

## 4. 性能优化

### 4.1 Bitmap 缓存块

直接操作 bitmap 文件的问题：
- 每次 set_idle 需要 pread + pwrite（2 次系统调用）
- 1000 个页 = 2000 次系统调用

优化：使用 8KB 缓存块（1024 个 uint64_t，覆盖 65536 个 PFN）

```cpp
class MmapPageIdle {
    static constexpr size_t CACHE_SIZE = 8 * 1024;
    uint8_t cache_[CACHE_SIZE];
    uint64_t cached_block_idx_ = UINT64_MAX;
    bool cache_dirty_ = false;
    
    void load_cache(uint64_t block_idx) {
        if (cached_block_idx_ == block_idx) return;
        if (cache_dirty_) flush_cache();
        pread(fd_, cache_, CACHE_SIZE, block_idx * CACHE_SIZE);
        cached_block_idx_ = block_idx;
    }
};
```

同一缓存块内的 PFN 操作只需一次 pread，缓存刷回时一次 pwrite。

### 4.2 动态频率调整

根据访问比例自动调整采样周期：

```cpp
void auto_adjust_rate(float access_ratio) {
    if (access_ratio > 0.10f) {
        set_rate(SampleRate::FAST);     // 100ms
    } else if (access_ratio < 0.01f) {
        set_rate(SampleRate::SLOW);     // 2000ms
    } else {
        set_rate(SampleRate::MEDIUM);   // 500ms
    }
}
```

| 档位 | 周期 | 条件 |
|------|------|------|
| FAST | 100ms | > 10% 页被访问 |
| MEDIUM | 500ms | 1% - 10% |
| SLOW | 2000ms | < 1% |

定时器间隔调整通过 `timerfd_settime` 在运行期完成。

---

## 5. 监控目标策略

### 5.1 当前实现

代码逻辑：

```cpp
// 尝试查找 libdemo_so.so
ProcMapsParser::find_so_regions("libdemo_so.so", target_regions_);
```

但在 Android APK 加载场景下，`/proc/self/maps` 中不会显示 `libdemo_so.so`，SO 是从 `base.apk` 直接加载的。因此实际走的是 fallback 逻辑：

```cpp
// 回退：匹配 base.apk 的 r-xp（代码段）和 rw-p（数据段）区域
if (regions.empty() && strstr(so_name, "demo_so")) {
    if (strstr(line, "base.apk") && (strstr(line, "r-xp") || strstr(line, "rw-p"))) {
        regions.push_back(region);
    }
}
```

**实际监控范围**：`base.apk` 的 r-xp 和 rw-p 区域。

### 5.2 问题分析

当前监控目标与 mem_reg.log 记录的堆分配地址不重叠：

```
实际监控区域（base.apk）：
7b0bd0e17000-7b0bd0e19000 r-xp ... base.apk
7b0bd0e1a000-7b0bd0e1b000 rw-p ... base.apk

堆分配区域（mem_reg.log）：
7b0c00000000-7b0c00100000 (L3-COOL Config Cache)
7b0d00000000-7b0d00400000 (L4-COLD Resource Packs)
```

代码段（r-xp）的访问模式主要是指令读取，与堆内存的数据访问热态分析目标不匹配。

### 5.3 后续改进方向

1. Hook 拦截：在 `my_malloc` / `my_mmap` 中记录分配地址
2. 动态注册：将分配的地址实时添加到监控列表
3. 分类统计：按热态等级（HOT/WARM/COOL/COLD）分别监控

---

## 6. 日志格式

### 6.1 mem_visit.log

```
# 格式: timestamp_us,sequence,vaddr,pfn,accessed,perms
timestamp_us,sequence,vaddr,pfn,accessed,(perms)
1711363200100000,0,0x7b0c00000000,1234567,1,(rw-p)
1711363200100000,0,0x7b0c00001000,1234568,0,(rw-p)
1711363200200000,1,0x7b0c00000000,1234567,0,(rw-p)
```

| 字段 | 说明 |
|------|------|
| timestamp_us | 微秒级时间戳（CLOCK_MONOTONIC）|
| sequence | 采样周期序号 |
| vaddr | 虚拟地址 |
| pfn | 物理页帧号 |
| accessed | 1=被访问, 0=idle, -1=unknown |
| perms | 内存权限（来自 maps）|

### 6.2 时间戳对齐

使用与 mem_reg.log 相同的时钟源：

```cpp
uint64_t get_timestamp_us() {
    using namespace std::chrono;
    return duration_cast<microseconds>(
        steady_clock::now().time_since_epoch()).count();
}
```

---

## 7. 关键代码片段

### 7.1 无锁任务队列

```cpp
class TaskQueue {
    static constexpr size_t CAPACITY = 256;
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
    SampleTask buffer_[CAPACITY];

public:
    bool enqueue(SampleTask task) {
        size_t tail = tail_.load(std::memory_order_relaxed);
        size_t next = (tail + 1) % CAPACITY;
        if (next == head_.load(std::memory_order_acquire)) {
            return false;  // 满
        }
        buffer_[tail] = task;
        tail_.store(next, std::memory_order_release);
        return true;
    }
    
    bool dequeue(SampleTask& task) {
        size_t head = head_.load(std::memory_order_relaxed);
        if (head == tail_.load(std::memory_order_acquire)) {
            return false;  // 空
        }
        task = buffer_[head];
        head_.store((head + 1) % CAPACITY, std::memory_order_release);
        return true;
    }
};
```

### 7.2 Timerfd + Epoll

```cpp
bool IdlePageTimer::init(int interval_ms, Callback callback) {
    timerfd_ = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    epollfd_ = epoll_create1(EPOLL_CLOEXEC);
    
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = timerfd_;
    epoll_ctl(epollfd_, EPOLL_CTL_ADD, timerfd_, &ev);
    
    // 设置定时器
    struct itimerspec its;
    its.it_value.tv_sec = interval_ms / 1000;
    its.it_value.tv_nsec = (interval_ms % 1000) * 1000000;
    its.it_interval = its.it_value;
    timerfd_settime(timerfd_, 0, &its, nullptr);
    
    // 启动线程
    thread_ = std::thread(&IdlePageTimer::timer_thread, this);
}

void IdlePageTimer::timer_thread() {
    struct epoll_event events[1];
    uint64_t expirations;
    
    while (running_) {
        int nfds = epoll_wait(epollfd_, events, 1, 100);
        if (nfds > 0 && events[0].data.fd == timerfd_) {
            read(timerfd_, &expirations, sizeof(expirations));
            if (callback_) callback_();
        }
    }
}
```

### 7.3 PFN 查询

```cpp
uint64_t MmapPagemap::get_pfn(uintptr_t vaddr) const {
    if (use_helper_ && helper_fd_ >= 0) {
        // 通过 Helper 查询
        send(helper_fd_, &vaddr, sizeof(vaddr), 0);
        uint64_t pfn;
        recv(helper_fd_, &pfn, sizeof(pfn), 0);
        return pfn;
    }
    
    // 本地查询
    uint64_t page_index = vaddr / 4096;
    uint64_t offset = page_index * 8;
    
    uint64_t entry;
    pread(fd_, &entry, sizeof(entry), offset);
    
    if (!(entry & PAGE_PRESENT)) return 0;
    return entry & PFN_MASK;
}
```

---

## 8. 已知问题

### 8.1 监控目标不匹配

当前监控 SO 加载区域，但实际需要监控堆分配区域。需要修改监控目标获取方式。

### 8.2 PFN 重复读取

`do_sample_start_all` 每次采样都重新读取 pagemap，实际上 PFN 在页面不交换的情况下是稳定的。可以复用首次缓存的 PFN 列表。

### 8.3 多区域效率

当前对每个区域单独循环处理，如果区域数量多、每个区域页数少，效率较低。可考虑合并 PFN 列表统一处理。

---

## 9. 文件清单

```
app/src/main/cpp/
├── idle_page_monitor.h/cpp    # 主监控类
├── idle_page_timer.h/cpp      # 高精度定时器
├── idle_page_mmap.h/cpp       # PFN 和 bitmap 操作
├── idle_page_task.h/cpp       # 任务队列
├── idle_page_elf.h/cpp        # ELF 节区解析（未使用）
├── idle_page_log.h            # 日志宏
└── so2-hook.cpp               # 集成点
```

---

## 10. 运行依赖

1. **内核配置**: `CONFIG_IDLE_PAGE_TRACKING=y`
2. **文件权限**: `chmod 666 /sys/kernel/mm/page_idle/bitmap`
3. **SELinux**: `setenforce 0`
4. **PFN Helper**: 必须以 root 运行，目标 PID 作为参数

---

*文档版本: 2026-03-27*
*代码状态: 基础功能完成，监控策略待调整*
