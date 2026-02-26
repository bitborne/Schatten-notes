---
title: 'Ntyco分析笔记'
description: '本文是对开源协程库 Ntyco 的深度源码分析笔记，涵盖了协程架构思想、调度器实现细节以及如何通过 Hook 技术实现“同步编码，异步执行”的魔法。'
pubDate: 2026-02-20
---


# ntyco 源码分析与 ucontext 改造

> Ntyco源码: https://github.com/wangbojing/NtyCo

你好！欢迎来到 ntyco 的世界。

作为一名协程小白，你可能会觉得协程、调度、Hook 这些概念有些抽象。别担心，这篇文档的目的就是带你一步步揭开 ntyco 的神秘面纱。我们会从它的架构设计讲起，然后像读故事一样，顺着最合理的路径把核心源码看一遍。最后，我们会一起动手，用更现代、更易于理解的 `ucontext` 接口，重写 ntyco 的核心部分，并用一个新的例子来验证我们的成果。

准备好了吗？让我们开始吧！

## 1. ntyco 架构思想与核心概念

在深入代码之前，我们先要理解 ntyco 是什么，以及它为了解决什么问题而设计。

**ntyco 是一个基于 C 语言的、用于网络编程的协程库。**

想象一下，你在写一个服务器程序，需要同时处理成千上万个客户端连接。传统的方法是：

*   **多进程**：为每个连接创建一个进程。但进程太“重”了，创建和切换的开销巨大，系统根本扛不住。
*   **多线程**：比进程轻量，但线程切换仍然有内核开销，并且线程间的锁竞争问题会让你头疼不已。
*   **IO 多路复用 (select/poll/epoll)**：性能很高，但代码会变得非常复杂，你需要手动管理每个连接的状态，形成所谓的“回调地狱 (Callback Hell)”。

**协程 (Coroutine)** 提供了一种优雅的解决方案。你可以把协程想象成一个“用户态的轻量级线程”。它有以下特点：

*   **轻量**：创建和销毁一个协程非常快，内存占用很小。你可以轻松创建几十万甚至上百万个。
*   **协作式调度**：协程的切换由代码自己控制（比如调用 `yield`），而不是由操作系统强制抢占。这避免了内核态和用户态的切换开销，也减少了对锁的依赖。
*   **同步编码，异步执行**：你可以用看起来是同步阻塞的方式写代码（如 `recv`, `send`），但实际上底层通过 Hook 技术和调度器，将这些阻塞操作变成了异步的非阻塞调用，从而实现了极高的并发性能。

### ntyco 的三大核心组件

ntyco 的世界主要由这三个角色构成：

1.  **协程 (Coroutine)**: `nty_coroutine` 结构体。它是一个执行单元，包含了自己独立的执行上下文（CPU 寄存器、栈），以及要执行的函数和状态。你可以把它看作一个“任务”。

2.  **调度器 (Scheduler)**: `nty_schedule` 结构体。它是整个协程世界的“大脑”和“驱动核心”。它的职责是：
    *   管理所有的协程。
    *   决定下一个应该运行哪个协程。
    *   当一个协程因为 IO 操作（比如等待网络数据）需要“睡眠”时，调度器会把它放到一个等待队列里。
    *   通过 `epoll` 监听所有“睡眠”协程所等待的 IO 事件。
    *   当 IO 事件发生时（比如网卡收到了数据），调度器会“唤醒”对应的协程，让它继续执行。

3.  **Hook (钩子)**: `nty_socket.c` 中的 `socket`, `recv`, `send` 等函数。这是实现“同步编码，异步执行”魔法的关键。ntyco "劫持" 了这些标准的网络 IO 函数。当你调用 `recv` 时，你调用的不再是 glibc 的原生 `recv`，而是 ntyco 的版本。这个 Hook 后的函数会：
    *   告诉调度器：“我要在这个文件描述符(fd)上等数据，先让我睡一会儿。”
    *   然后主动让出 CPU (`yield`)。
    *   调度器接管控制权，去运行其他协程。
    *   当 `epoll` 通知调度器数据来了，调度器会唤醒这个协-程。
    *   协程醒来后，从 `yield` 的地方继续执行，此时数据已经准备好了，它就可以去真正地读取数据了。

**一句话总结 ntyco 的工作流程**：创建一堆协程来处理任务 -> 协程遇到 IO 阻塞时就 `yield` 让出控制权给调度器 -> 调度器通过 `epoll` 等待 IO 事件 -> 事件发生后，调度器唤醒对应的协程继续执行。

---

## 2. ntyco 核心源码阅读之旅

