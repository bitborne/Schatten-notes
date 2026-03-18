---
title: 'ELF 学习 - ELF reader 实现记录'
description: '本文记录从零实现 ELF Reader 的学习过程，深入剖析 Android so 库的 ELF 文件结构与动态链接机制。详解 ELF Header 解析、字节序处理与 32/64 位差异，Section Header Table 中 .dynsym、.plt、.got.plt 等关键 Section 的作用与关联。重点图解 so 间函数调用的完整流程、PLT/GOT 延迟绑定（Lazy Binding）原理，以及 GOT 表在运行时的修改机制。最后延伸至 C++ 热更新与 ByteHook 的实现基础。适合 Android 开发者的 Native 层二进制与动态链接入门指南。'
pubDate: '2026-03-18'
---

# ELF 结构与 so 跳转机制学习笔记

> 本笔记记录 ELF Reader 开发过程中的学习心得，从代码实践中理解 ELF 文件结构和动态链接机制。

---

## 步骤 1：ELF Header 解析

**目标**：理解 ELF 基本元数据（Magic、类型、架构、入口点、Header 位置）

**实现文件**：

- `app/src/main/cpp/elf_reader/elf_types.h`
- `app/src/main/cpp/elf_reader/elf_types.cpp`
- `app/src/main/cpp/elf_reader/main.cpp`
- `app/src/main/cpp/elf_reader/CMakeLists.txt`

### 1.1 ELF 文件结构概览

ELF（Executable and Linkable Format）文件由以下几部分组成：

```
+----------------------------------+
|          ELF Header              |  <-- 52 bytes (32-bit) / 64 bytes (64-bit)
|   - 文件类型、架构、入口点        |
|   - Section Header 偏移位置       |
|   - Program Header 偏移位置       |
+----------------------------------+
|       Program Header Table       |  <-- 段加载信息（运行时用）
|   - PT_LOAD: 可加载段            |
|   - PT_DYNAMIC: 动态链接信息     |
+----------------------------------+
|          .text (代码)            |
|          .data (数据)            |
|          ...                     |
+----------------------------------+
|       Section Header Table       |  <-- 节区信息（链接时用）
|   - .dynsym: 动态符号表          |
|   - .plt: 过程链接表             |
|   - .got.plt: 全局偏移表         |
+----------------------------------+
```

### 1.2 ELF Header 结构详解

#### 1.2.1 e_ident[16] - 标识字节数组（16 bytes）

| 索引 | 名称 | 含义 |
|------|------|------|
| 0-3 | EI_MAG0-3 | Magic: `0x7f` 'E' 'L' 'F' |
| 4 | EI_CLASS | 文件类别：1=32位, 2=64位 |
| 5 | EI_DATA | 数据编码：1=小端, 2=大端 |
| 6 | EI_VERSION | ELF 版本，固定为 1 |
| 7 | EI_OSABI | OS/ABI 类型：0=System V, 3=Linux |
| 8-15 | EI_PAD | 填充，保留 |

| 偏移  | 宏定义            | 含义                                         | 你看到的值                    |
| ----- | ----------------- | -------------------------------------------- | ----------------------------- |
| 0-3   | EI_MAG            | Magic: `0x7f` 'E' 'L' 'F'                    | -                             |
| 4     | EI_CLASS          | 文件类别：1=32位, 2=64位                     | `ELF64`                       |
| 5     | EI_DATA           | 数据编码:1=小端,2=大端                       | `little endian`               |
| **6** | **EI_VERSION**    | **ELF格式版本**: 与下面的`e_version`必须一致 | **1 (current)** ← ELF Version |
| **7** | **EI_OSABI**      | **操作系统ABI标识**                          | `0` (System V) 或 `3` (Linux) |
| **8** | **EI_ABIVERSION** | **ABI特定版本**                              | **0** ← ABI Version           |
| 9-15  | EI_PAD            | 保留/填充                                    | 0                             |

#### 1.2.2 关键字段（64-bit ELF）

