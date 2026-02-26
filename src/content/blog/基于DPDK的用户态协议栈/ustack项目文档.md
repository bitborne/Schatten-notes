---
title: 'ustack项目文档'
description: '本文档是对 ustack 项目的完整技术拆解，详细分析了以太网、IP、TCP 等网络协议头的结构，以及用户态协议栈的设计架构与实现细节。'
pubDate: 2026-02-20
---

# ustack项目完整分析文档

> 源码...这就是个学习demo, 没开源哈, 不过后期我一定会把生产级DPDK用户态协议栈实现的! ---2026.2.19
>

## 1. 网络协议头分析

### 1.1 以太网头部 (Ethernet Header)

以太网帧头包含以下字段：

- `dst_addr`: 目标MAC地址 (6字节)
- `src_addr`: 源MAC地址 (6字节)
- `ether_type`: 类型字段，标识上层协议 (2字节)
- 0x0800: IPv4协议
- 0x0806: ARP协议
- 0x86DD: IPv6协议


### 1.2 IP头部 (IP Header)

IPv4头部包含以下关键字段：

- `version_ihl`: 版本(4位)和首部长度(4位)，如0x45表示IPv4，首部长度为20字节

- `type_of_service`: 服务类型字段

- `total_length`: IP包总长度(首部+数据)

- `packet_id`: 数据包ID，用于分片重组

- `fragment_offset`: 分片偏移量

- `time_to_live`: TTL生存时间

- `next_proto_id`: 上层协议ID(如IPPROTO_TCP=6, IPPROTO_UDP=17)

- `src_addr`: 源IP地址

- `dst_addr`: 目标IP地址

- `hdr_checksum`: 头部校验和

### 1.3 TCP头部 (TCP Header)

TCP头部包含以下字段：

- `src_port`: 源端口号

- `dst_port`: 目标端口号

- `sent_seq`: 序列号

- `recv_ack`: 确认号

- `data_off`: 数据偏移(首部长度)

- `tcp_flags`: TCP标志位

- SYN: 同步序列号，用于建立连接

- ACK: 确认标志

- FIN: 断开连接标志

- RST: 重置连接

- PSH: 推送数据

- URG: 紧急指针

- `rx_win`: 接收窗口大小

- `cksum`: 校验和

### 1.4 UDP头部 (UDP Header)

UDP头部包含以下字段：

- `src_port`: 源端口号

- `dst_port`: 目标端口号

- `dgram_len`: UDP包长度

- `dgram_cksum`: 校验和

## 2. 代码实现详解

  

### 2.1 项目结构

- `ustack.c`: 主要实现文件，包含TCP/UDP协议栈的核心功能

- `ustack_perfect.c`: 改进版本的实现

- `Makefile`: 编译配置文件

### 2.2 全局变量定义

```c

// 发送相关全局变量

uint8_t global_smac[RTE_ETHER_ADDR_LEN]; // 全局源MAC地址

uint8_t global_dmac[RTE_ETHER_ADDR_LEN]; // 全局目标MAC地址

uint32_t global_sip; // 全局源IP地址

uint32_t global_dip; // 全局目标IP地址

uint16_t global_sport; // 全局源端口

uint16_t global_dport; // 全局目标端口

  

// TCP相关状态变量

uint8_t global_flags; // 全局TCP标志位

uint32_t global_seqnum; // 全局序列号

uint32_t global_acknum; // 全局确认号

uint8_t tcp_status = USTACK_TCP_LISTEN; // TCP状态机

```

  

### 2.3 包编码函数

  

#### 2.3.1 UDP包编码 (ustack_encoding_udp_pkt)