现在，我们带着上面的架构图，开始代码之旅。阅读源码最好的方式不是逐行去看，而是跟着程序的执行脉络走。

**阅读路径**: `nty_coroutine.h` (数据结构) -> `nty_coroutine.c` (协程创建与切换) -> `nty_schedule.c` (调度器) -> `nty_socket.c` (Hook 与 IO)

### 第一站：定义世界的基石 (`nty_coroutine.h`)

这个头文件定义了我们上面说的两个核心结构体：`nty_coroutine` 和 `nty_schedule`。

*   **`struct _nty_coroutine`**:
    *   `nty_cpu_ctx ctx`: **核心中的核心**。这个结构体保存了协程的 CPU 上下文，即所有关键寄存器的值（比如 `esp` 栈顶指针, `ebp` 栈基址指针, `eip` 指令指针）。协程的切换，本质上就是保存旧协程的 `ctx`，加载新协程的 `ctx`。
    *   `proc_coroutine func`: 协程要执行的函数。
    *   `void *arg`: 传递给协程函数的参数。
    *   `void *stack`: 指向协程自己独享的栈空间。
    *   `nty_coroutine_status status`: 协程当前的状态（新建、就绪、运行、睡眠、退出等）。
    *   `nty_schedule *sched`: 指向它所属的调度器。
    *   `TAILQ_ENTRY(_nty_coroutine) ready_next`: 用于将协程链入调度器的“就绪队列”。

*   **`struct _nty_schedule`**:
    *   `nty_cpu_ctx ctx`: 调度器自己也有一个上下文。当所有协程都“睡眠”时，程序会切换到调度器的上下文来执行 `epoll_wait`。
    *   `void *stack`: 调度器的主栈。
    *   `struct _nty_coroutine *curr_thread`: 指向当前正在运行的协程。
    *   `int poller_fd`: `epoll` 的文件描述符。
    *   `nty_coroutine_queue ready`: **就绪队列**。所有可以立即运行的协程都在这个队列里排队。
    *   `nty_coroutine_rbtree_sleep sleeping`: **睡眠红黑树**。按睡眠时间排序，用于实现 `sleep()` 功能。
    *   `nty_coroutine_rbtree_wait waiting`: **IO 等待红黑树**。按文件描述符 `fd` 排序，用于存放所有等待 IO 的协程。

### 第二站：协程的“创世纪”与“灵魂转移” (`nty_coroutine.c`)

这里实现了协程的创建、切换和销毁。

*   **`nty_coroutine_create()`**:
    1.  获取当前线程的调度器 `sched`。如果不存在，就创建一个新的。
    2.  `calloc` 分配一个 `nty_coroutine` 结构体的内存。
    3.  `posix_memalign` 为协程分配独立的栈空间。这是协程能够独立运行的基础。
    4.  设置协程的初始状态为 `NTY_COROUTINE_STATUS_NEW`，并把它加入调度器的 `ready` 队列。
    5.  **注意**：此时协程只是“已创建”，但里面的函数还没开始执行。

*   **`_exec()`**: 这是一个静态的 trampoline 函数，是所有协程的真正入口。当一个协程首次被调度运行时，它会从这里开始。
    1.  执行用户传入的 `co->func(co->arg)`。
    2.  执行完毕后，将协程状态标记为 `EXITED`。
    3.  调用 `nty_coroutine_yield(co)`，主动让出 CPU，这是它生命周期中的最后一次让出。

*   **`_switch()`**: **魔法的核心**！这是一个用汇编实现的函数。它的功能非常纯粹：
    *   `_switch(new_ctx, cur_ctx)`
    *   把当前 CPU 的所有关键寄存器（`esp`, `ebp`, `ebx` 等）的值，保存到 `cur_ctx` 指向的结构体中。
    *   把 `new_ctx` 结构体中保存的寄存器值，加载到 CPU 的各个寄存器中。
    *   执行 `ret` 指令。`ret` 会把栈顶的值弹出到 `eip` 指令寄存器，CPU 就会跳转到新的 `eip` 地址去执行。而这个 `eip` 正是 `new_ctx` 中保存的。
    *   **就这样，一次上下文切换就完成了！CPU 开始执行另一个协程（或调度器）的代码了。**

*   **`nty_coroutine_resume()`**: 唤醒（或首次运行）一个协程。
    1.  将调度器的 `curr_thread` 指向要被唤醒的协程 `co`。
    2.  调用 `_switch(&co->ctx, &co->sched->ctx)`。这会**保存调度器的上下文**到 `sched->ctx`，并**加载协程的上下文** `co->ctx`。
    3.  CPU 开始执行协程的代码。

