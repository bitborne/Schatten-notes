---
title: 'ELF 学习笔记 03：高级解析篇'
description: 'ELF Reader 开发学习笔记系列之三，探索 .eh_frame 异常处理帧与 DWARF .debug_line 调试信息解析。'
pubDate: '2026-03-21'
---

# ELF 学习笔记 03：高级解析篇

> 本系列笔记记录 ELF Reader 开发过程中的学习心得，从代码实践中理解 ELF 文件结构和动态链接机制。
>
> **系列导航**：
> - 📖 [01_基础结构篇](./ELF学习_01_基础结构篇.md)（ELF Header、Section Header、符号表与重定位表）
> - 📖 [02_动态链接篇](./ELF学习_02_动态链接篇.md)（.dynamic、PT_LOAD、延迟绑定、PLT反汇编、.rela.dyn、.rodata）
> - 📖 **当前文档**：03_高级解析篇（.eh_frame、DWARF .debug_line）

> **前置知识**：本篇内容相对独立，只需基础 ELF 知识（Section 的概念）即可阅读。

---

## 步骤 9：.eh_frame 解析——C++ 异常与栈回溯的幕后功臣

**目标**：解析 .eh_frame 节，理解 C++ 异常处理和栈回溯机制

**实现文件**：
- `app/src/main/cpp/elf_reader/elf_ehframe.h/cpp` (新建)

---

### 9.1 什么是 .eh_frame？

**.eh_frame = Exception Handling Frame（异常处理帧）**

这是 DWARF 调试格式的一部分，用于：
1. **C++ 异常处理**：`try/catch/throw` 时栈展开
2. **栈回溯**：`backtrace()`、`debugger` 获取调用链
3. **信号处理**：`sigaction` 的 `SA_SIGINFO`

**为什么需要它？**

当异常抛出时，运行时需要从当前函数返回到调用者，然后到调用者的调用者...直到找到匹配的 catch。但编译器优化后，栈帧结构不固定，需要元数据指导如何恢复寄存器、找到返回地址。

### 9.2 .eh_frame 的结构

.eh_frame 是一系列 **CIE + FDE** 的组合：

```
+----------------------------------+
| CIE (Common Information Entry)   |  ← 公共信息，每个 so 只有一个
| - 版本号                         |
| - 编码规则                       |
| - 初始指令                       |
+----------------------------------+
| FDE (Frame Description Entry)    |  ← 每个函数一个
| - 函数起始地址                   |
| - 函数大小                       |
| - 指令序列（如何恢复寄存器）     |
+----------------------------------+
| FDE ...                          |
+----------------------------------+
| FDE ...                          |
+----------------------------------+
```

> **术语速查：CIE 与 FDE**
>
> **CIE（Common Information Entry，公共信息条目）**：
> - 每个 so 通常只有一个，存储公共的栈展开规则
> - 包含：版本号、augmentation 字符串、代码/数据对齐因子、返回地址寄存器
>
> **FDE（Frame Description Entry，帧描述条目）**：
> - 每个函数对应一个 FDE
> - 包含：函数起始 PC、函数大小、指向关联 CIE 的偏移、栈展开指令
>
> 关系：FDE 引用 CIE（通过负向偏移），继承 CIE 的公共规则并添加函数特定指令。

### 9.3 CIE 结构详解

```cpp
struct CIE {
    uint32_t length;           // CIE 长度（不含自身）
    uint32_t CIE_id;           // 必须是 0（标识 CIE vs FDE）
    uint8_t  version;          // 版本号（通常是 1 或 3）
    char     augmentation[...];// 扩展字符串（如 "zPLR"）
    uint64_t code_alignment;   // 代码对齐因子
    int64_t  data_alignment;   // 数据对齐因子
    uint64_t return_register;  // 返回地址寄存器
    uint8_t  initial_instructions[...]; // 初始指令
};
```