```c

static int ustack_encoding_udp_pkt(uint8_t *msg, uint8_t *data, uint16_t total_len) {

// [1] 以太网头部编码

struct rte_ether_hdr *eth = (struct rte_ether_hdr*)msg;

rte_memcpy(eth->d_addr.addr_bytes, global_dmac, RTE_ETHER_ADDR_LEN);

rte_memcpy(eth->s_addr.addr_bytes, global_smac, RTE_ETHER_ADDR_LEN);

eth->ether_type = htons(RTE_ETHER_TYPE_IPV4);

  

// [2] IP头部编码

struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr*)(eth + 1);

ip->version_ihl = 0x45; // IPv4 + 首部长度20字节

ip->type_of_service = 0; // 服务类型

ip->total_length = htons(total_len - sizeof(struct rte_ether_hdr));

ip->packet_id = 0; // 数据包ID

ip->fragment_offset = 0; // 分片偏移

ip->time_to_live = 64; // TTL

ip->next_proto_id = IPPROTO_UDP; // 上层协议UDP

ip->src_addr = global_sip; // 源IP

ip->dst_addr = global_dip; // 目标IP

ip->hdr_checksum = 0; // 重置校验和

ip->hdr_checksum = rte_ipv4_cksum(ip); // 计算校验和

  

// [3] UDP头部编码

struct rte_udp_hdr *udp = (struct rte_udp_hdr*)(ip + 1);

udp->src_port = global_sport; // 源端口

udp->dst_port = global_dport; // 目标端口

uint16_t udp_len = total_len - sizeof(struct rte_ether_hdr) - sizeof(struct rte_ipv4_hdr);

udp->dgram_len = htons(udp_len); // UDP长度

// [4] 数据填充

rte_memcpy((uint8_t*)(udp + 1), data, udp_len);

udp->dgram_cksum = 0;

udp->dgram_cksum = rte_ipv4_udptcp_cksum(ip, udp); // UDP校验和

  

return 0;

}

```

  

#### 2.3.2 TCP包编码 (ustack_encoding_tcp_pkt)

```c

static int ustack_encoding_tcp_pkt(uint8_t* msg, uint16_t total_len) {

// [1] 以太网头部编码 (同UDP)

// [2] IP头部编码 (同UDP)

  

// [3] TCP头部编码

struct rte_tcp_hdr* tcp = (struct rte_tcp_hdr*)(ip + 1);

tcp->src_port = global_sport; // 源端口

tcp->dst_port = global_dport; // 目标端口

tcp->sent_seq = htonl(12345); // 序列号 (随机值)

tcp->recv_ack = htonl(global_seqnum + 1); // 确认号(对方序列号+1)

tcp->data_off = 0x50; // 数据偏移，5个32位字(20字节)

tcp->tcp_flags = RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG; // SYN+ACK标志

tcp->rx_win = htons(TCP_INIT_WINDOWS); // 接收窗口大小

tcp->cksum = 0;

tcp->cksum = rte_ipv4_udptcp_cksum(ip, tcp); // TCP校验和

  

return 0;

}

```

  

### 2.4 网卡初始化 (ustack_init_port)

```c

static int ustack_init_port(struct rte_mempool *mbuf_pool) {

// 获取可用网卡数量

uint16_t nb_sys_ports = rte_eth_dev_count_avail();

if (nb_sys_ports == 0) {

rte_exit(EXIT_FAILURE, "No Supported eth found\n");

}

  

// 获取网卡设备信息

struct rte_eth_dev_info dev_info;

rte_eth_dev_info_get(global_portid, &dev_info);

  

// 配置网卡

const int num_rx_queues = 1; // 1个接收队列

const int num_tx_queues = 1; // 1个发送队列

rte_eth_dev_configure(global_portid, num_rx_queues, num_tx_queues, &port_conf_default);

  

// 设置接收队列

if (rte_eth_rx_queue_setup(global_portid, 0, 128, rte_eth_dev_socket_id(global_portid), NULL, mbuf_pool) < 0) {

rte_exit(EXIT_FAILURE, "Could not setup RX queue\n");

}

// 设置发送队列

struct rte_eth_txconf txq_conf = dev_info.default_txconf;

txq_conf.offloads = port_conf_default.rxmode.offloads;

if (rte_eth_tx_queue_setup(global_portid, 0, 512, rte_eth_dev_socket_id(global_portid), &txq_conf) < 0) {

rte_exit(EXIT_FAILURE, "Could not setup TX queue\n");

}

  

// 启动网卡

if (rte_eth_dev_start(global_portid) < 0) {

rte_exit(EXIT_FAILURE, "Could not start\n");

}

  

return 0;

}

```

  

