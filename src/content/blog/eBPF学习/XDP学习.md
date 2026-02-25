# XDP Filter 示例

## 📚 什么是 XDP？

**XDP (eXpress Data Path)** 是 Linux 内核中最早的数据包处理点，在网络驱动层就可以处理数据包，性能极高。

### XDP 的特点

- ⚡ **极致性能**：在驱动层处理，无需经过内核网络栈
- 🚀 **零拷贝**：直接在驱动内存中处理数据包
- 🎯 **早期过滤**：在数据包进入系统前就可以丢弃
- 🔧 **灵活处理**：可以修改、丢弃、转发或重定向数据包

### XDP vs TC 对比

| 特性 | XDP | TC |
|------|-----|-----|
| **处理位置** | 网络驱动层 | 内核网络栈 |
| **性能** | 极高 | 高 |
| **方向** | 仅 Ingress（入站） | Ingress + Egress |
| **功能** | 基础数据包处理 | 更丰富（QoS、分类等） |
| **适用场景** | DDoS 防护、负载均衡 | 流量整形、策略控制 |

---

## 🎯 本示例功能

这个示例演示了 XDP 的基本用法：

1. **过滤 ICMP 数据包**：在驱动层直接丢弃 ICMP 包
2. **流量统计**：统计各协议（ICMP、TCP、UDP）的数据包数量
3. **实时显示**：每 2 秒更新一次统计信息

---

## 📁 文件结构

```
xdp_filter/
├── xdp_filter.bpf.c    # XDP 内核态程序
├── xdp_filter.c        # 用户态加载程序
├── Makefile            # 构建脚本
└── README.md           # 本文档
```

---

## 🔧 XDP 返回值

XDP 程序通过返回值决定数据包的处理方式：

| 返回值 | 宏定义 | 含义 |
|--------|--------|------|
| `0` | `XDP_ABORTED` | 发生错误，丢弃数据包 |
| `1` | `XDP_DROP` | **丢弃数据包** |
| `2` | `XDP_PASS` | **允许通过**，传递到网络栈 |
| `3` | `XDP_TX` | 从接收接口发送回去（反弹） |
| `4` | `XDP_REDIRECT` | 重定向到其他网卡 |

---

## 🚀 编译和运行

### 1. 编译

```bash
cd src/xdp_filter
make
```

编译成功后会生成：
- `xdp_filter` - 可执行程序
- `../.output/xdp_filter.bpf.o` - eBPF 字节码
- `../.output/xdp_filter.skel.h` - 骨架头文件

### 2. 运行

```bash
# 查看网络接口名称
ip addr show

# 运行 XDP 程序（需要 root 权限）
sudo ./xdp_filter ens33   # 替换为您的网络接口名
```

### 3. 测试

在另一个终端执行：

```bash
# ICMP 包会被 XDP 丢弃（在驱动层）
ping 8.8.8.8

# TCP 流量正常通过
curl https://google.com
```

### 4. 查看统计信息

程序会实时显示统计信息：

```
XDP Packet Statistics (Press Ctrl+C to exit)
Protocol        Packet Count
--------        ------------
TCP             1234
UDP             56

Note: ICMP packets are dropped by XDP (not counted in network stack)
```

### 5. 查看内核日志

```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe
```

预期输出：
```
xdp_filter-12345 [001] .... 123456.789: XDP: Dropping ICMP packet: 8.8.8.8 -> 192.168.1.100
```

---

## 🎓 XDP 模式说明

XDP 支持三种工作模式：

### 1. **Generic/SKB 模式** (XDP_FLAGS_SKB_MODE)
- ✅ **兼容性最好**：所有网卡都支持
- ⚠️ **性能较低**：在内核网络栈中模拟 XDP
- 📌 **本示例使用此模式**

### 2. **Native/Driver 模式** (XDP_FLAGS_DRV_MODE)
- ⚡ **性能高**：直接在驱动中执行
- ⚠️ **需要驱动支持**：仅部分网卡支持（如 Intel i40e、mlx5 等）
- 🔧 修改代码：将 `XDP_FLAGS_SKB_MODE` 改为 `XDP_FLAGS_DRV_MODE`

### 3. **Hardware Offload 模式** (XDP_FLAGS_HW_MODE)
- 🚀 **性能最高**：在网卡硬件中执行
- ⚠️ **需要硬件支持**：仅高端网卡支持（如 Netronome NFP）

---

## 📊 代码讲解