*   **`nty_coroutine_yield()`**: 协程主动让出。
    1.  调用 `_switch(&co->sched->ctx, &co->ctx)`。这会**保存当前协程的上下文**到 `co->ctx`，并**加载调度器的上下文** `sched->ctx`。
    2.  CPU 开始执行调度器的代码（通常是从 `nty_coroutine_resume` 的下一行继续）。

### 第三站：运筹帷幄的总指挥 (`nty_schedule.c`)

这里是调度循环 `nty_schedule_run()` 的所在地，是 ntyco 的“发动机”。

*   **`nty_schedule_create()`**: 创建调度器。主要是分配 `nty_schedule` 结构体，创建 `epoll` 实例 (`nty_epoller_create`)，初始化各种队列和红黑树。

*   **`nty_schedule_run()`**: 这是主循环，只要还有未完成的协程，它就会一直运行。
    1.  **处理过期协程**：检查 `sleeping` 红黑树，看有没有 `sleep` 时间到了的协程，如果有，就把它唤醒 (`nty_coroutine_resume`)。
    2.  **处理就绪协程**：遍历 `ready` 队列，依次 `resume` 每一个就绪的协程。协程运行时，可能会因为新的 IO 请求而再次 `yield` 回来。
    3.  **执行 epoll 等待**：如果 `ready` 队列空了（意味着所有协程都在等待 IO 或 sleep），就调用 `nty_schedule_epoll()`。
        *   `nty_schedule_epoll()` 会计算出下一个要超时的 `sleep` 时间，作为 `epoll_wait` 的超时参数。
        *   然后就调用 `epoll_wait` 阻塞住，等待网络事件或超时。
    4.  **处理 IO 事件**：`epoll_wait` 返回后，遍历所有就绪的 `fd`。
        *   根据 `fd` 从 `waiting` 红黑树中找到对应的协程。
        *   将这个协程从 `waiting` 和 `sleeping` 结构中移除，然后 `resume` 它。
    5.  循环回到第 1 步。

### 第四站：偷天换日的魔法师 (`nty_socket.c`)

这里通过 `dlsym` Hook 了标准的 socket 函数。我们以 `recv` 为例。

*   **`recv()` (Hooked version)**:
    1.  检查当前是否存在调度器。如果不存在（说明用户在主线程直接调用），就直接调用原始的 `recv_f` 函数。
    2.  创建一个 `pollfd` 结构，表示我们关心这个 `fd` 上的 `POLLIN` (读) 事件。
    3.  调用 `nty_poll_inner()`。这是关键！
        *   `nty_poll_inner` 会把 `fd` 和关心的事件注册到调度器的 `epoll` 中。
        *   然后，它把当前协程加入到 `waiting` 红黑树，并设置一个超时。
        *   最后，调用 `nty_coroutine_yield(co)`，**当前协程在这里“睡着”了**。
    4.  当调度器因为 `epoll` 事件唤醒这个协程后，代码会从 `yield` 的地方继续执行。
    5.  此时数据已经准备好了，函数会调用原始的 `recv_f` 去读取数据并返回。

`accept`, `send`, `connect` 等函数的 Hook 原理与 `recv` 完全相同，只是关心的事件类型（`POLLIN` 或 `POLLOUT`）和调用的原始函数不同。

至此，ntyco 的核心逻辑我们已经完整地过了一遍。你现在应该明白了，它如何通过 **Coroutine + Scheduler + Hook** 这“三位一体”的架构，巧妙地将复杂的异步 IO 变成了简单的同步写法。

---

## 3. 使用 ucontext 重构核心

ntyco 使用手写的汇编代码 `_switch` 来实现上下文切换，这虽然高效，但有几个缺点：
*   **平台不通用**：需要为 x86, x64, ARM 等不同架构分别实现。
*   **难以理解和维护**：汇编代码对大多数开发者来说都很晦涩。

幸运的是，POSIX 提供了一套标准的 API `ucontext` 来实现同样的功能。它更通用，更易读。现在，我们就用它来替换掉 `_switch` 汇编代码。

`ucontext` 主要涉及四个函数：
*   `getcontext(ucontext_t *ucp)`: 获取当前上下文，并保存在 `ucp` 中。
*   `setcontext(const ucontext_t *ucp)`: 设置当前上下文为 `ucp`，程序会跳转到 `ucp` 所指向的上下文执行，**并且不再返回**。
*   `makecontext(ucontext_t *ucp, void (*func)(), int argc, ...)`: 修改由 `getcontext` 创建的上下文。主要是设置 `ucp` 的入口函数 `func` 和它的栈。当这个 `ucp` 被激活时，`func` 函数就会被执行。
*   `swapcontext(ucontext_t *oucp, ucontext_t *ucp)`: **原子操作**，相当于 `getcontext(oucp)` + `setcontext(ucp)`。它保存当前上下文到 `oucp`，然后激活 `ucp`。这是我们要用来替代 `_switch` 的核心函数。

