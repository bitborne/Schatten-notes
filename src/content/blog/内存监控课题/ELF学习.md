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

---

## 附录：关键术语深度解析

> 在继续步骤 3 之前，必须先彻底理解这些术语。这些概念是理解 so 跳转机制的基石。

### A. link_map 是什么？

**定义**：`link_map` 是动态链接器（linker/loader）维护的**已加载 so 链表节点**。

**数据结构**（简化）：

```c
struct link_map {
    ElfW(Addr) l_addr;          // so 加载基地址（加载到内存后的起始地址）
    char *l_name;               // so 文件路径（如 "/system/lib64/libc.so"）
    ElfW(Dyn) *l_ld;            // 指向 .dynamic section（动态链接信息）
    struct link_map *l_next;    // 链表下一个 so
    struct link_map *l_prev;    // 链表上一个 so
    // ... 还有更多字段用于重定位、符号查找等
};
```

**作用**：
1. **so 的唯一标识**：动态链接器通过 link_map 知道"这是哪个 so"
2. **基地址记录**：so 加载到内存的地址是随机的（ASLR），link_map 记录实际地址
3. **符号查找**：在解析重定位时，通过 link_map 找到 so 的符号表

**实际例子**：

```
进程启动时加载了3个 so：
+-------------+     +-------------+     +-------------+
|  linker     |<--->|  libc.so    |<--->|  libdemo.so |
|  (link_map) |     |  (link_map) |     |  (link_map) |
+-------------+     +-------------+     +-------------+
       ^                                          |
       +------------------------------------------+
       双向链表，linker 可以通过 l_next/l_prev 遍历所有 so

link_map 中的关键信息：
- l_addr = 0x7f8a1b0000  ← libc.so 实际加载到内存的地址
- l_ld = 0x7f8a1f6b48    ← 指向 .dynamic section（从 Section Header 可以看到地址）
```

**在延迟绑定中的作用**：

```
第一次调用 malloc 时：
1. PLT 代码 push GOT[1] → GOT[1] 就是 link_map 指针
2. 调用 _dl_runtime_resolve(link_map, reloc_index)
3. _dl_runtime_resolve 通过 link_map 找到 libc.so 的符号表
4. 在符号表中查找 "malloc" 的实际地址
```

---

### B. _dl_runtime_resolve 具体做什么？

**定义**：`_dl_runtime_resolve` 是**动态链接器的核心函数**，负责**运行时符号解析**。

**调用时机**：
- 只在**第一次**调用外部函数时执行
- 后续调用直接跳转到 GOT 中已填充的地址

**完整执行流程**：

```
调用 _dl_runtime_resolve(link_map, reloc_index) 时：

[步骤 1] 通过 link_map 找到 so 的 .dynamic section
    link_map->l_ld → .dynamic section

    .dynamic section 包含：
    - DT_SYMTAB: .dynsym 的地址
    - DT_STRTAB: .dynstr 的地址
    - DT_JMPREL: .rela.plt 的地址

[步骤 2] 通过 reloc_index 找到重定位条目
    rela_entry = DT_JMPREL + reloc_index * sizeof(Rela)

    Rela 结构：
    - r_offset: GOT 条目的地址（需要填充的位置）
    - r_info: 符号表索引 + 重定位类型
    - r_addend: 加数（通常为 0）

[步骤 3] 从重定位条目提取符号名
    sym_index = ELF64_R_SYM(rela.r_info)  // 符号表索引
    sym = DT_SYMTAB[sym_index]            // 符号条目
    sym_name = DT_STRTAB[sym.st_name]     // 符号名字符串

    例如：sym_name = "malloc"

[步骤 4] 在依赖库中查找符号地址
    遍历当前 so 的所有依赖（DT_NEEDED）：
    - 打开依赖 so
    - 在依赖 so 的 .dynsym 中查找 "malloc"
    - 找到后返回符号地址（sym.st_value + 依赖 so 的基地址）

    假设在 libc.so 中找到：
    malloc_addr = 0x7f8a1c2340

[步骤 5] 更新 GOT 条目
    *(rela.r_offset) = malloc_addr

    现在 GOT[n] = 0x7f8a1c2340（malloc 的实际地址）

[步骤 6] 跳转到目标函数
    jmp malloc_addr

    从此之后，调用 malloc 直接跳转到 0x7f8a1c2340
```

**为什么只需要两个参数？**
- `link_map`：告诉动态链接器"我在哪个 so 里"
- `reloc_index`：告诉动态链接器"我要解析第几个外部函数"

**性能优化**：
- 第一次调用：慢（需要完整解析）
- 第二次调用：快（GOT 已填充，直接跳转）
- 这就是"延迟绑定"（Lazy Binding）的意义

---

### C. 重定位类型 R_AARCH64_JUMP_SLOT 是什么意思？

**定义**：`R_AARCH64_JUMP_SLOT` 是 **ARM64 架构下的 PLT 重定位类型**。

**重定位类型分类**：

| 类型 | 用途 | 说明 |
|------|------|------|
| `R_AARCH64_ABS64` | 绝对地址 | 直接填充 64 位地址 |
| `R_AARCH64_GLOB_DAT` | 全局数据 | 用于 .rela.dyn（数据重定位）|
| `R_AARCH64_JUMP_SLOT` | 跳转槽 | 用于 .rela.plt（函数重定位）|
| `R_AARCH64_RELATIVE` | 相对地址 | 基地址 + 偏移 |