### 2.5 主要处理逻辑 (main函数)

  

#### 2.5.1 初始化阶段

```c

int main (int argc, char* argv[]) {

// 1. EAL初始化: DPDK环境抽象层初始化

if (rte_eal_init(argc, argv) < 0) {

rte_exit(EXIT_FAILURE, "Error with EAL init\n");

}

  

// 2. 获取网卡MAC地址

struct rte_ether_addr mac;

rte_eth_macaddr_get(global_portid, &mac);

  

// 3. 创建内存池

struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create("mbuf_pool", NUM_MBUFS, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());

  

// 4. 初始化网卡端口

ustack_init_port(mbuf_pool);

}

```

  

#### 2.5.2 包处理循环

```c

while (1) {

struct rte_mbuf* mbufs[BURST_SIZE] = {0};

// 从接收队列批量获取数据包

uint16_t num_recvd = rte_eth_rx_burst(global_portid, 0, mbufs, BURST_SIZE);

for (int i = 0; i < num_recvd; i++) {

// 解析以太网头部

struct rte_ether_hdr *eth_hdr = rte_pktmbuf_mtod(mbufs[i], struct rte_ether_hdr*);

if (eth_hdr->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4)) {

continue; // 非IPv4包，跳过

}

  

// 解析IP头部

struct rte_ipv4_hdr *ip_hdr = rte_pktmbuf_mtod_offset(mbufs[i], struct rte_ipv4_hdr*, sizeof(struct rte_ether_hdr));

if (ip_hdr->next_proto_id == IPPROTO_UDP) {

// 处理UDP包

struct rte_udp_hdr *udp_hdr = (struct rte_udp_hdr*)(ip_hdr + 1);

// 交换地址信息，准备回送

rte_memcpy(global_smac, eth_hdr->d_addr.addr_bytes, RTE_ETHER_ADDR_LEN);

rte_memcpy(global_dmac, eth_hdr->s_addr.addr_bytes, RTE_ETHER_ADDR_LEN);

// 发送UDP回送包

#if ENABLE_SEND

// 分配新的mbuf

struct rte_mbuf *tx_mbuf = rte_pktmbuf_alloc(mbuf_pool);

// 调用编码函数

ustack_encoding_udp_pkt(msg, data, total_len);

// 发送包

rte_eth_tx_burst(global_portid, 0, &tx_mbuf, 1);

#endif

} else if (ip_hdr->next_proto_id == IPPROTO_TCP) {

// 处理TCP包

struct rte_tcp_hdr *tcp_hdr = (struct rte_tcp_hdr*)(ip_hdr + 1);

// 提取TCP标志位、序列号、确认号

global_flags = tcp_hdr->tcp_flags;

global_seqnum = ntohl(tcp_hdr->sent_seq);

global_acknum = ntohl(tcp_hdr->recv_ack);

// TCP状态机处理

if (global_flags & RTE_TCP_SYN_FLAG) {

if (tcp_status == USTACK_TCP_LISTEN) {

// 发送SYN+ACK响应

ustack_encoding_tcp_pkt(msg, total_len);

tcp_status = USTACK_TCP_SYN_RCVD;

}

} else if (global_flags & RTE_TCP_ACK_FLAG) {

if (tcp_status == USTACK_TCP_SYN_RCVD) {

tcp_status = USTACK_TCP_ESTABLISHED;

printf("\n==== TCP CONNECT SUCCESS ====\n");

}

}

// 处理数据推送

if (global_flags & RTE_TCP_PSH_FLAG) {

if (tcp_status == USTACK_TCP_ESTABLISHED) {

uint8_t tcp_hdr_len = (tcp_hdr->data_off >> 4) * sizeof(uint32_t);

uint8_t *data = ((uint8_t*)tcp_hdr + tcp_hdr_len);

printf("[TCP]: %s\n", data);

}

}

}

// 释放mbuf

rte_pktmbuf_free(mbufs[i]);

}

}

```

  

## 3. DPDK相关函数API和数据结构详解

  

### 3.1 DPDK初始化函数

- `rte_eal_init(argc, argv)`: 初始化DPDK环境抽象层，配置CPU核心、内存等资源

