---
title: 'epoll实现原理'
description: ''
pubDate: 2026-02-20
---

# epoll 实现原理

# 红黑树 和 队列
> '2 + 2' : 两个**结构体**, 两个**数据结构**
>

**epitem 结构体 : 描述每一个节点 (既是红黑树的节点, 又是就绪队列的节点)**

+ 即使添加到就绪队列, 也没有从整集中移除 ---> `节点`**<font style="color:#DF2A3F;"> 由 </font>**`红黑树`**<font style="color:#DF2A3F;"> 和 </font>**`队列` 共用</font>**

**eventpoll 结构体 : 整集, 描述整棵红黑树**

+ `rbr`: 红黑树 根节点
+ `rdlist`: 就绪队列首节点

![1756695199328-5a18d342-4d7d-4480-bd03-a1f00fbcbb89.jpeg](./img/0UIuQmlltF00FgdZ/1756695199328-5a18d342-4d7d-4480-bd03-a1f00fbcbb89-728171.jpeg)

看上去 List 和 RB tree 是两个数据结构, **<font style="color:#DF2A3F;">实则二者的节点是共用的</font>**

![1756695578505-d79805f0-ec5a-43d0-8f6f-236da5b96938.jpeg](./img/0UIuQmlltF00FgdZ/1756695578505-d79805f0-ec5a-43d0-8f6f-236da5b96938-895874.jpeg)

# epoll_create / ctl / wait 分别实现
> epoll 函数 : '3 + 1'
>
> + 三个对外的接口
> + 一个对内 -- epoll_callback
>

## epoll_create
1. **创建一个 **`**struct eventpoll**`
2. **为**`**epollevent**`这个结构体分配一个`**epfd**`

## epoll_ctl
ADD : 如果事件存在, 直接返回 (已存在)

DEL : 如果存在, 直接删除, 如果不存在, 返回 (不存在)

MOD : 查找, 重新赋值

## epoll_wait
**参数 :**

**<font style="color:#DF2A3F;">epfd, event, length, timeout</font>**

#### <font style="color:#DF2A3F;">timeout < 0 --> 一直等待</font>
**pthread_cond_wait()**

+ **就绪队列非空的时候 **`pthread_cond_signal()`唤醒一下

#### <font style="color:#DF2A3F;">timeout != 0 --> 等待固定长度事件</font>
**pthread_cond_timedwait()**

#### <font style="color:#DF2A3F;">timeout == 0 --> 不用等待, 立刻返回</font>
![1756696393335-afc8dac6-7b18-48bc-b0e6-2a4614ba4b62.jpeg](./img/0UIuQmlltF00FgdZ/1756696393335-afc8dac6-7b18-48bc-b0e6-2a4614ba4b62-407534.jpeg)

# 协议栈如何通知到 epoll 模块
> epoll 函数: '3 + 1'
>

![1756697901904-42218b96-e599-4831-808f-0a02f3b9f0ef.jpeg](./img/0UIuQmlltF00FgdZ/1756697901904-42218b96-e599-4831-808f-0a02f3b9f0ef-971097.jpeg)

## epoll_callback
1. **三次握手完成时, 调用一次:**
+ `epoll_event_callback(table->ep, listener->fd, EPOLLIN)` 通知: ** listenfd 触发一个 EPOLLIN 事件 **
2. **数据来临时 （PSH 包）, 调用一次**

通知 fd 触发一个 EPOLLIN

3. **接收到 FIN 包的时候, 调用一次**

通知 fd 触发一个 EPOLLIN