```cpp
struct Elf64_Ehdr {
    uint8_t  e_ident[16];      // 标识信息
    uint16_t e_type;           // 文件类型：ET_DYN=动态库(so), ET_EXEC=可执行文件
    uint16_t e_machine;        // 目标架构：183=ARM64, 62=X86_64, 40=ARM
    uint32_t e_version;        // ELF 版本: 必须等于 e_ident[6] 的值
    uint64_t e_entry;          // 入口点虚拟地址（so 通常为 0）
    uint64_t e_phoff;          // Program Header 在文件中的偏移
    uint64_t e_shoff;          // Section Header 在文件中的偏移
    uint32_t e_flags;          // 处理器特定标志
    uint16_t e_ehsize;         // ELF Header 大小：64 bytes
    uint16_t e_phentsize;      // 每个 Program Header 条目大小
    uint16_t e_phnum;          // Program Header 条目数量
    uint16_t e_shentsize;      // 每个 Section Header 条目大小
    uint16_t e_shnum;          // Section Header 条目数量
    uint16_t e_shstrndx;       // 字符串表的 Section Header 索引
};
```

### 1.3 字节序处理

ELF 文件可能使用大端或小端格式。我在 `elf_types.h` 中实现了通用的读取函数：

```cpp
// 小端读取：低位字节在低地址
template<typename T>
inline T readLE(const uint8_t* p) {
    T val = 0;
    for (size_t i = 0; i < sizeof(T); i++) {
        val |= static_cast<T>(p[i]) << (i * 8);
    }
    return val;
}
// 大端读取：高位字节在低地址
template<typename T>
inline T readBE(const uint8_t* p) {
    T val = 0;
    for (size_t i = 0; i < sizeof(T); i++) {
        val |= static_cast<T>(p[i]) << ((sizeof(T) - 1 - i) * 8);
    }
    return val;
}

// 根据 ELF 文件的字节序读取数据
template<typename T>
inline T readVal(const uint8_t* p, bool littleEndian) {
    return littleEndian ? readLE<T>(p) : readBE<T>(p);
}
```

**验证方式**：Android 设备上运行的 so 都是小端格式（ARM64 支持双端但通常用小端）。

### 大小端到底长什么样?

**循环展开计算**（以32位无符号整数为例）：

假设从内存读到一个4字节数组 `p = {0x78, 0x56, 0x34, 0x12}`（这是小端存储的 0x12345678）：

#### 小端序解析

```cpp
T val = 0;
for (size_t i = 0; i < 4; i++) {
    val |= static_cast<T>(p[i]) << (i * 8);
}
```

| 轮次 | i    | p[i] | 左移位数 | 计算值                    |
| ---- | ---- | ---- | -------- | ------------------------- |
| 1    | 0    | 0x78 | 0        | `0x78 << 0` = 0x00000078  |
| 2    | 1    | 0x56 | 8        | `0x56 << 8` = 0x00005600  |
| 3    | 2    | 0x34 | 16       | `0x34 << 16` = 0x00340000 |
| 4    | 3    | 0x12 | 24       | `0x12 << 24` = 0x12000000 |

**可视化位运算**：

*初始 :	00000000 00000000 00000000 00000000 (0x00000000)*
第0轮:	00000000 00000000 00000000 **01111000** (0x000000**78**)  ← 最低字节就位
第1轮:	00000000 00000000 **01010110 01111000** (0x0000**5678**)  ← 次低字节左移8位
第2轮:	00000000 **00110100 01010110 01111000** (0x00**345678**)
第3轮:	**00010010 00110100 01010110 01111000** (0x**12345678**)  ← 最高字节左移24位，完成重组

#### 大端序解析

```cpp
T val = 0;
for (size_t i = 0; i < sizeof(T); i++) {
    val |= static_cast<T>(p[i]) << ((sizeof(T) - 1 - i) * 8);
}
```

| 轮次 | i    | p[i] | 左移位数 (3-i)*8 | 计算值                    |
| ---- | ---- | ---- | ---------------- | ------------------------- |
| 1    | 0    | 0x78 | (3-0)*8=24       | `0x12 << 24` = 0x78000000 |
| 2    | 1    | 0x56 | (3-1)*8=16       | `0x34 << 16` = 0x00560000 |
| 3    | 2    | 0x34 | (3-2)*8=8        | `0x56 << 8` = 0x00003400  |
| 4    | 3    | 0x12 | (3-3)*8=0        | `0x78 << 0` = 0x00000012  |

**可视化位运算**：

*初始 :	00000000 00000000 00000000 00000000 (0x00000000)*
第0轮:	**01111000** 00000000 00000000 00000000 (0x**78**000000)
第1轮:	**01111000 01010110** 00000000 00000000 (0x**7856**0000)
第2轮:	**01111000** **01010110 00110100** 00000000 (0x**785634**00)