- `rte_exit(EXIT_FAILURE, "Error message")`: DPDK错误退出函数

  

### 3.2 内存管理相关

- `struct rte_mempool`: DPDK内存池结构，用于高效分配和回收固定大小的内存块

- 相当于内核中的`sk_buff`

- `rte_pktmbuf_pool_create("mbuf_pool", NUM_MBUFS, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id())`: 创建mbuf内存池

- `struct rte_mbuf`: DPDK数据包缓冲区结构，存储网络数据包

- `rte_pktmbuf_alloc(mbuf_pool)`: 从内存池分配一个mbuf

- `rte_pktmbuf_free(mbufs[i])`: 释放mbuf回内存池

  

### 3.3 网卡管理相关

- `rte_eth_dev_count_avail()`: 获取可用网卡数量

- `struct rte_eth_dev_info`: 网卡设备信息结构

- `rte_eth_dev_info_get(global_portid, &dev_info)`: 获取指定网卡设备的详细信息

- `rte_eth_dev_configure(global_portid, num_rx_queues, num_tx_queues, &port_conf_default)`: 配置网卡端口，设置接收和发送队列数量

- `rte_eth_rx_queue_setup(global_portid, 0, 128, rte_eth_dev_socket_id(global_portid), NULL, mbuf_pool)`: 设置接收队列

- `rte_eth_tx_queue_setup(global_portid, 0, 512, rte_eth_dev_socket_id(global_portid), &txq_conf)`: 设置发送队列

- `rte_eth_dev_start(global_portid)`: 启动网卡端口

- `rte_eth_macaddr_get(global_portid, &mac)`: 获取网卡MAC地址

  

### 3.4 数据包收发相关

- `rte_eth_rx_burst(global_portid, 0, mbufs, BURST_SIZE)`: 从指定队列批量接收数据包，返回实际接收数量

- `rte_eth_tx_burst(global_portid, 0, &tx_mbuf, 1)`: 批量发送数据包

- `BURST_SIZE`: 突发处理大小，一次最多处理的数据包数量

- `NUM_MBUFS`: 内存池中mbuf的数量

  

### 3.5 数据包处理相关

- `rte_pktmbuf_mtod(mbufs[i], struct rte_ether_hdr*)`: 将mbuf转换为特定类型的指针，获取数据包起始地址

- `rte_pktmbuf_mtod_offset(mbufs[i], struct rte_ether_hdr*, sizeof(struct rte_ether_hdr))`: 获取偏移后的指针

- `rte_memcpy()`: 内存拷贝函数(类似memcpy)

- `rte_cpu_to_be_16()`, `ntohs()`, `htonl()`: 字节序转换函数

  

### 3.6 网络协议头结构

- `struct rte_ether_hdr`: 以太网头部结构

- `d_addr`: 目标MAC地址

- `s_addr`: 源MAC地址

- `ether_type`: 以太网类型

- `struct rte_ipv4_hdr`: IPv4头部结构

- `version_ihl`: 版本和首部长度

- `src_addr`, `dst_addr`: 源/目标IP地址

- `next_proto_id`: 下一层协议ID

- `struct rte_udp_hdr`: UDP头部结构

- `src_port`, `dst_port`: 源/目标端口

- `dgram_len`: UDP数据包长度

- `struct rte_tcp_hdr`: TCP头部结构

- `src_port`, `dst_port`: 源/目标端口

- `sent_seq`: 序列号

- `recv_ack`: 确认号

- `tcp_flags`: TCP标志位

- `data_off`: 数据偏移

  

### 3.7 校验和计算函数

- `rte_ipv4_cksum(ip)`: 计算IPv4头部校验和

- `rte_ipv4_udptcp_cksum(ip, tcp/udp)`: 计算TCP或UDP校验和

  

### 3.8 网络配置相关

- `RTE_ETHER_ADDR_LEN`: 以太网地址长度(6字节)

- `RTE_ETHER_TYPE_IPV4`: IPv4以太网类型值

- `IPPROTO_UDP`, `IPPROTO_TCP`: UDP和TCP协议号