### 内核态程序 (xdp_filter.bpf.c)

#### 1. XDP 程序入口点

```c
SEC("xdp")
int xdp_filter_icmp(struct xdp_md *ctx)
```

- `SEC("xdp")` 标记为 XDP 程序
- `struct xdp_md` 是 XDP 的上下文结构

#### 2. 数据包解析

```c
void *data = (void *)(long)ctx->data;
void *data_end = (void *)(long)ctx->data_end;
```

XDP 直接访问原始数据包内存。

#### 3. 边界检查

```c
if ((void *)(eth + 1) > data_end)
    return XDP_PASS;
```

必须进行边界检查，否则 verifier 会拒绝加载。

#### 4. 流量统计

```c
__u64 *count = bpf_map_lookup_elem(&packet_stats, &proto);
if (count) {
    __sync_fetch_and_add(count, 1);
}
```

使用 BPF Map 存储统计信息。

### 用户态程序 (xdp_filter.c)

#### 1. 附加 XDP 程序

```c
bpf_xdp_attach(ifindex, prog_fd, XDP_FLAGS_SKB_MODE, NULL);
```

- `ifindex`：网络接口索引
- `prog_fd`：程序文件描述符
- `XDP_FLAGS_SKB_MODE`：使用通用模式

#### 2. 读取统计信息

```c
bpf_map_lookup_elem(bpf_map__fd(skel->maps.packet_stats),
                    &proto, &count);
```

从 BPF Map 读取协议统计数据。

---

## 🛠️ 实战练习

### 练习 1：丢弃指定源 IP

**任务**：扩展程序，丢弃来自特定 IP 地址的所有流量。

**提示**：
```c
// 在 XDP 程序中添加
__u32 blocked_ip = bpf_htonl(0xC0A80101);  // 192.168.1.1
if (ip->saddr == blocked_ip) {
    return XDP_DROP;
}
```

### 练习 2：限制 UDP 端口

**任务**：只允许特定 UDP 端口通过，其他端口丢弃。

### 练习 3：实现简单的负载均衡

**任务**：使用 `XDP_TX` 将部分流量反弹回发送方。

---

## ❓ 常见问题

### Q1: 如何查看已加载的 XDP 程序？

```bash
# 使用 ip 命令
ip link show ens33

# 使用 bpftool
sudo bpftool net list
sudo bpftool prog list
```

### Q2: 如何手动卸载 XDP 程序？

```bash
# 使用 ip 命令
sudo ip link set dev ens33 xdp off

# 或在程序中使用
bpf_xdp_detach(ifindex, XDP_FLAGS_SKB_MODE, NULL);
```

### Q3: 为什么 ICMP 统计为 0？

因为 ICMP 包在 XDP 层就被丢弃了，根本没有进入内核网络栈，所以不会被统计。只有通过 `XDP_PASS` 的数据包才会被计数。

### Q4: 我的网卡支持 Native XDP 吗？

```bash
# 查看驱动支持
ethtool -i ens33

# 尝试加载 Native 模式
# 如果失败，说明不支持
sudo ip link set dev ens33 xdpgeneric off
sudo ip link set dev ens33 xdp obj xdp_filter.bpf.o sec xdp
```

---

## 🔗 参考资源

- [eBPF教程](github.com/haolipeng/ebpf-tutorial)

- [XDP Tutorial](https://github.com/xdp-project/xdp-tutorial)
- [Cilium XDP 文档](https://docs.cilium.io/en/stable/bpf/)
- [Linux XDP Documentation](https://www.kernel.org/doc/html/latest/networking/xdp.html)
- [libbpf XDP API](https://libbpf.readthedocs.io/en/latest/api.html)

---

## ✅ 总结

通过本示例，你学习了：

- ✅ XDP 的基本概念和工作原理
- ✅ XDP 程序的编写和加载
- ✅ XDP 与 TC 的区别和选择
- ✅ 使用 BPF Map 进行数据统计
- ✅ 三种 XDP 模式的差异

**XDP 的典型应用场景：**
- 🛡️ DDoS 防护（在驱动层丢弃恶意流量）
- ⚖️ 负载均衡（分发流量到不同后端）
- 🔥 防火墙（高性能包过滤）
- 📊 流量监控（零开销统计）

**下一步学习：**
- 尝试 XDP_TX 和 XDP_REDIRECT
- 结合 XDP 和 TC 实现完整的流量管理
- 学习 AF_XDP 进行用户空间高性能包处理