**R_AARCH64_JUMP_SLOT 的特殊之处**：

```cpp
// 重定位条目结构（Elf64_Rela）
typedef struct {
    uint64_t r_offset;    // GOT 条目的地址
    uint64_t r_info;      // 类型 + 符号索引
    int64_t  r_addend;    // 加数
} Elf64_Rela;

// r_info 的编码
#define ELF64_R_SYM(i)    ((i) >> 32)           // 高 32 位：符号表索引
#define ELF64_R_TYPE(i)   ((i) & 0xffffffff)    // 低 32 位：重定位类型

// R_AARCH64_JUMP_SLOT = 1026 (0x402)
```

**实际处理过程**：

```
重定位条目（.rela.plt 中的一个条目）：
- r_offset = 0x00000000000f6e50  ← GOT[3] 的地址（假设是第3个 GOT 条目）
- r_info = 0x0000000400000402   ← 符号索引=4，类型=R_AARCH64_JUMP_SLOT
- r_addend = 0

动态链接器看到 R_AARCH64_JUMP_SLOT 时：
1. 从 r_info 提取符号索引：4
2. 从 .dynsym[4] 找到符号名（如 "printf"）
3. 在其他 so 中找到 printf 的地址
4. 将地址写入 GOT[3]（即 r_offset 指向的位置）
5. 完成！
```

**为什么需要区分类型？**
- 不同类型的重定位需要不同的计算方式
- `JUMP_SLOT` 专门用于函数调用，可以直接写地址
- `GLOB_DAT` 用于全局变量，可能需要加上基地址

---

### D. GOT[0]、GOT[1]、GOT[2] 为什么是特殊的？

**GOT 结构**：
```
.got.plt section（运行时内存布局）：
+--------------+
| GOT[0]       |  → .dynamic section 的地址（供 PLT 代码使用）
+--------------+
| GOT[1]       |  → link_map 指针（标识当前 so）
+--------------+
| GOT[2]       |  → _dl_runtime_resolve 函数的地址
+--------------+
| GOT[3]       |  → 第1个外部函数的地址（初始指向 PLT 解析代码）
+--------------+
| GOT[4]       |  → 第2个外部函数的地址
+--------------+
| ...          |  → 更多外部函数
+--------------+
```

**详细解释**：

#### GOT[0] = .dynamic section 地址
```
用途：
- PLT 代码可能需要访问动态链接信息
- 通过 GOT[0] 可以快速找到 .dynamic

.dynamic section 包含：
- DT_SYMTAB（符号表地址）
- DT_STRTAB（字符串表地址）
- DT_HASH（哈希表地址）
- DT_PLTGOT（GOT 地址）
- DT_JMPREL（PLT 重定位表地址）
```

#### GOT[1] = link_map 指针
```
用途：
- 标识"当前是哪个 so"
- _dl_runtime_resolve 的第一个参数

为什么需要？
- 多个 so 可能调用同一个外部函数
- link_map 告诉动态链接器"我在哪个 so 里"
- 动态链接器通过 link_map 找到该 so 的重定位表和符号表
```

#### GOT[2] = _dl_runtime_resolve 地址
```
用途：
- PLT 通用解析代码跳转到这里
- 即 _dl_runtime_resolve 函数的入口地址

为什么存这个地址？
- 不同系统的动态链接器位置不同
- GOT[2] 在加载时由动态链接器填充
- PLT 代码通过 "jmp *GOT[2]" 调用解析函数
```

#### GOT[3+] = 实际外部函数地址
```
用途：
- 存储解析后的函数地址
- 初始时指向 PLT 中的解析代码

初始状态：
GOT[3] = PLT 条目地址 + 6 字节（指向 push index 指令）

解析后：
GOT[3] = 0x7f8a1c2340（malloc 的实际地址）
```

---

### E. GOT[n] 的 n 是什么？如何确定？

**n 的定义**：
- n 是 **GOT 条目索引**，从 0 开始
- 每个外部函数对应一个 GOT 条目
- n = 0,1,2 是保留的，n ≥ 3 是实际函数

**如何确定 n？**

#### 方法 1：通过 .rela.plt 计算
```
.rela.plt 是一个数组，每个元素对应一个 GOT 条目：
- rela[0] → GOT[3]（第一个外部函数）
- rela[1] → GOT[4]
- rela[n] → GOT[n+3]

公式：GOT 索引 = 数组索引 + 3
```

#### 方法 2：通过 r_offset 计算
```c
// 从重定位条目的 r_offset 可以计算 GOT 索引
// 假设 .got.plt 起始地址是 0xf6e50

GOT 条目大小 = 8 字节（64位指针）

r_offset = 0xf6e50 + n * 8

// 从 r_offset 反推 n：
n = (r_offset - got_plt_start) / 8
```