### `ntyco-ucontext` 精简版实现

下面是一个完整的、使用 `ucontext` 的协程核心实现。你可以把它看作是 `nty_coroutine.c` 的一个现代化改造版本。为了清晰，我将相关的结构体定义和函数实现都放在一起。

```c
/*
 * ntyco-ucontext.h (Conceptual)
 *
 * This is a simplified reimplementation of ntyco's core logic
 * using the ucontext API for better portability and readability.
 */

#include <ucontext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NTY_CO_STACK_SIZE (128 * 1024)

// Forward declarations
typedef struct nty_coroutine_s nty_coroutine_t;
typedef struct nty_schedule_s nty_schedule_t;
typedef void (*nty_proc_f)(void *arg);

// Coroutine Structure
struct nty_coroutine_s {
    ucontext_t ctx;         // ucontext context
    nty_proc_f func;        // The function this coroutine executes
    void *arg;              // Argument for the function
    char *stack;            // Pointer to the coroutine's stack
    size_t stack_size;
    int status;             // e.g., NEW, RUNNING, SLEEPING, EXITED
    nty_schedule_t *sched;  // Pointer to its scheduler
};

// Scheduler Structure
struct nty_schedule_s {
    ucontext_t main_ctx;    // The scheduler's own context
    nty_coroutine_t *running_co; // The currently running coroutine
    // In a full implementation, you'd have ready/waiting queues here.
    // For this example, we simplify to show only the context switching.
};

// The trampoline function that all coroutines start in.
static void _nty_coroutine_entry(void *arg) {
    nty_coroutine_t *co = (nty_coroutine_t *)arg;
    
    // Execute the user's function
    co->func(co->arg);
    
    // Mark as exited and yield back to the scheduler for the last time.
    co->status = -1; // -1 represents EXITED
    
    // This is equivalent to nty_coroutine_yield(co)
    swapcontext(&co->ctx, &co->sched->main_ctx);
}

// Creates a new coroutine
int nty_coroutine_create_ucontext(nty_schedule_t *sched, nty_coroutine_t **co_ptr, nty_proc_f func, void *arg) {
    nty_coroutine_t *co = (nty_coroutine_t *)malloc(sizeof(nty_coroutine_t));
    if (!co) return -1;

    co->stack = (char *)malloc(NTY_CO_STACK_SIZE);
    if (!co->stack) {
        free(co);
        return -1;
    }

    co->sched = sched;
    co->func = func;
    co->arg = arg;
    co->stack_size = NTY_CO_STACK_SIZE;
    co->status = 0; // 0 represents NEW/READY

    // Initialize the context
    getcontext(&co->ctx);

    // Set up the stack
    co->ctx.uc_stack.ss_sp = co->stack;
    co->ctx.uc_stack.ss_size = co->stack_size;
    co->ctx.uc_stack.ss_flags = 0;
    
    // Set the context to return to (the scheduler's context) when the coroutine finishes
    co->ctx.uc_link = &sched->main_ctx;

    // Modify the context to run our entry function
    // Note: The arguments to makecontext must match the signature of _nty_coroutine_entry
    makecontext(&co->ctx, (void (*)(void))_nty_coroutine_entry, 1, co);

    *co_ptr = co;
    return 0;
}

// Resumes a coroutine
void nty_coroutine_resume_ucontext(nty_schedule_t *sched, nty_coroutine_t *co) {
    if (co->status == -1) return; // Don't resume an exited coroutine

    sched->running_co = co;
    // Save the scheduler's context and switch to the coroutine's context
    swapcontext(&sched->main_ctx, &co->ctx);
    sched->running_co = NULL;
}

// A coroutine yields control back to the scheduler
void nty_coroutine_yield_ucontext(nty_schedule_t *sched) {
    nty_coroutine_t *co = sched->running_co;
    if (!co) return;
    
    // Save the coroutine's context and switch back to the scheduler's context
    swapcontext(&co->ctx, &sched->main_ctx);
}

// Frees a coroutine's resources
void nty_coroutine_free_ucontext(nty_coroutine_t *co) {
    if (!co) return;
    free(co->stack);
    free(co);
}
```

### `ntyco-ucontext` 代码解读