第3轮:	**01111000 01010110 00110100 00010010** (0x**78563412**)

#### **`static_cast<T>(p[i])`**：

- **至关重要**：`p[i]` 是 `uint8_t`，如果不强制转换，先左移8位以上时会发生**整数提升为 int**，但更重要的是确保左移的宽度足够
- 防止符号扩展：如果 `char` 是有符号的（-128~127），`0xFF` 会被解释为 `-1`，移位时会带上符号位（变成 `0xFFFFFFFF`），导致错误结果

### 1.4 32-bit vs 64-bit 差异

| 字段 | 32-bit | 64-bit |
|------|:-------|--------|
| Header 大小 | 52 bytes | 64 bytes |
| 地址/偏移类型 | uint32_t | uint64_t |
| e_entry 偏移 | 24 | 24 |
| e_phoff 偏移 | 28 | 32 |
| e_shoff 偏移 | 32 | 40 |

**代码技巧**：通过 `is64bit` 标志统一处理两种格式：
```cpp
if (is64bit) {
    e_entry = readVal<uint64_t>(p + 24, isLittleEndian);
} else {
    e_entry = readVal<uint32_t>(p + 24, isLittleEndian);
}
```

### 1.5 运行测试

编译后推送到 Android 设备测试：

```bash
# 编译
./gradlew :app:externalNativeBuildDebug

# 推送并运行
adb push app/build/intermediates/cmake/debug/obj/arm64-v8a/elf_reader /data/local/tmp/
adb shell chmod +x /data/local/tmp/elf_reader
adb shell /data/local/tmp/elf_reader /system/lib64/libc.so
```

**预期输出**（类似 readelf -h）：
```
File: /system/lib64/libc.so
Size: 1234567 bytes

ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              DYN (Shared object file)
  Machine:                           AArch64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          1234000 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         10
  Size of section headers:           64 (bytes)
  Number of section headers:         28
  Section header string table index: 27
```

### 1.6 学习要点总结

1. **Magic 识别**：ELF 文件以 `0x7f 'E' 'L' 'F'` 开头，这是识别 ELF 文件的第一道检查
2. **e_type = ET_DYN**：共享库（.so）的类型是 DYN，而不是 EXEC
3. **e_entry = 0**：共享库没有固定的入口点，由动态链接器决定加载地址
4. **e_shoff 和 e_phoff**：这两个偏移量告诉我们 Section Header 和 Program Header 的位置，是后续解析的关键
5. **e_shstrndx**：Section Header 字符串表的索引，后续解析 Section 名称时需要用到

### 1.7 下一步预告

步骤 2 将解析 **Section Header Table**，重点关注：
- `.dynsym`：动态符号表（导出的函数）
- `.dynstr`：动态字符串表
- `.plt` 和 `.got.plt`：延迟绑定的关键结构
- `.dynamic`：动态链接信息

---

## 步骤 2：Section Header 解析与 so 跳转机制

**目标**：理解 Section Header Table，掌握 so 间函数调用的完整流程

**实现文件**：

- `app/src/main/cpp/elf_reader/elf_sections.h`
- `app/src/main/cpp/elf_reader/elf_sections.cpp`
- 更新 `app/src/main/cpp/elf_reader/main.cpp`

**测试结果**：输出与 readelf -S 基本一致，Section 解析正确

