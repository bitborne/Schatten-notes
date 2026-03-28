---
title: 'Idle Page 双模式监控设计与实现'
description: 'Idle Page Monitor 的双模式监控架构设计，支持 SO 代码段静态监控与堆内存动态分配监控的编译时模式选择。'
pubDate: '2026-03-28'
---

# Idle Page 双模式监控设计与实现

## 1. 设计背景：从单一目标到多维度监控

在 Idle Page Monitor 的初始实现中，监控目标是通过 `ProcMapsParser::find_so_regions()` 从 `/proc/self/maps` 中静态解析的 SO 代码段。这种设计的局限性在文档第一部分已经分析：实际监控的是 `base.apk` 的 r-xp/rw-p 区域，而非真正需要关注的堆内存热态。

要实现堆内存监控，面临两个核心问题：

1. **目标来源不同**：SO 代码段是静态已知的（启动时从 maps 解析），而堆内存是动态分配的（需要在 malloc/mmap 钩子中捕获）
2. **日志语义不同**：SO 区域需要知道代码/数据段的归属（如 `r-xp(libdemo_so.so)`），而堆内存只需要标记为 `(heap)`

最初的设想是运行时动态切换模式，但经过评估后改为**编译时模式选择**。决策依据如下：

| 维度 | 运行时切换 | 编译时选择 |
|------|-----------|-----------|
| 代码复杂度 | 需要状态机维护，易引入竞态条件 | 模式判断仅在初始化时一次 |
| 性能开销 | track_allocation 每次调用都需判断模式 | SO 模式下 track_allocation 直接返回，零开销 |
| 使用场景 | 同一进程需要同时监控 SO 和堆 | 两种监控目标独立的分析场景 |
| 调试清晰度 | 日志混合，需额外标记区分来源 | 单一语义，分析脚本易于处理 |

最终选择编译时确定模式，两种模式独立工作不混合。

---

## 2. 模式定义与接口设计

### 2.1 枚举定义

```cpp
enum class MonitorMode : uint8_t {
    SO_CODE_SECTIONS = 0,   // 监控SO代码段，日志显示 权限(文件名)
    HEAP_ALLOCATIONS = 1    // 监控堆内存，日志显示 (heap)
};
```

使用 `uint8_t` 作为底层类型，确保内存布局紧凑（C 接口传递时直接用 `int` 转换）。

### 2.2 初始化接口修改

```cpp
bool init(MonitorMode mode, const char* so_name, const char* log_path, int initial_interval_ms = 100);
```

- `mode`: 编译时确定的监控模式
- `so_name`: 仅在 `SO_CODE_SECTIONS` 模式下使用，指定目标 SO 文件名
- `log_path`: 日志输出路径（`mem_visit.log`）

C 接口保持简单的 `int` 参数：

```cpp
extern "C" bool idle_page_monitor_init(int mode, const char* so_name, const char* log_path);
```

---

## 3. 初始化路径的模式分化

### 3.1 SO 代码段模式

```cpp
if (mode_ == MonitorMode::SO_CODE_SECTIONS) {
    // SO模式：从 maps 加载 SO 区域
    if (!ProcMapsParser::find_so_regions(so_name_.c_str(), target_regions_)) {
        IDLE_LOGE("Failed to find SO regions for %s", so_name_.c_str());
        return false;
    }
}
```

`find_so_regions` 的实现包含一个关键的 fallback 逻辑：当在 maps 中找不到指定的 SO 文件时，会尝试匹配 `base.apk` 的可执行区域。这在 Android APK 场景下是必需的，因为 SO 可能是从 APK 直接加载的：

```cpp
// fallback: 匹配 base.apk 的 r-xp 和 rw-p 区域
if (regions.empty() && strstr(so_name, "demo_so")) {
    if (strstr(line, "base.apk") && (strstr(line, "r-xp") || strstr(line, "rw-p"))) {
        regions.push_back(region);
    }
}
```

### 3.2 堆内存模式

堆模式下不预加载任何区域，`target_regions_` 保持为空直到运行时通过 `track_allocation` 动态添加：

```cpp
// 堆模式：不需要预加载区域，由 track_allocation 动态添加
```