#### 实际例子
```
从 readelf -r 输出：
Offset          Info           Type           Sym. Value    Sym. Name
00000000f6e50  0000000400000402 R_AARCH64_JUMP_SL 0000000000000000 malloc@LIBC

计算：
- r_offset = 0xf6e50
- .got.plt 起始地址 = 0xf6e50（从 Section Header 可见）
- GOT 索引 = (0xf6e50 - 0xf6e50) / 8 = 0 → 但前面有3个保留条目
- 实际函数索引 = 0（malloc 是第一个外部函数）
- GOT 条目 = GOT[3]
```

---

### F. PLT0 是什么？通用解析代码详解

**PLT0 定义**：
- `.plt` section 的**第一个条目**（条目 0）
- 所有外部函数第一次调用时都会跳转到 PLT0
- PLT0 调用 `_dl_runtime_resolve`

**ARM64 架构的 PLT0 代码**：
```asm
# .plt 起始地址：0xef890（从 Section Header 可见）

# PLT0 条目（每个 so 只有一个）：
0xef890: adrp x16, #0xf6000          # 计算 GOT 页地址
0xef894: ldr  x17, [x16, #3600]     # 加载 GOT[2] = _dl_runtime_resolve
0xef898: add  x16, x16, #3600        # x16 = &GOT[2]
0xef89c: br   x17                    # 跳转到 _dl_runtime_resolve
```

**每条指令详解**：

```asm
adrp x16, #0xf6000
# 功能：将 GOT 所在页的基地址加载到 x16
# 说明：ARM64 使用 4KB 页，adrp 加载页基地址（低12位清零）
# 结果：x16 = 0xf6000

ldr x17, [x16, #3600]
# 功能：从 GOT[2] 加载 _dl_runtime_resolve 地址
# 计算：0xf6000 + 3600 = 0xf6e50 = GOT[0] 地址？不对...
# 实际上：GOT[2] 的偏移是 16 字节（3 * 8 = 24？需要重新计算）
# 假设 GOT[2] 在 0xf6e50 + 16 = 0xf6e60

add x16, x16, #3600
# 功能：x16 指向 GOT[2] 的地址
# 这个地址会作为参数传递给 _dl_runtime_resolve（虽然实际上不需要）

br x17
# 功能：跳转到 x17 保存的地址，即 _dl_runtime_resolve
```

**PLT 普通条目**（每个外部函数一个）：
```asm
# 以 malloc 为例（假设是第1个外部函数，索引=0）：
0xef8a0: adrp x16, #0xf6000          # 计算 GOT 页地址
0xef8a4: ldr  x17, [x16, #3616]     # 加载 GOT[3]（malloc 的 GOT 条目）
0xef8a8: add  x16, x16, #3616        # x16 = &GOT[3]
0xef8ac: br   x17                    # 跳转到 GOT[3] 保存的地址

# 如果 GOT[3] 未解析，它指向 0xef8b0（下一条指令）：
0xef8b0: stp  x16, x30, [sp, #-16]!  # 保存寄存器
0xef8b4: mov  w17, #0                # w17 = 重定位索引（0）
0xef8b8: b    0xef890                # 跳转到 PLT0

# PLT0 会调用 _dl_runtime_resolve(link_map, 0)
```

**关键洞察**：
- 每个 PLT 条目**第一次执行**时会跳转到 PLT0
- PLT0 调用 `_dl_runtime_resolve` 解析符号
- 解析完成后，**GOT 条目被更新为实际地址**
- **第二次执行**时，`br x17` 直接跳转到目标函数

---

## 当前进度总结

### 已完成的步骤

| 步骤 | 内容 | 状态 | 关键实现 |
|------|------|------|----------|
| **步骤 1** | ELF Header 解析 | ✅ 完成 | `elf_types.h/cpp` - 支持 32/64 位、大小端 |
| **步骤 2** | Section Header 解析 | ✅ 完成 | `elf_sections.h/cpp` - 解析所有 Section 元数据，识别关键 Section |

### 当前能力

1. **可以解析任意 so 文件的 ELF Header**
   - 识别文件类型、架构、字节序
   - 获取 Program Header 和 Section Header 位置

2. **可以列出所有 Section**
   - 显示 Section 名称、类型、地址、偏移、大小
   - 识别关键 Section（.dynsym、.plt、.got.plt、.rela.plt 等）

3. **理解 so 跳转的理论机制**
   - PLT/GOT 延迟绑定原理
   - 动态链接器的工作流程
   - C++ 热更的实现基础

### 尚未完成的能力

1. **未解析 .dynsym** - 无法查看具体的导出/导入函数名
2. **未解析 .rela.plt** - 无法建立"函数名 → GOT 位置"的映射
3. **未反汇编 PLT** - 无法查看实际的跳转指令
4. **未实现内存映射** - 无法在运行时分析已加载的 so

---

## 步骤 3 目标（深度 C：完整版）

基于用户要求，步骤 3 将实现：

### 功能目标

| 功能 | 描述 | 对比 readelf |
|------|------|--------------|
| **动态符号表解析** | 显示 .dynsym 中所有符号（函数名、地址、类型） | 类似 `readelf --dyn-syms` |
| **重定位表解析** | 显示 .rela.plt 条目，建立"函数名 → GOT 偏移"映射 | 类似 `readelf -r` |
| **PLT 反汇编** | 反汇编 .plt 条目，显示每条指令的含义 | 类似 `objdump -d --section=.plt` |
| **函数调用追踪** | 手动追踪一个函数（如 malloc）的完整链路 | **readelf 无法做到！** |
| **GOT 状态模拟** | 显示 GOT 条目在加载时、第一次调用后、后续调用的状态变化 | **readelf 无法做到！** |