```bash
$ adb shell /data/local/tmp/elf_reader /system/lib64/libc.so

Section Headers:
  [Nr] Name              Type            Address          Off    Size   ES Flg Lk Inf Al
  [ 0]                   NULL            0000000000000000 000000 000000 00      0   0  0
  [ 1] .note.android.ident NOTE            00000000000002a8 0002a8 000018 00   A  0   0  4
  [ 2] .note.android.pad_segment NOTE            00000000000002c0 0002c0 000018 00   A  0   0  4
  [ 3] .note.gnu.build-id NOTE            00000000000002d8 0002d8 000020 00   A  0   0  4
  [ 4] .dynsym           DYNSYM          00000000000002f8 0002f8 008b38 18   A  9   1  8
  [ 5] .gnu.version      LOOS+           0000000000008e30 008e30 000b9a 02   A  4   0  2
  [ 6] .gnu.version_d    LOOS+           00000000000099cc 0099cc 0001c0 00   A  9  16  4
  [ 7] .gnu.version_r    LOOS+           0000000000009b8c 009b8c 000030 00   A  9   1  4
  [ 8] .gnu.hash         GNU_HASH        0000000000009bc0 009bc0 002cc8 00   A  4   0  8
  [ 9] .dynstr           STRTAB          000000000000c888 00c888 00477b 00   A  0   0  1
  [10] .rela.dyn         RELA            0000000000011008 011008 006108 18   A  4   0  8
  [11] .rela.plt         RELA            0000000000017110 017110 002e08 18  AI  4  24  8
  [12] .rodata           PROGBITS        0000000000019f20 019f20 022a98 00 AMS  0   0 16
  [13] .eh_frame_hdr     PROGBITS        000000000003c9b8 03c9b8 004764 00   A  0   0  4
  [14] .eh_frame         PROGBITS        0000000000041120 041120 012de0 00   A  0   0  8
  [15] .text             PROGBITS        0000000000054000 054000 09b88f 00  AX  0   0 16
  [16] .plt              PROGBITS        00000000000ef890 0ef890 001ec0 00  AX  0   0 16
  [17] .tdata            PROGBITS        00000000000f4000 0f4000 000028 00 WAT  0   0  8
  [18] .tbss             NOBITS          00000000000f4028 0f4028 000008 00 WAT  0   0  8
  [19] .data.rel.ro      PROGBITS        00000000000f4040 0f4040 002ac8 00  WA  0   0 32
  [20] .fini_array       FINI_ARRAY      00000000000f6b08 0f6b08 000010 00  WA  0   0  8
  [21] .init_array       INIT_ARRAY      00000000000f6b18 0f6b18 000030 00  WA  0   0  8
  [22] .dynamic          DYNAMIC         00000000000f6b48 0f6b48 0001c0 10  WA  9   0  8
  [23] .got              PROGBITS        00000000000f6d08 0f6d08 000148 00  WA  0   0  8
  [24] .got.plt          PROGBITS        00000000000f6e50 0f6e50 000f70 00  WA  0   0  8
  [25] .relro_padding    NOBITS          00000000000f7dc0 0f7dc0 000240 00  WA  0   0  1
  [26] .data             PROGBITS        00000000000f8000 0f8000 0005e0 00  WA  0   0 32
  [27] .bss              NOBITS          00000000000fc000 0f85e0 01f58c 00  WA  0   0 16384
  [28] .comment          PROGBITS        0000000000000000 0f85e0 0001b3 01  MS  0   0  1
  [29] .symtab           SYMTAB          0000000000000000 0f8798 013a58 18     31 1869  8
  [30] .shstrtab         STRTAB          0000000000000000 10c1f0 000147 00      0   0  1
  [31] .strtab           STRTAB          0000000000000000 10c337 014fdd 00      0   0  1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  E (exclude), C (compressed)

Key Sections for Dynamic Linking:
  .dynsym         present
  .dynstr         present
  .rela.plt       present
  .rela.dyn       present
  .plt            present
  .got.plt        present
  .dynamic        present
  .hash           NOT FOUND
  .gnu.hash       present
```

---

### 2.1 Section Header Table 结构

每个 Section Header（64-bit）包含以下信息：

```cpp
struct Elf64_Shdr {
    uint32_t sh_name;       // Section 名称在 .shstrtab 中的偏移
    uint32_t sh_type;       // Section 类型（SHT_PROGBITS, SHT_DYNSYM 等）
    uint64_t sh_flags;      // 标志（SHF_ALLOC, SHF_EXECINSTR 等）
    uint64_t sh_addr;       // 运行时虚拟地址
    uint64_t sh_offset;     // 文件偏移
    uint64_t sh_size;       // Section 大小
    uint32_t sh_link;       // 链接到其他 Section 的索引
    uint32_t sh_info;       // 额外信息（如重定位目标 Section）
    uint64_t sh_addralign;  // 对齐要求
    uint64_t sh_entsize;    // 如果是表，每个条目的大小
};
```

**关键观察**：
- `sh_addr` 是运行时地址（加载到内存后的虚拟地址）
- `sh_offset` 是文件偏移（在 so 文件中的位置）
- `sh_flags` 决定运行时属性：
  - `A` (SHF_ALLOC)：需要加载到内存
  - `X` (SHF_EXECINSTR)：可执行（代码段）
  - `W` (SHF_WRITE)：可写（数据段）