这种设计确保两种模式的初始化路径清晰分离，SO 模式下不会因为缺少堆分配而报错，堆模式下也不会误加载 SO 区域。

---

## 4. 动态跟踪的隔离设计

### 4.1 track_allocation 的模式守卫

堆分配跟踪由 Hook 层在 `my_malloc` / `my_mmap` 中调用：

```cpp
void* my_malloc(size_t size) {
    BYTEHOOK_STACK_SCOPE();
    void* result = BYTEHOOK_CALL_PREV(my_malloc, size);

    if (result && size > 0) {
        idle_page_track_allocation(result, size);
    }
    return result;
}
```

为避免 SO 模式下不必要的开销，`track_allocation` 在入口处即进行模式判断：

```cpp
void IdlePageMonitor::track_allocation(uintptr_t addr, size_t size, uint32_t flags) {
    // SO 模式下不跟踪堆内存分配
    if (mode_ == MonitorMode::SO_CODE_SECTIONS) {
        return;  // 零开销：直接返回，不进入任务队列逻辑
    }
    // ... 堆跟踪逻辑
}
```

这个 early return 确保了 SO 模式下的 Hook 调用路径最短，不会因为未使用的功能引入额外开销。

### 4.2 异步任务队列

堆分配通过无锁任务队列（SPSC）异步提交，避免在 Hook 上下文中执行耗时操作：

```cpp
SampleTask task;
task.type = TaskType::ADD_REGION;
task.region_start = page_start;
task.region_end = page_end;

// 非阻塞入队，队列满时丢弃
if (!task_queue_.enqueue(task)) {
    IDLE_LOGD("Task queue full, dropping ADD_REGION");
}
```

队列容量为 256，对于常规分配速率足够，极端压力下允许丢包而非阻塞。

### 4.3 区域去重

工作线程处理 `ADD_REGION` 任务时，会检查区域是否已存在：

```cpp
bool IdlePageMonitor::region_exists(uintptr_t start, uintptr_t end) const {
    for (const auto& r : target_regions_) {
        if (r.start == start && r.end == end) return true;
        if (start < r.end && end > r.start) return true;  // 部分重叠
    }
    return false;
}
```

去重检查在 `track_allocation`（入队前）和 `handle_add_region`（出队后）各执行一次，形成双保险。

---

## 5. 日志格式的差异化设计

### 5.1 设计目标

- SO 模式：需要识别代码段 vs 数据段，且需要知道归属哪个 SO 文件
- 堆模式：只需要知道这是堆内存，无需区分来源

### 5.2 实现细节

```cpp
// 写入日志 - 根据模式选择显示格式
const char* region_label;
char label_buffer[128];

if (mode_ == MonitorMode::HEAP_ALLOCATIONS) {
    // 堆模式：直接使用 region.name（已预设为 "heap"）
    region_label = !region.name.empty() ? region.name.c_str() : region.perms;
} else {
    // SO模式：构造 权限(文件名) 格式
    const char* name = region.name.empty() ? "" : region.name.c_str();
    const char* last_slash = strrchr(name, '/');
    const char* filename = last_slash ? last_slash + 1 : name;  // 去除路径
    snprintf(label_buffer, sizeof(label_buffer), "%s(%s)", region.perms, filename);
    region_label = label_buffer;
}

// 统一格式输出
snprintf(log_buffer_ + log_offset_, LOG_BUFFER_SIZE - log_offset_,
         "%llu,%llu,0x%llx,%llu,%d,(%s)\n",
         timestamp, current_sequence_, addr, pfn, accessed_status, region_label);
```

### 5.3 输出示例

SO 模式：
```
1711363200100000,0,0x7b0bd0e17000,1234567,1,(r-xp(base.apk))
1711363200100000,0,0x7b0bd0e1a000,1234568,0,(rw-p(base.apk))
```

堆模式：
```
1711363200100000,0,0x7b0c00000000,2345678,1,(heap)
1711363200100000,0,0x7b0c00001000,2345679,1,(heap)
```

括号内的标签使得后续分析脚本可以通过正则简单提取：`\(([^)]+)\)`。

---

## 6. 配置与使用

### 6.1 模式切换

在 `so2-hook.cpp` 中修改初始化参数：