### 学习深度

1. **代码层面**：详细注释每个解析步骤，说明数据结构的内存布局
2. **文档层面**：用图示展示数据结构关系，用流程图展示解析过程
3. **实践层面**：提供内存 dump 示例，展示实际的二进制数据

### 预期输出示例

```
$ elf_reader --deep /system/lib64/libc.so malloc

函数调用链路追踪: malloc

[1] 符号表查找:
    .dynsym[12]:
        st_name  = 0x1234 ("malloc")
        st_value = 0x00000000 (未定义，需要重定位)
        st_info  = 0x12 (STB_GLOBAL, STT_FUNC)

[2] 重定位表查找:
    .rela.plt[7]:
        r_offset = 0xf6e50 (GOT[10] 的地址)
        r_info   = 0x0000000c00000402 (符号索引=12, 类型=R_AARCH64_JUMP_SLOT)
        r_addend = 0

[3] PLT 条目分析:
    .plt[7] 地址: 0xef8c0
    反汇编:
        0xef8c0: adrp x16, 0xf6000    # 计算 GOT 页地址
        0xef8c4: ldr  x17, [x16, #3648] # 加载 GOT[10]
        0xef8c8: add  x16, x16, #3648   # x16 = &GOT[10]
        0xef8cc: br   x17              # 跳转到 GOT[10] 保存的地址

[4] GOT 条目状态:
    加载时:   GOT[10] = 0xef8d0 (指向 PLT 解析代码)
    解析后:   GOT[10] = 0x7f8a1c2340 (malloc 实际地址)

[5] 调用流程总结:
    第一次调用: call malloc → .plt[7] → GOT[10]=0xef8d0 → 解析代码 → _dl_runtime_resolve → 更新 GOT[10] → malloc
    后续调用:   call malloc → .plt[7] → GOT[10]=0x7f8a1c2340 → malloc (直接跳转)
```

### 与 readelf 的区别

| 能力 | readelf | 我们的 elf_reader |
|------|---------|-------------------|
| 显示符号表 | ✅ | ✅ |
| 显示重定位 | ✅ | ✅ |
| 反汇编 PLT | ❌ (需要 objdump) | ✅ |
| 追踪单函数完整链路 | ❌ | ✅ |
| 模拟 GOT 状态变化 | ❌ | ✅ |
| 运行时分析已加载 so | ❌ | ✅ (步骤 4) |

**我们的优势**：
- 将分散的信息（符号表、重定位表、PLT、GOT）整合为完整的调用链路
- 提供运行时视角，展示延迟绑定的动态过程
- 为理解 C++ 热更和 PLT Hook 提供实践基础

---

**下一步行动**：
1. 实现 `elf_symbols.h/cpp` - 解析 .dynsym 和 .dynstr
2. 实现 `elf_relocations.h/cpp` - 解析 .rela.plt 和 .rela.dyn
3. 实现 `elf_plt.h/cpp` - 反汇编 ARM64 PLT 条目
4. 更新 `main.cpp` - 添加 `--deep` 选项用于深度分析单个函数

---

## 步骤 3：动态符号表与重定位表解析

**目标**：真正读懂 .dynsym 和 .rela.plt，建立"函数名 → GOT 偏移"的完整映射

**实现文件**：

- `app/src/main/cpp/elf_reader/elf_symbols.h/cpp`：动态符号表解析
- `app/src/main/cpp/elf_reader/elf_relocations.h/cpp`：重定位表解析
- 更新 `app/src/main/cpp/elf_reader/main.cpp`

**测试结果**：libc.so 共 1448 个函数符号，48 个 PLT 条目，与 GNU readelf 完全一致

---

### 3.1 为什么需要解析 .dynsym 和 .rela.plt？

步骤 2 已经知道 `.dynsym` 的**位置**和**大小**（如地址 `0x2f8`，大小 `0x8b38`），但还不知道里面**存了哪些函数**。

这两个 section 共同构成了动态链接的"地图"：

```
.dynsym（符号表）：记录函数的名字和基本信息
    ↕ 配合（符号名字符串存储在 .dynstr 里）
.dynstr（字符串表）：存储所有符号名的字符串池

.rela.plt（重定位表）：每个外部函数在 GOT 中的位置
    ↕ 引用（通过索引找到 .dynsym 中的对应符号）
.dynsym（符号表）：通过索引找到函数名
```

完整的信息链路：
```
.rela.plt[n].r_info >> 32 = symIndex
.dynsym[symIndex].st_name = nameOffset
.dynstr[nameOffset] = "malloc"

.rela.plt[n].r_offset = GOT[n+3] 的运行时地址
```

---

### 3.2 Elf64_Sym：动态符号表条目详解

**.dynsym** section 是一个 `Elf64_Sym` 结构体数组，每个元素描述一个符号（函数、变量等）。

#### 3.2.1 内存布局（64-bit）

