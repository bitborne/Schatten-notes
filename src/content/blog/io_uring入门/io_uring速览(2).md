# io_uring 详解

  

## 核心结构体分析

  

### io_uring 结构体

这是 io_uring 的主要数据结构，包含对 Submission Queue (SQ) 和 Completion Queue (CQ) 的引用。

- `sq`：指向 Submission Queue 的指针

- `cq`：指向 Completion Queue 的指针

- `ring_fd`：内核分配的文件描述符，用于与内核进行通信

  

### Submission Queue (SQ) - 提交队列

用户态向内核提交 I/O 请求的地方

- `sq.head`：队列头部，由内核维护（表示已处理的请求数）

- `sq.tail`：队列尾部，由用户态维护（表示下一个要提交的请求位置）

- `sq.mask`：用于环形缓冲区的掩码

- `sq.entries`：队列大小

  

### Completion Queue (CQ) - 完成队列

内核将完成的 I/O 请求结果放在这里

- `cq.head`：队列头部，由用户态维护（表示已处理的完成项数）

- `cq.tail`：队列尾部，由内核维护（表示下一个完成项的位置）

- `cq.mask`：环形缓冲区掩码

- `cq.entries`：队列大小

  

### Submission Queue Entry (SQE) - 提交队列条目

用于描述一个 I/O 请求

- `opcode`：操作类型（如 IORING_OP_READ, IORING_OP_WRITE, IORING_OP_ACCEPT 等）

- `fd`：文件描述符

- `addr`：缓冲区地址

- `len`：数据长度

- `user_data`：用户数据，用于关联请求和响应

  

### Completion Queue Entry (CQE) - 完成队列条目

内核返回的 I/O 操作结果

- `user_data`：与对应的 SQE 中的 user_data 相同，用于识别完成事件

- `res`：操作结果（成功时为字节数，失败时为负错误码）

- `flags`：完成标志

  

## mmap 映射机制详解

  

io_uring 使用内存映射(mmap)在用户态和内核态之间共享数据结构，避免系统调用的开销：

  

1. **初始化阶段**：

- 调用 `io_uring_setup()` 系统调用，内核分配 SQ 和 CQ 的环形缓冲区

- 内核返回一个文件描述符(uring_fd)和相关的参数信息

- 用户态调用 `mmap()` 将内核分配的内存区域映射到用户地址空间

  

2. **共享内存布局**：

- 内核将 SQ 和 CQ 的元数据（head、tail 指针）放在一块共享内存区

- 将 SQE 和 CQE 数组放在另一块共享内存区

- 用户态和内核态都能访问这些共享内存，但各自维护不同的指针

  

3. **指针管理**：

- 用户态只修改 SQ.tail（提交请求）和 CQ.head（处理完成）

- 内核只修改 SQ.head（处理请求）和 CQ.tail（提交完成）

- 这种分工避免了锁竞争，提高了性能

  

## 代码中 io_uring 调用流程分析

  

### 1. 初始化阶段

```c

struct io_uring ring;

io_uring_queue_init_params(ENTRIES_LENGTH, &ring, &params);

```

- 调用 `io_uring_queue_init_params()` 创建 io_uring 实例

- 内部执行 `io_uring_setup()` 系统调用分配内核资源

- mmap 映射 SQ 和 CQ 相关的共享内存区域到用户空间

- 初始化 ring 结构体，使其指向映射的内存区域

  

### 2. 提交 SQE 阶段（在 set_event_* 函数中）

```c

struct io_uring_sqe *sqe = io_uring_get_sqe(ring);

io_uring_prep_accept(sqe, listenfd, addr, addrlen, flags);

```

- 调用 `io_uring_get_sqe()` 获取一个空闲的 SQE

- 调用 `io_uring_prep_*()` 系列函数填充 SQE（如 `io_uring_prep_accept`、`io_uring_prep_recv`、`io_uring_prep_send`）

- 填充 SQE 的操作码、文件描述符、参数等字段

- 将用户自定义的数据复制到 `sqe->user_data` 中，用于后续识别

  

### 3. 提交到内核阶段

```c

io_uring_submit(&ring);

```

- 调用 `io_uring_submit()` 将用户态准备好但尚未提交的 SQE 提交到内核

- 更新 SQ.tail 指针，通知内核有新的请求待处理

- 内核开始处理队列中的 I/O 请求

  

### 4. 等待完成阶段

```c

io_uring_wait_cqe(&ring, &cqe);

```

- 调用 `io_uring_wait_cqe()` 阻塞等待至少一个完成事件

- 如果 CQ 中已经有完成项则立即返回，否则进入睡眠直到内核产生完成项