```cpp
// 模式选择：
//   0 = SO_CODE_SECTIONS (监控SO代码段，日志显示 权限(文件名))
//   1 = HEAP_ALLOCATIONS (监控堆内存，日志显示 (heap))
auto mode = idle_page::IdlePageMonitor::MonitorMode::HEAP_ALLOCATIONS;

if (idle_page::IdlePageMonitor::instance().init(mode, "libdemo_so.so", visit_log_path, 100)) {
    LOGI("IdlePageMonitor initialized");
}
```

### 6.2 启动流程

无论哪种模式，启动流程统一：

```cpp
IdlePageMonitor::instance().init(mode, so_name, log_path, interval_ms);
// ...
IdlePageMonitor::instance().start();  // 启动定时器 + 工作线程
```

SO 模式在 `start()` 时从 maps 加载区域，堆模式则等待首次分配触发 `ADD_REGION`。

---

## 7. 关键设计决策回顾

### 7.1 编译时 vs 运行时模式选择

选择编译时的核心原因是**避免混合语义**。如果同一日志中既有 SO 代码段访问、又有堆内存访问，分析时需要额外的上下文来判断每条记录的归属。独立模式使得日志分析脚本更简单，也避免了 SO 模式下不必要的堆跟踪开销。

### 7.2 为什么不在 SO 模式下完全禁用 Hook

虽然 SO 模式下 `track_allocation` 直接返回，但 Hook 本身仍会被触发。这是 ByteHook 的限制：Hook 目标是在初始化时确定的（`bytehook_hook_single`），无法在运行时为特定模式选择性禁用。如果追求极致性能，可以考虑通过宏在编译时完全剔除 Hook 代码，但权衡后认为当前设计的复杂度/收益比更合理。

### 7.3 区域重叠处理策略

`region_exists` 使用简单的重叠检测（`start < r.end && end > r.start`），而非精确合并。这是基于以下假设：

1. 堆分配通常不频繁重叠（free 后重新分配是不同地址）
2. 精确合并需要维护更复杂的数据结构（如区间树）
3. 少量重叠区域的重复采样对结果影响可接受

如果后续发现重叠区域过多影响性能，可以考虑实现区间合并优化。

---

## 8. 后续优化方向

1. **动态频率调整**：当前已实现基于访问比例的自适应采样率（`timer_.auto_adjust_rate()`），但阈值参数（10% / 1%）可能需要根据实际场景调优

2. **区域生命周期管理**：当前 `untrack_allocation` 为空实现，只添加不删除。对于长期运行的进程，可能需要实现 LRU 淘汰或显式 free/munmap 跟踪

3. **多线程 PFN 查询优化**：`do_sample_start_all` / `do_sample_end_all` 当前是单线程顺序处理，CPU 核心充足时可以考虑并行化

---

## 9. 文件清单

```
app/src/main/cpp/
├── idle_page_monitor.h/cpp    # 主监控类（双模式支持）
├── idle_page_task.h/cpp       # 任务队列（ADD_REGION 任务类型）
└── so2-hook.cpp               # 模式配置入口（第 95 行）
```

---

## 10. 运行观察：实际现象与分析

本节记录系统实际运行后的观察结果，以及对这些现象的技术分析。

### 10.1 双日志时间戳对齐

**观察现象**：
`mem_visit.log` 和 `mem_reg.log` 的时间戳可以在同一基准线上对比。

**实现机制**：
两个日志使用完全相同的时间戳获取函数，基于 `CLOCK_MONOTONIC`：

```cpp
// log_hooks.cpp (mem_reg.log)
static uint64_t get_timestamp_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
}

// idle_page_monitor.cpp (mem_visit.log)
uint64_t IdlePageMonitor::get_timestamp_us() {
    using namespace std::chrono;
    return duration_cast<microseconds>(
        steady_clock::now().time_since_epoch()).count();
}
```

两者都使用 `std::chrono::steady_clock`，底层对应 `CLOCK_MONOTONIC`，确保：
- 不受系统时间调整影响
- 两个日志的时间戳具有严格的可比性
- 可以精确计算"分配→首次访问"的时间间隔

### 10.2 地址空间包含关系