- `RTE_TCP_SYN_FLAG`, `RTE_TCP_ACK_FLAG`, `RTE_TCP_PSH_FLAG`, `RTE_TCP_FIN_FLAG`: TCP标志位宏定义

- `RTE_ETHER_MAX_LEN`: 以太网最大长度

- `RTE_MBUF_DEFAULT_BUF_SIZE`: mbuf默认缓冲区大小

  

### 3.9 系统信息获取

- `rte_eth_dev_socket_id(global_portid)`: 获取网卡所在NUMA节点ID

- `rte_socket_id()`: 获取当前线程所在NUMA节点ID

  

## 4. 面试题及详细分析

  

### 4.1 面试题1：请解释DPDK的基本原理及其优势

  

**面试级回答：**

DPDK(Dataplane Development Kit)是一个用户态网络数据包处理框架，其核心原理是：

1. 轮询模式：通过轮询而非中断方式处理网络数据包，避免中断开销

2. 零拷贝：数据包直接从网卡DMA到用户态内存，避免内核与用户态之间的数据拷贝

3. 内存池：使用预分配的固定大小内存池(mbfs)进行数据包缓冲，提高内存分配效率

4. 大页内存：使用大页内存减少页表项，提高TLB命中率

  

主要优势：

- 高性能：绕过内核，直接在用户态处理数据包

- 低延迟：减少数据包处理路径

- 高吞吐量：批量处理和优化的内存管理

  

**详细分析：**

在ustack项目中，我们使用了`rte_mempool`内存池来管理数据包缓冲区，`rte_eth_rx_burst`函数进行批量轮询接收数据包，避免了传统中断驱动模式的开销。

  

### 4.2 面试题2：请解释TCP三次握手的详细过程及在代码中的实现

  

**面试级回答：**

TCP三次握手过程：

1. 客户端发送SYN包，状态变为SYN_SENT

2. 服务器收到SYN包，发送SYN+ACK包，状态变为SYN_RCVD

3. 客户端收到SYN+ACK包，发送ACK包，状态变为ESTABLISHED

4. 服务器收到ACK包，状态变为ESTABLISHED

  

**详细分析：**

在ustack代码中：

```c

if (global_flags & RTE_TCP_SYN_FLAG) {

	if (tcp_status == USTACK_TCP_LISTEN) { // 收到SYN

		// 发送SYN+ACK响应包
		ustack_encoding_tcp_pkt(msg, total_len);
		tcp_status = USTACK_TCP_SYN_RCVD; // 状态变为SYN_RCVD

	}

} else if (global_flags & RTE_TCP_ACK_FLAG) {

	if (tcp_status == USTACK_TCP_SYN_RCVD) { // 收到ACK
        
		tcp_status = USTACK_TCP_ESTABLISHED; // 状态变为ESTABLISHED
		printf("\n==== TCP CONNECT SUCCESS ====\n");
        
	}

}

```

代码实现了服务器端的三次握手响应逻辑，当收到SYN包时发送SYN+ACK，收到ACK后连接建立。

  

### 4.3 面试题3：请解释DPDK的mbuf结构及其在内存管理中的作用

  

**面试级回答：**

mbuf是DPDK中数据包的容器结构，其主要特点：

- 预分配：在初始化时批量分配，避免运行时动态分配开销

- 固定大小：每个mbuf大小固定，便于内存管理

- 池化管理：通过内存池统一管理，提高分配回收效率

- 引用计数：支持数据包的共享和复制

  

**详细分析：**

在ustack代码中：

```c

struct rte_mempool *mbuf_pool = rte_pktmbuf_pool_create("mbuf_pool", NUM_MBUFS, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());

struct rte_mbuf *tx_mbuf = rte_pktmbuf_alloc(mbuf_pool);

rte_pktmbuf_free(mbufs[i]);

```

创建内存池后，通过`rte_pktmbuf_alloc`分配mbuf，通过`rte_pktmbuf_free`释放mbuf，实现高效的内存复用。

  

### 4.4 面试题4：请解释网络协议栈中各层头部的解析方法

  

**面试级回答：**

协议栈头部解析遵循层层剥离的方法：

1. 从以太网头部开始，根据ether_type判断上层协议