**Augmentation String**：
- `"z"`：有扩展字段
- `"P"`：有 personality 函数（C++ 异常处理）
- `"L"`：有 LSDA（Language Specific Data Area）指针
- `"R"`：有 FDE 编码信息

### 9.4 FDE 结构详解

```cpp
struct FDE {
    uint32_t length;           // FDE 长度（不含自身）
    uint32_t CIE_pointer;      // 指向关联 CIE 的偏移（负值）
    uint64_t initial_location; // 函数起始地址（PC）
    uint64_t address_range;    // 函数大小（字节）
    // 可选：LSDA 指针（如果 CIE 有 'L'）
    uint8_t  instructions[...]; // 栈展开指令
};
```

### 9.5 栈展开指令（Call Frame Instructions）

这些指令告诉运行时如何恢复调用者的寄存器：

| 指令 | 编码 | 含义 |
|------|------|------|
| DW_CFA_advance_loc | 0x40-0x7f | PC 增加 delta |
| DW_CFA_offset | 0x80-0xbf | 寄存器保存在 CFA + offset |
| DW_CFA_restore | 0xc0-0xff | 恢复寄存器到初始值 |
| DW_CFA_set_loc | 0x01 | 设置绝对 PC |
| DW_CFA_def_cfa | 0x0c | 定义 CFA（当前帧地址） |
| DW_CFA_def_cfa_offset | 0x0e | 设置 CFA 偏移 |

**CFA = Canonical Frame Address（规范帧地址）**

通常是调用者的栈指针（sp）值。所有寄存器的保存位置都相对于 CFA。

### 9.6 代码实现

```cpp
// eh_frame 条目基类
struct EHFrameEntry {
    uint32_t length;           // 条目长度
    uint32_t cieId;            // CIE ID（CIE=0，FDE=指向CIE的偏移）
    bool isCIE;                // 是否是 CIE
    uint64_t offset;           // 在文件中的偏移
};

// CIE 条目
struct CIEEntry : EHFrameEntry {
    uint8_t version;           // 版本号
    std::string augmentation;  // 扩展字符串
    uint64_t codeAlign;        // 代码对齐
    int64_t  dataAlign;        // 数据对齐
    uint64_t returnReg;        // 返回寄存器
    std::vector<uint8_t> initialInsns; // 初始指令
    bool hasAugmentationData;  // 是否有扩展数据
    uint64_t personalityFunc;  // personality 函数地址（C++ 异常）
    uint64_t lsdaEncoding;     // LSDA 编码方式
    uint64_t fdeEncoding;      // FDE 编码方式
};

// FDE 条目
struct FDEEntry : EHFrameEntry {
    const CIEEntry* cie;       // 关联的 CIE
    uint64_t pcBegin;          // 函数起始地址
    uint64_t pcRange;          // 函数大小
    uint64_t lsdaPointer;      // LSDA 指针（C++ 异常表）
    std::vector<uint8_t> instructions; // 栈展开指令
};

// .eh_frame 解析器
class EHFrameParser {
public:
    std::vector<std::unique_ptr<CIEEntry>> cies;
    std::vector<std::unique_ptr<FDEEntry>> fdes;

    bool parse(const uint8_t* data, size_t size,
               uint64_t sectionAddr, bool is64bit);

    // 查找包含给定 PC 的 FDE
    const FDEEntry* findFDEByPC(uint64_t pc) const;

    void print() const;
    void printSummary() const;

private:
    bool parseCIE(CIEEntry* cie, const uint8_t* data, size_t size);
    bool parseFDE(FDEEntry* fde, const uint8_t* data, size_t size,
                  const CIEEntry* cie);
};
```

### 9.7 LSDA（Language Specific Data Area）