```
Elf64_Sym 大小 = 24 bytes（0x18）

偏移 |  字段名   | 大小  | 含义
-----|-----------|-------|-------
  0  | st_name   | 4字节 | 符号名在 .dynstr 中的字节偏移（字符串索引）
  4  | st_info   | 1字节 | 高4位=绑定类型(bind)，低4位=符号类型(type)
  5  | st_other  | 1字节 | 可见性（通常为 0=DEFAULT）
  6  | st_shndx  | 2字节 | 关联的 Section 索引（0=未定义=外部符号）
  8  | st_value  | 8字节 | 符号值：若已定义=函数在本 so 中的偏移；未定义=0
 16  | st_size   | 8字节 | 符号大小（函数体字节数）
```

**关键观察：64位布局中 st_info/st_other/st_shndx 在 st_value 之前！**

#### 3.2.2 内存布局（32-bit）⚠️ 与 64-bit 字段顺序不同！

```
Elf32_Sym 大小 = 16 bytes（0x10）

偏移 |  字段名   | 大小  | 含义
-----|-----------|-------|-------
  0  | st_name   | 4字节 | 符号名在 .dynstr 中的字节偏移
  4  | st_value  | 4字节 | 符号值（⚠️ 在 st_info 之前！）
  8  | st_size   | 4字节 | 符号大小
 12  | st_info   | 1字节 | 绑定类型 + 符号类型（⚠️ 在末尾！）
 13  | st_other  | 1字节 | 可见性
 14  | st_shndx  | 2字节 | Section 索引
```

这个差异非常容易踩坑：32位 ELF 的 `st_value` 在 `st_info` 前面，64位的 `st_info` 在 `st_value` 前面。解析代码必须根据 `is64bit` 分支处理：

```cpp
if (is64bit) {
    st_name  = readVal<uint32_t>(entry + 0,  isLittleEndian);
    st_info  = readVal<uint8_t> (entry + 4,  isLittleEndian);
    st_other = readVal<uint8_t> (entry + 5,  isLittleEndian);
    st_shndx = readVal<uint16_t>(entry + 6,  isLittleEndian);
    st_value = readVal<uint64_t>(entry + 8,  isLittleEndian);
    st_size  = readVal<uint64_t>(entry + 16, isLittleEndian);
} else {
    st_name  = readVal<uint32_t>(entry + 0,  isLittleEndian);
    st_value = readVal<uint32_t>(entry + 4,  isLittleEndian);  // 注意顺序！
    st_size  = readVal<uint32_t>(entry + 8,  isLittleEndian);
    st_info  = readVal<uint8_t> (entry + 12, isLittleEndian);
    st_other = readVal<uint8_t> (entry + 13, isLittleEndian);
    st_shndx = readVal<uint16_t>(entry + 14, isLittleEndian);
}
```

#### 3.2.3 st_info 编码解析

`st_info` 是一个1字节字段，用位域编码了两个信息：

```
st_info（1 byte）：
  +---------+---------+
  | 高 4 位  | 低 4 位  |
  |  bind   |  type   |
  +---------+---------+

bind（绑定类型）：
  STB_LOCAL  = 0   局部符号，文件内部可见，不参与动态链接
  STB_GLOBAL = 1   全局符号，可被其他 so 引用（导出函数）
  STB_WEAK   = 2   弱符号，可被同名全局符号覆盖

type（符号类型）：
  STT_NOTYPE  = 0  无类型
  STT_OBJECT  = 1  数据对象（全局变量）
  STT_FUNC    = 2  函数（⭐ 最重要！）
  STT_SECTION = 3  Section 引用
  STT_FILE    = 4  源文件名
  STT_TLS     = 6  线程本地存储变量

解码示例：
  st_info = 0x12
  bind = 0x12 >> 4 = 0x1 = STB_GLOBAL
  type = 0x12 & 0x0f = 0x2 = STT_FUNC
  → 全局导出函数
```

代码实现：
```cpp
sym.bind = st_info >> 4;       // 高4位
sym.type = st_info & 0x0f;     // 低4位
```

#### 3.2.4 st_shndx 的特殊值

`st_shndx`（section index）标志符号"在哪个 section 里"：

```
SHN_UNDEF = 0        未定义，需要从其他 so 中解析（外部符号）
SHN_ABS   = 0xfff1   绝对地址，不受重定位影响
SHN_COMMON = 0xfff2  公共块（未初始化全局变量）
1~N           定义在本 so 的第 N 个 section 中（已定义符号）
```

**关键判断**：`shndx == SHN_UNDEF(0)` 说明是外部符号，需要从依赖库中加载，这些正是 .rela.plt 中记录的符号。

---

### 3.3 .dynstr：字符串表的工作原理

`.dynstr` section 是一个连续的字符串池，所有符号名依次存储（以 `\0` 分隔）：

```
.dynstr 内存布局（示例）：
偏移  内容
0x00: '\0'          ← 第一个字节是空字符（索引0=空名称）
0x01: 'm','a','l',...,'c','\0'  ← "malloc"（偏移=1）
0x08: 'f','r','e','e','\0'      ← "free"（偏移=8）
0x0d: 'p','r','i','n','t','f','\0' ← "printf"（偏移=13）
...
```

`st_name` 是字节偏移，从 `.dynstr` 起始地址加上 `st_name` 即得到符号名：