---

### 2.2 关键 Section 详解

从测试输出可以看到 libc.so 的关键 Section：

| Section | 类型 | 运行时地址 | 说明 |
|---------|------|-----------|------|
| `.dynsym` | DYNSYM | 0x2f8 | 动态符号表：导出/导入的函数和变量 |
| `.dynstr` | STRTAB | 0xc888 | 动态字符串表：符号名称的字符串池 |
| `.gnu.hash` | GNU_HASH | 0x9bc0 | GNU 哈希表：加速符号查找 |
| `.rela.dyn` | RELA | 0x11008 | 数据重定位表（已初始化数据的重定位）|
| `.rela.plt` | RELA | 0x17110 | PLT 重定位表（函数跳转的重定位）|
| `.plt` | PROGBITS | 0xef890 | 过程链接表：延迟绑定的跳板代码 |
| `.got.plt` | PROGBITS | 0xf6e50 | PLT 的全局偏移表：存储函数地址 |
| `.text` | PROGBITS | 0x54000 | 代码段：实际的函数实现 |

**为什么 `.got.plt` 有 `W` 标志？**
因为动态链接器需要在运行时修改 GOT 条目，将其从初始值（指向 PLT 的解析代码）改为实际的函数地址。

---

### 2.3 so 间函数跳转的完整流程（核心！）

这是理解动态链接最关键的部分。假设 so A 调用 so B 的 `malloc` 函数：

#### 阶段 1：编译时（链接器处理）

```
so A 的代码中调用 malloc():
    call malloc@PLT

链接器生成：
    1. .rela.plt 中添加重定位条目："需要解析 malloc"
    2. .dynsym 中添加符号条目：malloc（但地址为 0）
    3. .plt 中生成跳板代码
    4. .got.plt 中预留槽位（初始指向 PLT 解析代码）
```

#### 阶段 2：加载时（动态链接器处理）

```
1. 加载 so A 和 so B 到内存
2. 处理 .rela.dyn（数据重定位）- 此时立即完成
3. 不处理 .rela.plt（函数重定位）- 延迟到第一次调用
```

#### 阶段 3：运行时（第一次调用 malloc）

```
调用流程（延迟绑定 Lazy Binding）：

[1] so A 代码执行: call malloc@PLT
           |
           v
[2] 跳转到 .plt 中的 malloc 桩代码：
    .plt 条目（每个外部函数一个）：
        jmp *GOT[n]    # 第一次：GOT[n] 指向 .plt 的下一条指令
        push n         # 压入重定位条目索引
        jmp PLT0       # 跳转到 PLT 首条目
           |
           v
[3] PLT0 通用解析代码：
        push GOT[1]    # 压入 link_map 指针（so 标识）
        jmp *GOT[2]    # 跳转到 _dl_runtime_resolve
           |
           v
[4] _dl_runtime_resolve（动态链接器函数）：
    - 根据 link_map 找到 so A
    - 根据重定位索引 n 找到 .rela.plt[n]
    - 根据 .rela.plt[n] 找到符号名 "malloc"
    - 在依赖库（so B）中查找 malloc 地址
    - 更新 GOT[n] = malloc 的实际地址
    - 跳转到 malloc 执行
           |
           v
[5] malloc 执行完成，返回到 so A
```

**关键洞察**：
- **第一次调用**：经过完整的解析流程，较慢
- **GOT[n] 被更新**：指向实际的 malloc 地址
- **后续调用**：`jmp *GOT[n]` 直接跳转到 malloc，无需解析

#### 内存布局示意图

```
so A 内存布局：
+------------------+
| .text (代码)     |
|   call malloc    |---+ 编译时确定的相对跳转
+------------------+   |
| .plt (跳板)      |   |
|   jmp *GOT[5]    |<--+ 跳转到 GOT 条目
|   push 5         |       |
|   jmp PLT0       |       |
+------------------+       |
| .got.plt         |       |
|   GOT[0] = .dynamic 地址 |       |
|   GOT[1] = link_map 指针 |       |
|   GOT[2] = _dl_runtime_resolve
|   GOT[3] = ...   |       |
|   GOT[5] = .plt 解析代码 |<------+
+------------------+       |
                           |
so B 内存布局：            |
+------------------+       |
| .text            |       |
|   malloc:        |<------+ 实际函数地址
|     ...          |
+------------------+
```

---