**观察现象**：
`mem_visit.log` 中采样的页地址，包含于 `mem_reg.log` 记录的内存分配/释放地址范围内。

**形成机制**：

1. 堆分配时，`track_allocation` 将地址通过任务队列异步提交：

```cpp
void* my_malloc(size_t size) {
    void* result = BYTEHOOK_CALL_PREV(my_malloc, size);

    // 记录到 mem_reg.log
    fast_write_log("%lu,%d,%p,%zu,%zu,...", get_timestamp_us(), ...);

    // 同时提交给 IdlePageMonitor
    if (result) {
        idle_page::IdlePageMonitor::instance().track_allocation(
            reinterpret_cast<uintptr_t>(result), malloc_usable_size(result));
    }
    return result;
}
```

2. `track_allocation` 将页面对齐后的区域添加到监控列表：

```cpp
void IdlePageMonitor::track_allocation(uintptr_t addr, size_t size, uint32_t flags) {
    // 页对齐处理
    uintptr_t page_start = addr & ~0xFFFULL;
    uintptr_t page_end = (addr + size + 4095) & ~0xFFFULL;

    SampleTask task;
    task.type = TaskType::ADD_REGION;
    task.region_start = page_start;
    task.region_end = page_end;
    // ...
    task_queue_.enqueue(task);
}
```

3. 采样时，监控区域被纳入 `page_idle/bitmap` 的操作范围，因此采样地址必然来源于已记录的分配地址。

### 10.3 PFN = 0 现象与延迟分配机制

**观察现象**：
大量堆内存页在采样时 PFN 字段显示为 0，同时 `accessed` 字段为 -1。

**根本原因：Demand Paging（延迟分配）**

| 分配类型 | 现象 | 物理页何时分配 |
|---------|------|---------------|
| 用户空间 malloc | 仅扩展 VMA，返回虚拟地址，PTE 未建立或指向零页 | 首次访问时（触发 Page Fault） |
| 内核 kmalloc | 通常立即分配（GFP_KERNEL） | 分配时即有 PFN |
| mmap 匿名映射 | 同 malloc，首次访问才分配 | 首次访问时 |

**详细分析**：

当 Hook 到 `malloc` 返回时，内核可能仅完成了以下操作：
1. 在进程地址空间中预留虚拟地址范围（VMA）
2. 返回虚拟地址给调用者
3. **尚未** 建立页表项（PTE）到物理页框的映射

此时通过 `/proc/self/pagemap` 查询：
- Present 位（Bit 63） = 0
- PFN 字段无效，`get_pfn()` 返回 0

只有在进程**首次读写**该虚拟地址时，触发 Page Fault，内核才会：
1. 分配物理页框
2. 建立 PTE → PFN 的映射
3. 重新执行被中断的指令

**代码层面的体现**：

```cpp
// MmapPagemap::get_pfn 读取 pagemap 条目
uint64_t entry;
pread(fd_, &entry, sizeof(entry), offset);

if (!(entry & PAGE_PRESENT)) {
    // Present 位为 0，PFN 无效
    return 0;
}
return entry & PFN_MASK;
```

日志记录逻辑（idle_page_monitor.cpp）：

```cpp
uint64_t pfn = pagemap_.get_pfn(addr);
int accessed_status = 0;

if (pfn != 0) {
    bool was_accessed = page_idle_.is_accessed(pfn);
    accessed_status = was_accessed ? 1 : 0;
} else {
    accessed_status = -1;  // unknown，表示页未驻留
}

// 日志格式：timestamp,sequence,vaddr,pfn,accessed,(region)
// 当 pfn=0 时，accessed=-1
```

**后续可参考的策略**：

1. **延迟采样**：对于新分配的区域，等待一段时间（如 100ms）后再进行首次采样，给 Demand Paging 留出时间
2. **预触摸（Pre-fault）**：在添加监控区域前，对页面进行一次只读访问强制建立映射（但会干扰热态统计的准确性）
3. **区分未驻留与空闲**：当前实现将 pfn=0 且 accessed=-1 作为"未驻留"标记，在分析时可以与"已驻留但 idle"（pfn>0, accessed=0）区分开来

---

*文档版本: 2026-03-28*
*代码状态: 双模式功能完成，编译时通过 `MonitorMode` 选择*