让我们来读一下我们刚刚写的代码。

1.  **结构体变化**:
    *   `nty_coroutine_s` 里的 `nty_cpu_ctx ctx` 被换成了 `ucontext_t ctx`。
    *   `nty_schedule_s` 里的 `nty_cpu_ctx ctx` 被换成了 `ucontext_t main_ctx`。
    *   我们不再需要手写汇编，所以 `nty_cpu_ctx` 这个结构体可以被完全抛弃了。

2.  **`nty_coroutine_create_ucontext()`**:
    *   和原版一样，分配 `nty_coroutine_t` 和栈 `stack`。
    *   `getcontext(&co->ctx)`: **关键步骤**。获取当前上下文作为模板。
    *   `co->ctx.uc_stack.ss_sp = co->stack`: 将这个上下文的栈指向我们新分配的 `stack`。
    *   `co->ctx.uc_link = &sched->main_ctx`: **重要**。`uc_link` 指定了当这个协程函数执行完毕后，程序应该恢复到哪个上下文。我们让它恢复到调度器主循环。
    *   `makecontext(...)`: **关键步骤**。将这个上下文的执行入口修改为我们的 `_nty_coroutine_entry` 函数，并告诉它需要一个参数 `co`。

3.  **`_nty_coroutine_entry()`**:
    *   这个函数的作用和原版 `_exec` 完全一样，都是作为协程的入口。
    *   它执行用户函数，然后在结束后将状态置为 `EXITED`，最后 `swapcontext` 切回调度器。

4.  **`nty_coroutine_resume_ucontext()`**:
    *   `swapcontext(&sched->main_ctx, &co->ctx)`: **代替了 `_switch`**。这行代码的含义是：“把当前的上下文（调度器的）保存到 `main_ctx` 里，然后立即切换到 `co->ctx` 所代表的上下文去执行。”

5.  **`nty_coroutine_yield_ucontext()`**:
    *   `swapcontext(&co->ctx, &sched->main_ctx)`: **代替了 `_switch`**。含义是：“把当前的上下文（协程的）保存到 `co->ctx` 里，然后立即切换回 `main_ctx`（调度器的）上下文去执行。”

看到了吗？使用 `ucontext` 后，整个逻辑变得非常清晰。`resume` 就是从 `main` 切换到 `co`，`yield` 就是从 `co` 切换回 `main`。所有平台相关的、晦涩的寄存器操作都被 `swapcontext` 这一个函数优雅地封装了。

---

## 4. `hook_tcp_server-ucontext.c` 用例

现在，我们需要一个例子来使用我们基于 `ucontext` 的新核心。我们可以改造原始的 `hook_tcpserver.c`。由于我们只是替换了底层的上下文切换机制，而上层的 `nty_schedule_run` 和 Hook 逻辑保持不变，所以对于用户来说，代码几乎没有任何变化！

这正是优秀底层设计的魅力：**对上层透明**。

下面是 `hook_tcp_server-ucontext.c` 的示例代码。它会使用我们上面定义的 `ucontext` 版本函数。为了能让它独立编译运行，我们需要将上面的 `ntyco-ucontext` 实现和一个简化的调度循环结合起来。

我将为您创建一个可以直接使用的 `hook_tcp_server-ucontext.c` 文件。这个文件会包含一个简化的调度器和 `ucontext` 协程实现，以便于演示和编译。

请查看 `gemini/hook_tcp_server-ucontext.c` 文件，我已经为您准备好了。该文件可以直接编译和运行，以展示 `ucontext` 版本协程的工作方式。

**如何编译和运行新例子？**

```bash
# 编译 (需要链接 -ldl 以支持 dlsym)
gcc -o hook_tcp_server_ucontext hook_tcp_server-ucontext.c -ldl

# 运行，监听 8080 端口
./hook_tcp_server_ucontext 8080
```

然后你可以用 `nc localhost 8080` 或 `telnet localhost 8080` 来连接这个服务器，发送任何消息，它都会 echo 回来。

## 总结

恭喜你！你已经完成了 ntyco 的探险之旅。

我们从宏观的架构和核心概念出发，理解了协程、调度器和 Hook 如何协同工作；然后我们深入源码，厘清了协程创建、切换、调度和 IO 等待的完整生命周期；最后，我们还亲自动手，用 `ucontext` 对其核心进行了现代化改造，并验证了我们的成果。

希望这次旅行能让你对协程的原理有一个清晰而深刻的认识。从这里出发，无论是继续深入研究 ntyco 的更多细节，还是学习其他更现代的协程库（如 libco, Go coroutine），你都将拥有一个坚实的基础。