### 2.4 代码验证：PLT/GOT 关系

我们可以通过 readelf 查看具体的 PLT/GOT 关系：

```bash
# 查看重定位条目
readelf -r /system/lib64/libc.so | grep malloc

# 查看动态符号
readelf --dyn-syms /system/lib64/libc.so | grep malloc

# 查看 PLT 条目（反汇编）
objdump -d /system/lib64/libc.so --section=.plt | head -50
```

**典型输出分析**：
```
Relocation section '.rela.plt' at offset 0x17110:
  Offset          Info           Type           Sym. Value    Sym. Name
00000000f6e50  000000000007 R_AARCH64_JUMP_SL 0000000000000000 malloc
# GOT[?] 偏移 0xf6e50，类型是跳转槽（JUMP_SLOT），符号是 malloc
```

---

### 2.5 C++ 热更与 ELF 的关系

理解了 PLT/GOT 机制，就能理解 C++ 热更的实现原理：

#### 热更核心思想

**问题**：C++ so 不能像 Java 那样直接替换类，因为机器码已经编译好了。

**解决方案**：利用 GOT 是可写的特性，修改 GOT 条目指向新函数！

#### 热更实现流程

```
原始状态：
    so A 调用 so B 的 func()
    GOT[n] = 0x12345678 (so B 中的 func 地址)

热更步骤：
    1. 加载新 so B'（包含修复后的 func'）
    2. 找到 so A 的 GOT[n]
    3. 修改 GOT[n] = 0xabcdef00 (so B' 中的 func' 地址)

结果：
    so A 再次调用 func() 时，实际执行的是 func'()
```

#### 与 ByteHook 的关系

我们项目中使用的 ByteHook 就是基于这个原理：

```cpp
// ByteHook 内部实现（简化）
void* hook_function(const char* target_func, void* new_func) {
    // 1. 找到目标函数的 GOT 条目
    void** got_entry = find_got_entry(target_func);

    // 2. 保存原函数地址
    void* orig_func = *got_entry;

    // 3. 修改 GOT 条目指向新函数
    *got_entry = new_func;

    // 4. 返回原函数地址（供调用原函数时使用）
    return orig_func;
}
```

**ByteHook 的优势**：
- 不需要修改目标 so 文件
- 运行时动态 hook
- 支持 inline hook（直接修改函数开头的机器码）

---

### 2.6 代码实现细节

在 `elf_sections.cpp` 中，关键逻辑：

```cpp
// 1. 解析 Section Header Table
// 读取每个 section header，填充 SectionInfo 结构

// 2. 加载 Section 名称字符串表 (.shstrtab)
// shstrtab 存储所有 section 的名称

// 3. 识别关键 section
for (auto& sec : sections) {
    if (sec.name == ".dynsym") dynsymSection = &sec;
    if (sec.name == ".rela.plt") relaPltSection = &sec;
    // ...
}

// 4. Section 之间的链接关系
// .rela.plt.sh_link 指向 .dynsym（重定位条目引用符号表）
// .dynsym.sh_link 指向 .dynstr（符号名称在字符串表中）
```

---

### 2.7 学习要点总结

1. **Section vs Segment**：
   - Section 用于链接（编译时）
   - Segment 用于加载（运行时）
   - `.text`、`.plt` 等最终会合并到 PT_LOAD segment

2. **延迟绑定（Lazy Binding）**：
   - 目的：加快 so 加载速度
   - 代价：第一次函数调用稍慢
   - 关键：GOT 条目在第一次调用后才被填充实际地址

3. **so 间跳转三要素**：
   - **PLT**：跳板代码，第一次调用时触发解析
   - **GOT**：地址表，存储解析后的函数地址
   - **动态链接器**：`_dl_runtime_resolve` 完成符号查找

4. **热更原理**：
   - GOT 是可写的（`WA` 标志）
   - 修改 GOT 条目 = 替换函数实现
   - 这是 PLT hook 和 C++ 热更的基础

---

### 2.8 下一步预告

步骤 3 将解析：
- **动态符号表（.dynsym）**：查看导出/导入的函数
- **重定位表（.rela.plt）**：理解重定位条目的具体结构
- **PLT 条目反汇编**：查看实际的跳转代码

目标是能够手动解析一个函数调用，从 `.dynsym` 找到符号名，从 `.rela.plt` 找到 GOT 位置，最终计算出函数地址！