```cpp
if (st_name < dynstrSize) {
    sym.name = reinterpret_cast<const char*>(dynstrData + st_name);
}
```

这里 `reinterpret_cast<const char*>` 是安全的，因为 `.dynstr` 中的字符串以 `\0` 结尾，`std::string` 构造时会自动在 `\0` 处截断。

---

### 3.4 SymbolInfo：我们的封装结构

我们用 `SymbolInfo` 封装原始的 `Elf64_Sym` 字段，**使用简化字段名**（省略 `st_` 前缀，更易读）：

```cpp
struct SymbolInfo {
    uint32_t index;      // 在 .dynsym 数组中的索引（0-based）
    std::string name;    // 符号名（已从 .dynstr 解析）
    uint8_t bind;        // 绑定类型（STB_GLOBAL=1 等）
    uint8_t type;        // 符号类型（STT_FUNC=2 等）
    uint8_t other;       // 可见性（通常0）
    uint16_t shndx;      // Section 索引（0=外部，0xfff1=绝对）
    uint64_t value;      // 符号地址/偏移（外部函数为0）
    uint64_t size;       // 符号大小（字节）

    bool isFunction()  const { return type == STT_FUNC; }
    bool isUndefined() const { return shndx == SHN_UNDEF; }
    bool isGlobal()    const { return bind == STB_GLOBAL; }
    // ...
};
```

⚠️ **重要**：`SymbolInfo` 使用简化字段名（`value`，不是 `st_value`；`size`，不是 `st_size`）。在局部变量中用 `st_value` 读取，赋值给 `sym.value`：

```cpp
st_value = readVal<uint64_t>(entry + 8, isLittleEndian);
sym.value = st_value;   // 简化字段名
```

---

### 3.5 Elf64_Rela：重定位表条目详解

**.rela.plt** section 是一个 `Elf64_Rela` 结构体数组，每个元素描述一个"需要动态链接器填充的位置"。

#### 3.5.1 内存布局

```
Elf64_Rela 大小 = 24 bytes（0x18）

偏移 |  字段名  | 大小  | 含义
-----|----------|-------|-------
  0  | r_offset | 8字节 | 需要被修改的内存地址（即对应 GOT 条目的运行时地址）
  8  | r_info   | 8字节 | 高32位=符号表索引，低32位=重定位类型
 16  | r_addend | 8字节 | 加数（int64_t，有符号；JUMP_SLOT 通常为0）
```

#### 3.5.2 r_info 的编码

`r_info` 是8字节，实际上同时存储了两个信息：

```
r_info（8 bytes = 64 bits）：
  +---------------------+----------------------+
  |    高 32 位           |       低 32 位        |
  |    符号表索引(symIndex) |  重定位类型(type)     |
  +---------------------+----------------------+

解码：
  symIndex = (uint32_t)(r_info >> 32)          // 右移32位取高半部分
  type     = (uint32_t)(r_info & 0xffffffff)   // 掩码取低32位

示例：
  r_info   = 0x0000001500000402
  symIndex = 0x0000001500000402 >> 32 = 0x15 = 21
  type     = 0x0000001500000402 & 0xffffffff = 0x402 = 1026 = R_AARCH64_JUMP_SLOT
```

代码实现：
```cpp
rel.info    = readVal<uint64_t>(entry + 8, isLittleEndian);
rel.symIndex = static_cast<uint32_t>(rel.info >> 32);
rel.type    = static_cast<uint32_t>(rel.info & 0xffffffff);
```

#### 3.5.3 重定位类型

ARM64 架构下，.rela.plt 中的重定位类型几乎全是 `R_AARCH64_JUMP_SLOT`：

```cpp
enum ElfAArch64Reloc : uint32_t {
    R_AARCH64_NONE         = 0,    // 空操作
    R_AARCH64_ABS64        = 257,  // 填充绝对64位地址
    R_AARCH64_COPY         = 1024, // 复制符号值到目标
    R_AARCH64_GLOB_DAT     = 1025, // .rela.dyn 中全局变量重定位
    R_AARCH64_JUMP_SLOT    = 1026, // .rela.plt 中函数跳转槽 ⭐ 最重要
    R_AARCH64_RELATIVE     = 1027, // 基地址+加数（位置无关代码）
    R_AARCH64_TLS_DTPREL64 = 1028, // TLS 动态偏移
    R_AARCH64_TLS_TPREL64  = 1029, // TLS 静态偏移
    R_AARCH64_TLSDESC      = 1031, // TLS 描述符
    R_AARCH64_IRELATIVE    = 1032  // 间接相对地址（ifunc）
};
```

---

### 3.6 rela[n] → GOT[n+3] 映射关系的推导

这是步骤3最核心的知识点：**重定位条目的索引与 GOT 条目索引的关系**。

#### 3.6.1 直接从 r_offset 推导

`.rela.plt` 中每个条目的 `r_offset` 就是"要写入的 GOT 条目的运行时地址"。