> **术语速查：LSDA 与 Landing Pad**
>
> **LSDA（Language Specific Data Area，语言特定数据区）**：
> - C++ 异常处理的元数据，每个函数（FDE）可能有一个
> - 包含：Call Site Table（每个可能抛出的调用点）、Action Table（catch 块信息）、Type Table（异常类型匹配）
>
> **Landing Pad（着陆垫）**：
> - 异常处理代码的入口点（catch 块或清理代码）
> - 当异常匹配时，运行时跳转到 landing pad 执行
> - 如果 call site 的 landing pad = 0，表示该点没有 catch 处理，异常继续向上传播

对于 C++，LSDA 包含：
- **Call Site Table**：每个可能抛出异常的调用点
- **Action Table**：每个 catch 块的信息
- **Type Table**：异常类型匹配信息

```cpp
// LSDA 头
struct LSDAHeader {
    uint8_t lpStartEncoding;   // landing pad 起始编码
    uint8_t ttypeEncoding;     // 类型表编码
    uint64_t ttypeOffset;      // 类型表偏移
    uint8_t callSiteEncoding;  // call site 表编码
    uint64_t callSiteLength;   // call site 表长度
};

// Call Site 条目
struct CallSiteEntry {
    uint64_t position;         // 相对于函数起始的位置
    uint64_t length;           // 代码长度
    uint64_t landingPad;       // landing pad 偏移（或 0 表示无处理）
    uint64_t action;           // action 表索引（0 表示无处理）
};
```

**Landing Pad**：异常处理代码的入口点。如果 call site 有 landing pad，异常会跳转到这里执行 catch 或清理代码。

### 9.8 为什么这是"幕后功臣"？

**正常情况**：你看不到它的存在
- 程序正常执行，.eh_frame 被完全忽略
- 文件大小增加约 5-15%，但这是值得的

**异常情况**：它是救命稻草
- C++ `throw` → 需要 .eh_frame 找到 catch
- 崩溃时打印栈回溯 → 需要 .eh_frame 还原调用链
- 信号处理程序 → 需要 .eh_frame 安全地跳转到信号处理代码

---

**步骤 9 已完成**：
- `elf_ehframe.h/cpp` 创建
- `EHFrameParser` 类实现
- 支持 CIE/FDE 解析
- 支持 augmentation（`zPLR` 等）
- 新增命令行参数 `-f/--eh-frame`

---

## 步骤 10：DWARF .debug_line——源码与机器码的桥梁

**目标**：解析 `.debug_line` 节，建立 机器码地址 ↔ 源文件:行号 的映射

**实现文件**：
- `app/src/main/cpp/elf_reader/elf_dwarf.h/cpp` (新建)
- 修改 `main.cpp` 添加 `-g/--debug-line` 参数支持

---

### 10.1 什么是 DWARF？

**DWARF（Debugging With Attributed Record Formats）** 是调试信息的国际标准（DWARF 4 广泛使用）。

存放在以下节中：
| 节名 | 内容 |
|------|------|
| `.debug_line` | 源文件行号 ↔ 机器地址映射 |
| `.debug_info` | 函数名、类型、变量信息 |
| `.debug_abbrev` | 压缩编码的类型描述 |
| `.debug_str` | 调试信息的字符串表 |
| `.debug_ranges` | 不连续代码区间 |

**注意**：发布版 so（如 `/system/lib64/libc.so`）通常**裁剪掉**了调试信息，只在 debug 版中才有。

### 10.2 .debug_line 的结构

```
.debug_line 节
├── 编译单元 1 (native-lib.cpp)
│   ├── 头部 (Header)
│   │   ├── DWARF 版本
│   │   ├── 源文件列表 (含 #include 的头文件)
│   │   ├── 目录列表
│   │   └── 操作码参数
│   └── 行号程序 (Line Number Program)
│       ├── 特殊操作码：同时推进地址+行号
│       ├── 标准操作码：单独设置各寄存器
│       └── 扩展操作码：设置地址、序列结束等
└── 编译单元 2 (log_hooks.cpp)
    └── ...
```

### 10.3 行号状态机