2. 对于IP包，解析IP头部，根据next_proto_id判断传输层协议

3. 解析TCP或UDP头部，提取端口号等信息

4. 最后获取实际数据内容

  

**详细分析：**

在ustack代码中，头部解析过程如下：

```c

// 1. 解析以太网头部

struct rte_ether_hdr *eth_hdr = rte_pktmbuf_mtod(mbufs[i], struct rte_ether_hdr*);

  

// 2. 解析IP头部 (偏移sizeof(struct rte_ether_hdr))

struct rte_ipv4_hdr *ip_hdr = rte_pktmbuf_mtod_offset(mbufs[i], struct rte_ipv4_hdr*, sizeof(struct rte_ether_hdr));

  

// 3. 根据协议ID解析TCP或UDP

if (ip_hdr->next_proto_id == IPPROTO_UDP) {

struct rte_udp_hdr *udp_hdr = (struct rte_udp_hdr*)(ip_hdr + 1); // IP+1跳到UDP头部

uint8_t* data = (uint8_t*)(udp_hdr + 1); // UDP+1跳到数据区域

}

```

  

### 4.5 面试题5：请解释TCP状态机的实现原理及在ustack中的应用

  

**面试级回答：**

TCP状态机是TCP连接管理的核心机制，通过状态转换处理连接建立、数据传输和连接终止。主要状态包括：CLOSED、LISTEN、SYN_SENT、SYN_RCVD、ESTABLISHED、FIN_WAIT等。每个状态对应特定的处理逻辑和状态转换规则。

  

**详细分析：**

在ustack代码中，TCP状态机实现如下：

```c

typedef enum __USTACK_TCP_STATUS{

USTACK_TCP_CLOSED = 0,

USTACK_TCP_LISTEN, // 监听状态

USTACK_TCP_SYN_RCVD, // 收到SYN，等待ACK

USTACK_TCP_SYN_SENT, // 发送SYN

USTACK_TCP_ESTABLISHED, // 连接建立

// ... 其他状态

} USTACK_TCP_STATUS;

  

uint8_t tcp_status = USTACK_TCP_LISTEN;

  

// 状态转换逻辑

if (global_flags & RTE_TCP_SYN_FLAG) {

if (tcp_status == USTACK_TCP_LISTEN) {

tcp_status = USTACK_TCP_SYN_RCVD; // LISTEN -> SYN_RCVD

}

} else if (global_flags & RTE_TCP_ACK_FLAG) {

if (tcp_status == USTACK_TCP_SYN_RCVD) {

tcp_status = USTACK_TCP_ESTABLISHED; // SYN_RCVD -> ESTABLISHED

}

}

```

通过状态变量和标志位检查实现状态转换，确保TCP连接按协议规范正确处理。

  

### 4.6 面试题6：请解释用户态协议栈相比内核协议栈的优势和挑战

  

**面试级回答：**

优势：

1. 性能：绕过内核，减少系统调用和上下文切换开销

2. 灵活性：完全控制协议处理逻辑，可定制优化

3. 可预测性：避免内核调度的不确定性

4. 高吞吐量：用户态优化的数据结构和算法

  

挑战：

1. 开发复杂性：需要实现完整的协议栈功能

2. 维护成本：独立维护协议栈实现

3. 安全性：用户态处理可能引入安全风险

4. 兼容性：需处理各种网络异常情况

  

**详细分析：**

ustack项目体现了用户态协议栈的特点：

- 使用DPDK框架绕过内核直接处理数据包

- 实现了基础的TCP/UDP协议处理

- 通过状态机管理TCP连接状态

- 面向特定应用场景，可灵活定制

  

但项目也存在局限性：

- 仅实现了基本功能，缺少完整的错误处理

- 需要手动处理地址映射(无ARP协议)

- 功能相比内核协议栈有限

  

## 5. 总结

ustack项目是一个基于DPDK的用户态TCP/UDP协议栈实现，通过直接操作网卡硬件和用户态内存管理，实现高性能的数据包处理。项目涵盖了网络协议栈的核心概念，包括协议头解析、状态机管理、内存池优化等关键技术。虽然功能相对简单，但体现了用户态网络编程的基本原理和方法。