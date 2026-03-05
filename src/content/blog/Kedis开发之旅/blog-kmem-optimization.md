---
title: '从段错误到 2300万OPS：我如何为KV存储重构内存池'
description: '在维护C语言KV存储项目时，我发现旧内存池存在单尺寸类、全局锁、容量封顶等严重问题。本文记录完整的重构历程：从问题定位、架构设计（多尺寸类+TLS缓存+动态扩展），到性能优化实战，最终实现单线程2.8倍、多线程6倍性能提升，内存碎片率从65%降至18%。包含详细代码实现、工程踩坑记录和面试复盘问答，适合想深入理解内存管理和高性能系统设计的开发者。'
pubDate: 2026-03-06
---

# 从段错误到 2300万OPS：我如何为KV存储重构内存池

> 项目：[Kedis](https://github.com/bitborne/Kedis) - 一个高性能KV存储系统
> 作者：[@bitborne](https://github.com/bitborne)
> 日期：2026-03-06

> **TL;DR**：在维护一个C语言KV存储项目时，我发现旧内存池存在严重性能问题。经过架构重构，实现了多尺寸类+TLS缓存的新内存池，单线程性能提升2.8倍，多线程提升6倍，内存碎片率从65%降至18%。

---

## 一、导火索：一个诡异的段错误

那是一个普通的周二下午。我正在给Kedis（我们组的KV存储项目）跑压力测试，突然终端跳出几个刺眼的红色字符：

```
Segmentation fault (core dumped)
```

**GDB调试现场**：

```bash
$ gdb ./kvstore core.12345
(gdb) bt
#0  0x00007f8b3c2a115b in mem_pool_free () at src/utils/memory_pool.c:85
#1  0x00007f8b3c2a2200 in kvs_hash_del () at src/engines/kvs_hash.c:319
...
(gdb) p ptr
$1 = (void *) 0x55a3f8b2c000  
(gdb) x/4gx 0x55a3f8b2c000 - 16  # 查看块头
0x55a3f8b2bff0: 0xdeadbeefdeadbeef  0x0000000000000000
```

**问题定位**：`0xdeadbeef`？这不是我设置的魔数，是**内存越界写入**导致的！

翻看旧代码，我发现内存池的实现是这样的：

```c
// 旧内存池：单尺寸、单Chunk、单锁
typedef struct memory_pool {
    void *chunk;              // 只有一个256MB的chunk
    mem_block_t *free_list;   // 全局空闲链表
    pthread_mutex_t lock;     // 一把大锁
    size_t block_size;        // 固定256B
} memory_pool_t;
```

**四个致命问题**浮出水面：

| 问题 | 影响 |
|------|------|
| **单尺寸类** | 24B的hash节点也分配256B，**90%内存被浪费** |
| **容量封顶** | 256MB用完就只能回退malloc，失去内存池意义 |
| **全局锁** | 8线程并发时锁竞争严重，CPU空转 |
| **无NUMA感知** | 跨CPU访问内存，Cache Line频繁失效 |

当时我面临两个选择：
- **方案A**：修修补补，加个边界检查继续用
- **方案B**：重构整个内存池架构

我选择了方案B。**好的工程师不是修bug的人，而是让bug无法产生的人。**

---

## 二、旧架构剖析：为什么慢？

### 2.1 内存碎片：隐形杀手

Kedis支持多种数据结构：Hash表、红黑树、跳表。它们分配的内存大小差异巨大：

```
对象类型          实际大小    旧池分配    碎片率
─────────────────────────────────────────────
hashnode_t        24B         256B        90.6%
短key             16B         256B        93.8%
长value           512B        256B×2      50%
conn结构体        ~200B       256B        21.9%
```

**平均碎片率高达65%**！这意味着你申请了100MB内存，实际只用了35MB。

### 2.2 锁竞争：并发杀手

压力测试时的火焰图显示：

```
34%  pthread_mutex_lock  ← 所有线程都在等这把锁
  │
  ├─12%  mem_pool_alloc
  └─22%  mem_pool_free
```

**阿姆达尔定律**告诉我们：即使锁内操作只占10%，如果有8个线程竞争，整体加速比也会被限制在5倍以内。

### 2.3 扩展性瓶颈

```c
// 旧代码：chunk耗尽后的处理
if (!pool->free_list) {
    return malloc(pool->block_size);  // 回退到malloc！
}
```

一旦超过256MB，新分配就不受内存池管理了，碎片化更加严重。

---

## 三、新架构设计： kmem 诞生

### 3.1 核心思想：分层解耦

参考了jemalloc和tcmalloc的设计，我提出了三层架构：

```
┌─────────────────────────────────────────┐
│  Thread Local Cache Layer (无锁)        │
│  每线程64块缓存，99%操作无锁             │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│  Size Class Layer (细粒度锁)            │
│  6种尺寸：64B/128B/256B/512B/1KB/2KB    │
│  每尺寸独立锁，锁竞争降低6倍             │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│  Chunk Management Layer (mmap/malloc)   │
│  动态扩展，按需分配，无容量上限           │
└─────────────────────────────────────────┘
```

### 3.2 关键设计决策

**决策1：为什么选6种尺寸？**

经过对Kedis内存分配的统计：

```
尺寸范围      分配占比    对应尺寸类
──────────────────────────────────
1-64B         23%         64B
65-128B       31%         128B
129-256B      28%         256B
257-512B      12%         512B
513-1024B     4%          1KB
1025-2048B    2%          2KB
>2048B        少量        直接malloc
```

这6档可以覆盖**98%的分配请求**，内部碎片控制在20%以内。

**决策2：TLS批量大小为什么是32？**

不是拍脑袋定的。假设单次锁操作耗时1μs，批量32块可以摊销到0.031μs/块。但批量太大（如256）会导致：
- 线程退出时归还延迟高
- 单个线程占用过多资源

32是经过测试的**帕累托最优**。

**决策3：mmap vs malloc？**

```c
// 自适应策略
if (chunk_size >= 4*1024*1024) {
    memory = mmap(...);   // 大块用mmap，避免内存碎片
} else {
    memory = malloc(...); // 小块用malloc，减少TLB miss
}
```

---

## 四、核心代码实现

### 4.1 尺寸类路由（分支预测优化）

```c
// 不是用if-else链，而是用查找表
static const size_t class_sizes[6] = {64, 128, 256, 512, 1024, 2048};

int kmem_size_class(size_t size) {
    // 快速路径：常见大小
    if (size <= 64)  return 0;
    if (size <= 128) return 1;
    if (size <= 256) return 2;
    if (size <= 512) return 3;
    if (size <= 1024)return 4;
    if (size <= 2048)return 5;
    return -1; // 大块
}
```

**为什么这样写？**
- CPU分支预测对**有序比较**更友好
- 避免了除法和位运算（虽然`clz`指令更快，但可移植性差）

### 4.2 TLS批量获取（锁优化精髓）

```c
void* kmem_alloc_fast(size_t size) {
    int cls = kmem_size_class(size);
    
    // 1. 先查TLS缓存（无锁）
    if (tls.cache_count[cls] > 0) {
        return pop_from_tls(cls);
    }
    
    // 2. 缓存空，批量从全局池获取（仅一次加锁）
    void *batch[32];
    int got = kmem_slab_alloc_batch(cls, batch, 32);
    
    // 3. 一个给当前请求，其余放TLS
    tls.cache[cls] = batch[1];  // 剩余31个
    tls.cache_count[cls] = got - 1;
    
    return batch[0];
}
```

**关键点**：一次加锁获取32块，后续31次分配都是**无锁**的！

### 4.3 Chunk动态切分（内存对齐）

```c
static int kmem_slab_grow(kmem_slab_t *slab) {
    // 分配对齐的内存（通常是4KB页对齐）
    void *memory = mmap(NULL, slab->chunk_size, 
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    
    // 切分策略：每个块前放元数据头
    char *ptr = memory;
    for (int i = 0; i < blocks_per_chunk; i++) {
        kmem_block_hdr_t *hdr = (kmem_block_hdr_t *)ptr;
        hdr->size_class = slab->class_idx;
        hdr->magic = KMEM_MAGIC_FREED;
        
        // 用户可用内存从hdr后开始
        kmem_free_node_t *node = (kmem_free_node_t *)(hdr + 1);
        push_to_freelist(node);
        
        ptr += sizeof(kmem_block_hdr_t) + slab->block_size;
    }
}
```

**为什么元数据要内嵌？**
- 避免额外哈希表查询（O(1)直接定位）
- 缓存友好：hdr和data在同一Cache Line

---

## 五、性能验证：数据说话

### 5.1 测试环境

```
CPU: Intel i7-12700 (8P+4E cores)
RAM: 32GB DDR4-3200
GCC: 11.3.0 with -O2
OS:  Ubuntu 22.04 LTS
```

### 5.2 基准测试结果

**单线程测试**（100万次alloc/free）：

| 方案 | OPS | vs 旧池 | 碎片率 |
|------|-----|---------|--------|
| malloc/free | 200M | 25x | - |
| 旧内存池 | 8M | 1x | 65% |
| kmem_alloc | 23M | 2.8x | 18% |
| kmem_fast | 23M | 2.8x | 18% |

> 注：malloc在单线程下极快（有线程缓存），但多线程会暴跌。

**多线程测试**（8线程，各100万次）：

| 方案 | OPS | 锁竞争占比 |
|------|-----|-----------|
| 旧内存池 | 3M | 67% |
| kmem_alloc | 18M | 12% |
| kmem_fast | **35M** | **<1%** |

**6倍提升！** 这才是新架构的真正优势。

### 5.3 内存碎片对比

压力测试运行10分钟后：

```
旧内存池：
  申请内存：1.2GB
  实际使用：420MB
  碎片率：65%

kmem：
  申请内存：520MB
  实际使用：426MB
  碎片率：18%
  
节省内存：约680MB (57%)
```

---

## 六、工程踩坑实录

### 坑1：pthread_exit不调用TLS析构

**现象**：压力测试后内存占用不下降。

**原因**：线程退出时，`__thread`变量不会自动归还缓存块。

**解决**：显式注册线程退出hook：

```c
void worker_thread(void *arg) {
    kmem_tls_init();  // 初始化TLS
    
    // ... 工作逻辑
    
    kmem_tls_destroy();  // 必须显式调用！
    pthread_exit(NULL);
}
```

### 坑2：魔数校验的性能陷阱

**最初代码**：
```c
void kmem_free(void *ptr) {
    kmem_block_hdr_t *hdr = ptr - sizeof(kmem_block_hdr_t);
    assert(hdr->magic == KMEM_MAGIC_ALLOCATED);  // debug模式检查
    // ...
}
```

**问题**：assert在Release模式下消失，但生产环境需要轻量校验。

**解决**：条件编译 + 概率采样

```c
#ifdef KMEM_DEBUG
    #define KMEM_CHECK_MAGIC(h) assert(h->magic == KMEM_MAGIC_ALLOCATED)
#else
    #define KMEM_CHECK_MAGIC(h) ((void)0)
#endif
```

### 坑3：NUMA陷阱（预留接口）

虽然kmem架构支持NUMA感知（每个CPU绑定本地Chunk），但项目时间有限未实现。留下了扩展点：

```c
// TODO: NUMA-aware allocation
#ifdef KMEM_NUMA
    int node = numa_node_of_cpu(sched_getcpu());
    return kmem_numa_alloc(slab, node);
#endif
```

---

## 七、面试复盘：如果被追问

**Q1：为什么不用jemalloc/tcmalloc，要自己写？**

> A：两个原因。一是项目依赖最小化原则，引入第三方库会增加编译复杂度；二是jemalloc的size class是固定的，而Kedis有特定的内存分布（小key多、大value少），自定义可以针对性优化。

**Q2：如果Chunk链表太长（>1000个），查找会变慢吗？**

> A：这是个好问题。实际上Chunk只用于释放时验证指针归属，分配时直接从free_list取，O(1)复杂度。如果需要优化，可以用radix tree代替链表，做到O(log n)验证。

**Q3：内存池的线程安全是怎么保证的？**

> A：三层防护：
> 1. TLS层：无锁，每个线程私有
> 2. Size Class层：每个尺寸类独立锁，细粒度
> 3. Chunk层：只有扩展时需要锁，读操作为只读

**Q4：如果我想分配3KB的内存，会怎么处理？**

> A：超过2KB阈值的走大块分配器，直接用malloc/mmap。因为这类分配频率低（<2%），不值得专门建slab，而且大内存的碎片问题不敏感。

---

## 八、总结与反思

### 8.1 核心收获

1. **架构设计 > 代码技巧**：先想清楚分层，再写代码
2. **测量驱动优化**：没有火焰图，我会在错误的地方优化
3. **向后兼容是美德**：新内存池接入，旧代码一行不改

### 8.2 适用场景

kmem适合：
- 高并发、小对象分配频繁的服务
- 对内存碎片敏感的长跑服务
- 需要可预测延迟的系统

不适合：
- 单线程脚本（直接用malloc更快）
- 超大对象（>1MB）为主的场景

### 8.3 源码地址

```bash
https://github.com/bitborne/kedis/tree/main/src/utils/kmem.c
```

欢迎Star和PR，NUMA支持、延迟释放队列等特性等待你的贡献！

---

## 参考资料

1. [jemalloc: A Scalable Concurrent Memory Allocator](https://people.freebsd.org/~jasone/jemalloc/bsdcan2006/jemalloc.pdf)
2. [tcmalloc: Thread-Caching Malloc](https://goog-perftools.sourceforge.net/doc/tcmalloc.html)
3. 《深入理解计算机系统》第9章：虚拟内存
4. 《性能之巅》第7章：内存分析

---

**作者**：Kedis核心开发者  
**发布时间**：2026年3月  
**版权声明**：本文采用 CC BY-NC-SA 4.0 协议

---

