# 命令耗时统计

本文记录 Enhanced `hdc shell` 各类命令的实测耗时，并与原生 hdc 路径对照。当前规格见 [AGENTS.md](../AGENTS.md)，功能差异与验证结论见 [hdc-shell-alignment.md](hdc-shell-alignment.md)。

测量日期：2026-11-08（1.3.2）。数据来自单台设备、单次会话的中位数；不是硬件上限，也不代表 Windows 实机结果。

## 测量环境

| 项目 | 值 |
|---|---|
| 主机 | Linux 7.0.0-42-generic |
| PowerShell | 7.6.9 |
| PSReadLine | 2.4.5 |
| Python | 3.14.4 |
| 测试依赖 | pexpect 4.9.0、pyte 0.8.2、wcwidth |
| hdc | 3.2.0c |
| 设备 | HUAWEI Mate 70 Pro（PLR-AL00），序列号 `3DK0224A12000841` |
| 设备系统 | HarmonyOS/OpenHarmony `PLR-AL00 7.1.0.553`，API 26 |
| 设备内核 | HongMeng Kernel 1.15.0，aarch64，Toybox |

## 测量方法

三种路径执行同一组命令：

| 路径 | 方式 | 计时窗口 |
|---|---|---|
| `direct` | `hdc -t SERIAL shell CMD`，每个样本新建 hdc 进程，stdin 为 `/dev/null`，stdout/stderr 丢弃 | 整个 hdc 进程的墙上时间 |
| `raw` | `hdc -t SERIAL shell` 交互会话，PTY 200×60，持久 shell | 发送回车到下一个 `# ` 提示符 |
| `enhanced` | `Enter-HdcShell`，PTY 200×60，pyte 解析屏幕，路径强调渲染完成后 | 发送回车到下一个设备提示符 |
| `enhanced render` | 同上 | 发送完整命令文本到输入行和光标渲染完成（不含执行） |

- 1.2.0 起，Unix 主机的 `enhanced` 使用持久 `hdc shell` 通道：会话启动时定义一次远端包装函数，每条命令只发送一条短的函数调用，命令在独立子 shell 中执行，stdin 为 `/dev/null`，stdout/stderr 经管道中继，避免用户命令看到 TTY。Windows、PTY 创建失败或命令行过长时回退到逐命令 RPC（约 200 ms/命令）。本表在 Linux 上测量，使用持久路径。
- 持久会话启动（创建 PTY、等待提示符、定义包装函数并自检）约 0.65 秒，每进入一次增强会话只发生一次，不计入单命令耗时。
- 每条命令先执行一次预热并丢弃，再取 4–7 个样本的中位数；重命令（`bm`、`aa`、`hidumper`、`hilog`、`dmesg`、大输出）取 4–5 个样本。
- **pexpect 的 `delaybeforesend` 已设为 0。** 默认值会在每次发送前休眠 50 ms，一次命令至少包含“发送回车”和“回答光标位置查询”两次发送，会给所有 PTY 路径凭空增加约 100 ms。
- `enhanced` 的输入行在按回车前等待渲染完成，避免把用户打字时间混入执行耗时；`enhanced render` 单独列出一列。
- `raw` 和 `enhanced` 都经过同一套 pexpect+pyte 终端模拟；`direct` 没有终端模拟开销。
- stdin 类命令没有 `direct` / `raw` 数值：非交互 `hdc shell cat` 不会收到 EOF（实测 5 秒仍不返回），原生交互 `hdc shell` 会把终端作为 stdin 等待用户输入。增强会话的 stdin 指向 `/dev/null`，因此可以立即返回。
- 测试夹具创建在 `/data/local/tmp/hdc_bench_<pid>_<time>`，结束时删除；表中以 `<fixture>` 代替实际路径。

## 结果

单位：毫秒。`—` 表示该类路径不适用或会阻塞。

