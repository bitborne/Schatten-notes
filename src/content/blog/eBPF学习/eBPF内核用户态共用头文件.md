---
title: 'eBPF内核用户态共用头文件'
description: '本文介绍了在 eBPF 开发中，如何通过合理的头文件包含顺序或手动 typedef 来防止内核态与用户态共用头文件时出现的类型重定义问题。'
pubDate: 2026-02-23
---

# `common.h`怎样防止重定义?

## 问题

### common.h:

- __u32 在内核态 vmlinux.h 中有 typedef
- __u32 在用户态的一大坨头文件中也有 typedef
- 但是如果单独放在 `common.h` 没人typedef

```c
#ifndef __MIRROR_H__
#define __MIRROR_H__

#define CHUNK_SIZE 1024
#define EVENT_HEADER 1
#define EVENT_DATA 2

struct packet_event {
    __u32 type;  
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u32 payload_len;
    __u32 offset;
    __u32 chunk_len;
    __u8 data[CHUNK_SIZE];
};

#endif
```

## 解决方法1

**自己 typedef**

```c
// common.h 下
typedef unsigned int __u32;
```



## 解决方法2

**制定好头文件包含顺序:**

### 内核态

-  把 `common.h` 放在 `vmlinux.h` 后面 include
- 注意: `vmlinux.h` 必须放在开头! 因为 `bpf_helpers.h` 依赖 `vmlinux.h`

```c
// mirror.bpf.c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// 放在最后
#include "mirror_common.h"
// #define CHUNK_SIZE 1024
// #define EVENT_HEADER 1
// #define EVENT_DATA   2

// struct packet_event {
//     __u32 type;
//     __u32 src_ip;
//     __u32 dst_ip;
//     __u16 src_port;
//     __u16 dst_port;
//     __u32 payload_len;
//     __u32 offset;
//     __u32 chunk_len;
//     __u8 data[CHUNK_SIZE];
// };
```

### 用户态

- 把**一大坨头文件**放在`common.h` include

```c
// mirror.c
#include "mirror_log.h"
#include "mirror.skel.h"

#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

// 放在最后
#include "mirror_common.h"
```

## 结果

**common.h 长这样, 内部看起来没有 `typedef __u32`  也能正常编译**

```c
#ifndef __MIRROR_H__
#define __MIRROR_H__

#define CHUNK_SIZE 1024
#define EVENT_HEADER 1
#define EVENT_DATA 2

struct packet_event {
    __u32 type;
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u32 payload_len;
    __u32 offset;
    __u32 chunk_len;
    __u8 data[CHUNK_SIZE];
};

#endif
```