DWARF 使用一个**虚拟状态机**来压缩存储行号信息：

```
寄存器：
- address：当前程序计数器（PC）
- file：当前文件索引
- line：当前行号（从1开始）
- is_stmt：是否为语句开始

操作码执行 → 状态机推进 → emit row → 最终建立映射表
```

**关键操作码**：
- `DW_LNE_set_address`：设置基地址（扩展操作码）
- `DW_LNS_advance_pc`：推进地址
- `DW_LNS_advance_line`：推进行号
- `DW_LNS_copy`：输出当前状态到行号表
- 特殊操作码（>= opcode_base）：同时推进地址和行号，然后自动 emit

**实现要点**：
- ULEB128/SLEB128 变长整数解码（LEB128 = Little Endian Base 128）
- 标准操作码 + 特殊操作码 + 扩展操作码三种类型的分支处理
- 每个编译单元（CU）独立解析，有自己的头部和文件列表

### 10.4 测试结果

```bash
adb shell /data/local/tmp/elf_reader -g /data/local/tmp/libdemo_so.so
```

输出示例：
```
.debug_line 调试行号信息:
  编译单元数量: 30

  编译单元 [0]  DWARF v4
    源文件列表:
      [ 1] /home/.../native-lib.cpp
      [ 2] /opt/android-ndk/.../jni.h
      ...
    地址范围: 0x1234 - 0x5678  (256 个行号条目)
```

**关键发现**：
- 每个 `.cpp` 文件对应一个编译单元
- 头文件的行号信息也被包含（内联展开）
- 发布版 so 无调试信息（`strip` 命令删除）

---

**步骤 10 已完成**：
- `elf_dwarf.h/cpp` 创建，实现 DWARF 行号状态机
- `-g/--debug-line` 参数支持
- 打印摘要：文件列表、地址范围、行号统计

---

## 本篇总结

本篇（高级解析篇）完成了 ELF Reader 的调试与异常信息解析功能：

| 步骤 | 功能 | CLI 参数 | 关键成果 |
|------|------|----------|----------|
| **步骤 9** | .eh_frame 解析 | `-f` | CIE/FDE 解析，支持 augmentation（`zPLR`），理解 C++ 异常处理机制 |
| **步骤 10** | DWARF .debug_line | `-g` | 行号状态机实现，ULEB128 解码，建立地址↔源码行号映射 |

**核心收获**：
- .eh_frame 是 C++ 异常处理和栈回溯的基础，以 CIE + FDE 的形式压缩存储每个函数的栈帧信息
- DWARF 使用状态机压缩存储调试信息，.debug_line 记录"哪行源码对应哪个机器地址"
- 发布版 so 通常 strip 掉 .debug_* 节，但会保留 .eh_frame（异常处理需要）

---

## ELF Reader 完整功能清单

| 步骤 | 功能 | CLI 参数 | 所在文档 |
|------|------|----------|----------|
| 步骤 1 | ELF Header 解析 | `-h` | 01_基础结构篇 |
| 步骤 2 | Section Header 解析 | `-S` | 01_基础结构篇 |
| 步骤 3 | 动态符号表+重定位表 | `-s` / `-r` | 01_基础结构篇 |
| 步骤 4 | .dynamic 段解析 | `-d` | 02_动态链接篇 |
| 步骤 5 | PT_LOAD 段信息 | `-l` | 02_动态链接篇 |
| 步骤 6 | PLT 反汇编 | `-D` | 02_动态链接篇 |
| 步骤 7 | .rela.dyn 解析 | `-r` | 02_动态链接篇 |
| 步骤 8 | .rodata 解析 | `-R` | 02_动态链接篇 |
| 步骤 9 | .eh_frame 解析 | `-f` | 03_高级解析篇 |
| 步骤 10 | DWARF .debug_line | `-g` | 03_高级解析篇 |
| — | 显示全部 | `-a` | — |