| 类别 | 命令 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---|---:|---:|---:|---:|
| 平凡 | `echo hello` | 114 | 29 | 50 | 440 |
| 平凡 | `pwd` | 114 | 29 | 49 | 162 |
| 平凡 | `true` | 115 | 29 | 49 | 116 |
| 平凡 | `printf 'TXT\n'` | 165 | 103 | 100 | 108 |
| 文件 | `cat <fixture>/plain.txt` | 115 | 29 | 174 | 74 |
| 文件 | `head -1 <fixture>/plain.txt` | 164 | 102 | 101 | 66 |
| 文件 | `tail -1 <fixture>/plain.txt` | 115 | 102 | 102 | 65 |
| 文件 | `grep hello <fixture>/plain.txt` | 165 | 85 | 104 | 99 |
| 文件 | `sed -n 1p <fixture>/plain.txt` | 165 | 108 | 105 | 100 |
| 文件 | `wc -l <fixture>/plain.txt` | 165 | 124 | 100 | 65 |
| 文件 | `sort <fixture>/plain.txt` | 164 | 125 | 106 | 73 |
| stdin | `cat` | — | — | 105 | 33 |
| stdin | `wc` | — | — | 103 | 32 |
| stdin | `head` | — | — | 104 | 32 |
| stdin | `grep x` | — | — | 122 | 39 |
| stdin | `read line` | — | — | 51 | 40 |
| 列表 | `ls <fixture>` | 114 | 100 | 102 | 68 |
| 列表 | `ls -1 <fixture>` | 165 | 126 | 107 | 66 |
| 列表 | `ls -l <fixture>` | 165 | 127 | 103 | 65 |
| 列表 | `ls -R <fixture>` | 165 | 103 | 105 | 65 |
| 列表 | `ls -a <fixture>` | 114 | 103 | 106 | 64 |
| 列表 | `ls -S <fixture>` | 115 | 124 | 102 | 64 |
| 列表 | `ls -m <fixture>` | 165 | 125 | 102 | 64 |
| 列表 | `ls /system/bin | wc -l` | 215 | 104 | 103 | 63 |
| 搜索 | `find <fixture> -maxdepth 1 -name '*.txt'` | 214 | 108 | 130 | 75 |
| OpenHarmony | `bm dump -a | head -3` | 215 | 153 | 154 | 64 |
| OpenHarmony | `param get const.product.model` | 165 | 105 | 89 | 64 |
| OpenHarmony | `aa dump -l | head -3` | 315 | 227 | 241 | 64 |
| OpenHarmony | `hidumper -e | head -3` | 390 | 304 | 324 | 40 |
| OpenHarmony | `hilog -x | head -3` | 165 | 84 | 104 | 39 |
| OpenHarmony | `dmesg | head -3` | 165 | 80 | 103 | 37 |
| 复合 | `echo hi | cat` | 164 | 27 | 53 | 63 |
| 复合 | `true && echo AND` | 114 | 29 | 50 | 64 |
| 复合 | `false || echo OR` | 114 | 29 | 49 | 64 |
| 复合 | `echo A; echo B` | 115 | 29 | 30 | 64 |
| 复合 | `echo SUB=$(echo inner)` | 115 | 32 | 51 | 65 |
| 复合 | `echo x > /dev/null && echo REDIR` | 115 | 28 | 52 | 70 |
| 状态 | `false` | 114 | 28 | 51 | 33 |
| 状态 | `export FOO=state; echo $FOO` | 115 | 28 | 53 | 64 |
| 大输出 | `seq 1 3000 | tail -1` | 165 | 82 | 101 | 64 |
| 大输出 | `seq 1 1000` | 165 | 131 | 106 | 63 |
| Unicode | `printf '中文✓\n'` | 165 | 125 | 101 | 65 |
| Unicode | `printf '\033[31mRED\033[0m\n'` | 165 | 126 | 106 | 64 |

### 分类中位数

| 类别 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---:|---:|---:|---:|
| 平凡 | 114 | 29 | 50 | 139 |
| 文件 | 164 | 102 | 102 | 72 |
| stdin | — | — | 103 | 32 |
| 列表 | 165 | 114 | 103 | 64 |
| 搜索 | 214 | 108 | 130 | 75 |
| OpenHarmony | 190 | 129 | 129 | 52 |
| 复合 | 115 | 29 | 50 | 64 |
| 状态 | 114 | 28 | 52 | 48 |
| 大输出 | 165 | 106 | 104 | 64 |
| Unicode | 165 | 126 | 104 | 64 |
| **全部命令中位数** | **165** | **102** | **102** | **64** |