从 libc.so 的测试数据可以验证：
```
.got.plt section 起始地址：0xf6e50（来自 Section Header 的 sh_addr）
每个 GOT 条目大小：8 字节（64位指针）

GOT[0] 地址 = 0xf6e50 + 0 * 8 = 0xf6e50
GOT[1] 地址 = 0xf6e50 + 1 * 8 = 0xf6e58
GOT[2] 地址 = 0xf6e50 + 2 * 8 = 0xf6e60
GOT[3] 地址 = 0xf6e50 + 3 * 8 = 0xf6e68  ← 第一个函数的 GOT 条目

rela[0].r_offset = 0xf6e68 → GOT[3]（第1个函数）
rela[1].r_offset = 0xf6e70 → GOT[4]（第2个函数）
rela[n].r_offset = 0xf6e50 + (n+3)*8 → GOT[n+3]

公式：GOT 索引 = n + 3（n 是 .rela.plt 数组索引）
```

#### 3.6.2 为什么从 GOT[3] 开始？

```
GOT[0] = .dynamic section 地址 ← 保留给动态链接器使用
GOT[1] = link_map 指针         ← 保留给 _dl_runtime_resolve
GOT[2] = _dl_runtime_resolve 地址 ← 运行时解析函数
GOT[3] = 第1个外部函数（rela[0] 对应） ← 用户代码的第一个函数
GOT[4] = 第2个外部函数（rela[1] 对应）
...
GOT[n+3] = 第n+1个外部函数（rela[n] 对应）
```

这3个保留条目是由动态链接器在加载 so 时填充的，ELF 文件中初始值为0。

#### 3.6.3 在代码中展示 GOT 索引

```cpp
void RelocationTable::printPLTRelocations() const {
    for (const auto& rel : relocations) {
        uint32_t gotIndex = 3 + rel.index;  // rela[0] → GOT[3]
        printf("[%5d] %016lx [%3d]      %s\n",
               rel.index,
               (unsigned long)rel.offset,
               gotIndex,
               rel.symbol ? rel.symbol->name.c_str() : "???");
    }
}
```

---

### 3.7 linkSymbols()：建立重定位↔符号的联系

解析完 `.dynsym` 和 `.rela.plt` 之后，需要调用 `linkSymbols()` 把两者关联起来：

```cpp
void RelocationTable::linkSymbols(const DynamicSymbolTable& symtab) {
    for (auto& rel : relocations) {
        // rel.symIndex 是从 r_info 高32位解出来的符号表索引
        rel.symbol = symtab.findByIndex(rel.symIndex);
        // 关联后，rel.symbol->name 就是函数名
    }
}
```

建立关联后，一个 `RelocationInfo` 就包含了完整信息：

```
RelocationInfo {
    index    = 21           // .rela.plt 第21个条目
    offset   = 0xf6f78      // GOT[24] 的地址（21+3=24）
    symIndex = 某个值        // 指向 .dynsym 中的 malloc 条目
    type     = 1026          // R_AARCH64_JUMP_SLOT
    addend   = 0
    symbol   = &SymbolInfo { name="malloc", type=STT_FUNC, shndx=SHN_UNDEF }
}
```

---

### 3.8 解析流程的完整代码路径（main.cpp）

```cpp
// 步骤3完整流程

// [1] 解析动态符号表
DynamicSymbolTable symtab;
const uint8_t* dynsymData = sections.getSectionData(sections.dynsymSection, fileData);
const uint8_t* dynstrData = sections.getSectionData(sections.dynstrSection, fileData);
symtab.parse(dynsymData, sections.dynsymSection->size,
             dynstrData, sections.dynstrSection->size,
             header.is64bit, header.isLittleEndian);

// [2] 解析重定位表
RelocationTable relocs;
const uint8_t* relaData = sections.getSectionData(sections.relaPltSection, fileData);
relocs.parse(relaData, sections.relaPltSection->size,
             header.is64bit, header.isLittleEndian, true);

// [3] 关联符号表（建立 symIndex → SymbolInfo 映射）
relocs.linkSymbols(symtab);

// [4] 打印结果
symtab.printFunctions();       // 所有函数符号
relocs.printPLTRelocations();  // PLT 重定位条目（含 GOT 索引）
```

---

### 3.9 实际测试结果分析

使用 `/system/lib64/libc.so` 作为测试目标：

#### 3.9.1 符号数量验证

```bash
# 我们的工具
adb shell /data/local/tmp/elf_reader /system/lib64/libc.so 2>&1 | grep -c FUNC
# 结果：1448

# GNU readelf（在电脑上执行）
readelf --dyn-syms /system/lib64/libc.so | grep FUNC | wc -l
# 结果：1448 ✅ 完全一致
```

libc.so 导出了 1448 个函数，每个都是 `STT_FUNC` + `STB_GLOBAL`，`shndx` 非零（定义在本 so 内部）。

#### 3.9.2 PLT 重定位条目验证（libc.so 依赖的外部函数）

```bash
# 我们的工具输出片段
PLT relocations (function jumps):
  Entry  Offset           GOT Index  Symbol
[    0] 0000000000f6e68 [  3]      __memcpy_chk
[    1] 0000000000f6e70 [  4]      __memmove_chk
...
[   21] 0000000000f6f78 [ 24]      malloc
...

# 总条目数
# .rela.plt section 大小 = 0x2e08 = 11784 bytes
# 每条目大小 = 24 bytes（Elf64_Rela）
# 条目数 = 11784 / 24 = 491 条
```