- 返回指向 CQE 的指针

  

### 5. 批量处理完成事件阶段

```c

struct io_uring_cqe* cqes[128];

int nready = io_uring_peek_batch_cqe(&ring, cqes, 128);

```

- 调用 `io_uring_peek_batch_cqe()` 批量获取已完成的 CQE

- 一次性获取最多 128 个完成事件，减少系统调用开销

  

### 6. 处理完成事件

```c

for (int i = 0; i < nready; i++) {

struct conn_info res;

memcpy(&res, &entry->user_data, sizeof(struct conn_info));

// 根据事件类型处理

}

```

- 遍历每个 CQE，从 `user_data` 中获取预先存储的连接信息

- 根据事件类型（EVENT_ACCEPT、EVENT_READ、EVENT_WRITE）处理相应的逻辑

- 根据处理结果可能重新注册新的 I/O 事件

  

### 7. 清理 CQ 阶段

```c

io_uring_cq_advance(&ring, nready);

```

- 调用 `io_uring_cq_advance()` 更新 CQ.head 指针

- 通知内核这些 CQE 已被处理，可以重用

  

整个流程的优势在于：

- 通过 mmap 避免了频繁的系统调用

- 通过批量处理提升了吞吐量

- 通过内核线程直接处理 I/O 操作，减少了上下文切换

  

## 面试级精简回答

  

io_uring 是 Linux 内核提供的一种高性能异步 I/O 框架，其核心原理包括：

  

1. **双队列架构**：包含提交队列(SQ)和完成队列(CQ)，用户态提交 I/O 请求到 SQ，内核完成请求后将结果放入 CQ。

  

2. **共享内存机制**：通过 mmap 将内核的 SQ、CQ 结构映射到用户空间，避免频繁系统调用。用户态只修改 SQ.tail 和 CQ.head，内核只修改 SQ.head 和 CQ.tail，无锁并发。

  

3. **零拷贝设计**：用户预先将 SQE 填入共享内存，内核直接从 SQ 中取出请求执行，完成后将 CQE 放入 CQ，实现真正的零拷贝。

  

4. **批量处理**：支持一次提交多个请求，一次获取多个完成结果，减少系统调用开销。

  

5. **内置操作类型**：支持多种 I/O 操作（read/write/accept/send/recv 等），无需额外的 poll 系统调用。

  

(io_uring 独特的无锁共享内存设计使其在高并发场景下性能远超 epoll+线程池的组合)

  

## io_uring 面试题及回答

  

### 面试题 1: 请比较 epoll 和 io_uring 的区别，为什么说 io_uring 性能更好？

  

**回答：**

1. **系统调用开销**：

- epoll：需要多次系统调用（epoll_ctl 添加事件，epoll_wait 等待事件，read/write 数据传输）

- io_uring：通过共享内存减少系统调用，大多数操作在用户态完成

  

2. **数据拷贝**：

- epoll：每次 read/write 都需要系统调用进行数据拷贝

- io_uring：通过预先注册缓冲区（IORING_OP_PROVIDE_BUFFERS）可实现零拷贝

  

3. **异步模型**：

- epoll：本质上是同步 I/O，需要用户线程阻塞等待

- io_uring：真正的异步 I/O，内核线程直接处理 I/O 操作

  

4. **批量处理**：

- epoll：一次只能处理一个事件（除非使用 epoll_pwait2）

- io_uring：可批量提交和获取多个 I/O 操作

  

5. **扩展性**：

- epoll：主要用于网络 I/O

- io_uring：支持文件 I/O、网络 I/O 等多种操作类型

  

### 面试题 2: io_uring 的 SQ 和 CQ 是如何实现无锁并发的？这种设计有什么优势？

  

**回答：**

1. **无锁机制**：

- SQ（提交队列）：用户态修改 `sq.tail`（提交请求），内核修改 `sq.head`（处理请求）

- CQ（完成队列）：内核修改 `cq.tail`（提交完成），用户态修改 `cq.head`（处理完成）

- 读写分离避免了锁竞争

  

2. **内存屏障**：

- 使用内存屏障确保内存访问顺序，防止编译器优化导致的数据不一致

  

3. **环形缓冲区**：

- 使用掩码实现高效的环形缓冲区，避免数组越界检查开销

  

4. **优势**：

- 消除了锁竞争开销，提升并发性能

- 减少上下文切换，用户态和内核态可并行操作

- 更高的吞吐量，特别适合高并发场景

  

这种设计使 io_uring 在高并发 I/O 密集型应用中相比传统 I/O 多路复用技术具有显著性能优势。