### 路径强调的冷/热差异

路径强调与补全共用设备目录列表的 10 秒缓存；行内结果仍按输入行缓存，控制台样式每行重置。

| 场景 | enhanced 输入渲染（文件/搜索类命令） |
|---|---:|
| 冷缓存：10 秒内首次查询某目录 | 约 350–490 ms |
| 热缓存：同一目录 10 秒内再次输入 | 约 65–100 ms |

上表主结果是在预热后的稳态测量；首次进入一个新目录仍会出现一次冷查询。

## 分析

- **整体**：1.2.0 增强会话执行中位数约 **101 ms**（1.1.8 约 204 ms），与原生交互会话（约 102 ms）和非交互 `hdc shell`（约 115 ms）基本持平。
- **持久通道的收益**：每条命令不再新建 hdc 进程和连接（原先约 85 ms），也不再重复解析长包装脚本；会话启动时只定义一次包装函数，每条命令发送一条短调用。简单内建命令从约 200 ms 降到约 **50 ms**。
- **简单 `cat` 的文件通道**：1.3.2 起，单个普通文件优先通过 `hdc file recv` 读取（1.59 MB 图片约 50 ms，远快于 shell 通道 base64 的约 0.4 MB/s），二进制内容以 base64 文本显示、文本内容原样显示；`cat file` 约 174 ms（含 `test -f` 预检和临时文件读取）。多文件/带选项/管道/重定向的 `cat` 仍在设备内执行或走简单 base64 转码。
- **大文件 `cat`**：1.59 MB 图片的传输由文件通道完成，终端显示 2.1 MB base64 文本的时间取决于终端/测试端 pyte；实测 pyte 约 2.7 秒，传输本身约 50 ms。超大文件仍建议 `hdc file recv` 保存到主机。
- **剩余成本**：`head`、`grep`、`printf`、`seq`、`ls` 等是设备上的外部程序，进程启动本身约 50 ms；因此这些命令仍在约 100 ms。`aa dump`、`hidumper` 等设备侧耗时占主导（约 220–315 ms）。
- **stdout 非 TTY**：持久通道的用户命令 stdout/stderr 经管道中继到会话，仍是非 TTY，避免 `ls` 排版、`dmesg` 跟随模式等因 TTY 检测而变化；`cat`、`read` 等仍得到 EOF。
- **路径强调**：热缓存输入渲染中位数约 65 ms；冷查询仍约 350–490 ms。该部分与命令执行无关，受用户输入节奏影响。
- **启动与回退**：持久会话启动约 0.65 秒，每次进入只发生一次。Windows、PTY 不可用、会话自检失败或命令行超过 3000 字符时回退到逐命令 RPC，约 200 ms/命令，功能保持。
- **波动**：单次会话中位数，受设备负载、hdc daemon 状态、USB/网络链路和首次调用缓存影响；`enhanced render` 的个别无路径样本偶有 400 ms 以上，属于测试端 PSReadLine/pyte 重绘波动，不影响执行。
- **进一步空间**：执行层已与原生 hdc 接近；剩余可优化项是设备外部命令的启动成本（由设备决定）、冷路径查询的一次性 hdc 查询，以及持久通道的启动时间。继续降低交互延迟需要设备侧更快的外部命令或更少的目录查询，主机侧已没有明显的固定开销。

## 复现

``sh
python3 tests/HdcShell.Bench.py <serial>
``

需要 `pwsh`、`hdc`、`pexpect`、`pyte`、`wcwidth`，并连接一台在线设备。测试会在 `/data/local/tmp` 创建一个临时夹具并在退出时删除；不会修改其他设备文件。增强会话默认从仓库加载模块，也可用 `HDC_TEST_MODULE` 指向安装后的模块：

``sh
HDC_TEST_MODULE=~/.local/share/powershell/Modules/TerminalSuggestions/TerminalSuggestions.psd1 \
  python3 tests/HdcShell.Bench.py <serial>
``