**解读**：libc.so 自身也依赖外部函数（如 linker 提供的内部函数），共491个 PLT 条目。`malloc` 在 `rela[21]`，对应 `GOT[24]`。

#### 3.9.3 malloc 符号完整信息

```
在 .dynsym 中查找 "malloc"：
  index  = 某个值（被 .rela.plt[21] 引用）
  name   = "malloc"
  bind   = STB_GLOBAL (1)
  type   = STT_FUNC (2)
  shndx  = 某个非零值（在 libc.so 内部定义）
  value  = 函数在 libc.so 中的偏移（非零）
  size   = 函数大小（字节）

在 .rela.plt 中查找：
  rela[21].r_offset = 0xf6f78  → GOT[24] 的地址
  rela[21].symIndex = 上面的 index
  rela[21].type     = R_AARCH64_JUMP_SLOT (1026)
  rela[21].addend   = 0
```

---

### 3.10 调试过程记录：printFunctions() 输出为空的问题

**问题**：最初运行时 `grep FUNC` 结果为0，但 GNU readelf 有1448行 FUNC。

**原因排查**：`printFunctions()` 的格式字符串缺少 `Type` 列：

```cpp
// 错误的格式（缺少 type 列，匹配不到 "FUNC"）：
printf("%6d: %016lx %5lu %-6s %-8s %s\n",
       sym.index, sym.value, sym.size,
       getBindName(sym.bind), "DEFAULT", sym.name.c_str());

// 修复后（添加 type 列）：
printf("%6d: %016lx %5lu %-7s %-6s %-8s %s\n",
       sym.index, sym.value, sym.size,
       getTypeName(sym.type),    // ← 添加这列
       getBindName(sym.bind), "DEFAULT", sym.name.c_str());
```

**教训**：打印格式要与表头严格对应，缺少列会导致 grep 匹配失败。

---

### 3.11 数据流关系图

```
文件数据 (uint8_t* fileData)
    │
    ├─ [sh_offset=0x2f8]──► .dynsym 原始数据
    │                              │
    │                     DynamicSymbolTable::parse()
    │                              │
    │                     symbols[] vector
    │                     SymbolInfo {index, name, bind, type, shndx, value, size}
    │
    ├─ [sh_offset=0xc888]─► .dynstr 原始数据
    │                              │
    │                     直接作为字符串池，由 st_name 索引
    │
    └─ [sh_offset=0x17110]─► .rela.plt 原始数据
                                   │
                          RelocationTable::parse()
                                   │
                          relocations[] vector
                          RelocationInfo {index, offset, symIndex, type, addend}
                                   │
                          linkSymbols()
                                   │
                          RelocationInfo.symbol ──────► SymbolInfo
                          （此后可通过 rel.symbol->name 得到函数名）
```

---

### 3.12 步骤3学习要点总结

1. **符号表是查找函数的字典**：
   - `.dynsym` 是数组，每条24字节（64位）
   - 函数名存在 `.dynstr`，通过 `st_name` 偏移访问
   - `st_info` 的高4位=bind（全局/局部/弱），低4位=type（函数/变量等）

2. **重定位表是"需要动态链接器填充的清单"**：
   - `.rela.plt` 每条24字节，3个字段：r_offset、r_info、r_addend
   - `r_info` 高32位=符号索引，低32位=重定位类型
   - `r_offset` 是 GOT 条目的运行时地址

3. **GOT 布局的黄金公式**：
   - `rela[n].r_offset = .got.plt 基址 + (n+3) * 8`
   - 反过来：`GOT 索引 = (r_offset - got_plt_base) / 8`
   - n+3 是因为 GOT[0/1/2] 被动态链接器保留

4. **两表联动**：
   - 先解析 `.dynsym`，再解析 `.rela.plt`，然后 `linkSymbols()` 建立关联
   - 关联后每个 `RelocationInfo` 都持有 `const SymbolInfo*` 指针

5. **32位与64位的陷阱**：
   - `Elf64_Sym`：st_name(4) → st_info(1) → st_other(1) → st_shndx(2) → st_value(8) → st_size(8)
   - `Elf32_Sym`：st_name(4) → **st_value(4) → st_size(4)** → st_info(1) → st_other(1) → st_shndx(2)
   - 64位的 st_info 在 offset 4，32位的 st_info 在 offset 12，**字段顺序完全不同**！

---

### 3.13 下一步预告：步骤 4 PLT 反汇编

步骤 4 将达到 **readelf 无法做到的深度**：反汇编 `.plt` section，查看每个 PLT 条目的实际机器指令。

ARM64 架构的 PLT 条目格式固定为4条指令：
```asm
adrp x16, <GOT页基址>      # 计算 GOT 所在的内存页地址
ldr  x17, [x16, <偏移>]   # 从 GOT[n] 加载函数地址到 x17
add  x16, x16, <偏移>      # x16 = &GOT[n]（传递给 _dl_runtime_resolve）
br   x17                   # 跳转到 x17 保存的地址
```

通过解码这4条指令，可以：
1. 验证 PLT 条目与 GOT 条目的实际对应关系
2. 看到机器码层面的跳转机制
3. 理解 ADRP+LDR 如何实现位置无关代码（PIC）
