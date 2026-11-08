# 命令耗时统计

本文记录 Enhanced `hdc shell` 各类命令的实测耗时，并与原生 hdc 路径对照。当前规格见 [AGENTS.md](../AGENTS.md)，功能差异与验证结论见 [hdc-shell-alignment.md](hdc-shell-alignment.md)。

测量日期：2026-11-08（1.1.8）。数据来自单台设备、单次会话的中位数；不是硬件上限，也不代表 Windows 实机结果。

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

- 每条命令先执行一次预热并丢弃，再取 4–7 个样本的中位数；重命令（`bm`、`aa`、`hidumper`、`hilog`、`dmesg`、大输出）取 4–5 个样本。
- **pexpect 的 `delaybeforesend` 已设为 0。** 默认值会在每次发送前休眠 50 ms，一次命令至少包含“发送回车”和“回答光标位置查询”两次发送，会给所有 PTY 路径凭空增加约 100 ms。早期版本的统计未扣除这一测试端开销，数字偏高；本表是扣除后的结果。
- `enhanced` 的输入行在按回车前等待渲染完成，避免把用户打字时间混入执行耗时；`enhanced render` 单独列出一列。
- `raw` 和 `enhanced` 都经过同一套 pexpect+pyte 终端模拟；`direct` 没有终端模拟开销。
- stdin 类命令没有 `direct` / `raw` 数值：非交互 `hdc shell cat` 不会收到 EOF（实测 5 秒仍不返回），原生交互 `hdc shell` 会把终端作为 stdin 等待用户输入。增强会话的 stdin 指向 `/dev/null`，因此可以立即返回。
- 测试夹具创建在 `/data/local/tmp/hdc_bench_<pid>_<time>`，结束时删除；表中以 `<fixture>` 代替实际路径。

## 结果

单位：毫秒。`—` 表示该类路径不适用或会阻塞。

| 类别 | 命令 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---|---:|---:|---:|---:|
| 平凡 | `echo hello` | 114 | 29 | 194 | 447 |
| 平凡 | `pwd` | 114 | 29 | 181 | 164 |
| 平凡 | `true` | 114 | 29 | 198 | 117 |
| 平凡 | `printf 'TXT\n'` | 165 | 86 | 249 | 143 |
| 文件 | `cat <fixture>/plain.txt` | 115 | 29 | 175 | 68 |
| 文件 | `head -1 <fixture>/plain.txt` | 164 | 127 | 253 | 68 |
| 文件 | `tail -1 <fixture>/plain.txt` | 165 | 125 | 271 | 76 |
| 文件 | `grep hello <fixture>/plain.txt` | 165 | 124 | 175 | 100 |
| 文件 | `sed -n 1p <fixture>/plain.txt` | 114 | 103 | 242 | 101 |
| 文件 | `wc -l <fixture>/plain.txt` | 114 | 107 | 247 | 67 |
| 文件 | `sort <fixture>/plain.txt` | 115 | 109 | 250 | 85 |
| stdin | `cat` | — | — | 199 | 33 |
| stdin | `wc` | — | — | 201 | 33 |
| stdin | `head` | — | — | 250 | 33 |
| stdin | `grep x` | — | — | 204 | 39 |
| stdin | `read line` | — | — | 195 | 62 |
| 列表 | `ls <fixture>` | 164 | 103 | 242 | 63 |
| 列表 | `ls -1 <fixture>` | 114 | 126 | 178 | 66 |
| 列表 | `ls -l <fixture>` | 165 | 85 | 199 | 66 |
| 列表 | `ls -R <fixture>` | 165 | 101 | 219 | 65 |
| 列表 | `ls -a <fixture>` | 115 | 80 | 267 | 64 |
| 列表 | `ls -S <fixture>` | 165 | 125 | 274 | 67 |
| 列表 | `ls -m <fixture>` | 165 | 124 | 252 | 66 |
| 列表 | `ls /system/bin \| wc -l` | 165 | 102 | 247 | 64 |
| 搜索 | `find <fixture> -maxdepth 1 -name '*.txt'` | 165 | 106 | 243 | 72 |
| OpenHarmony | `bm dump -a \| head -3` | 215 | 154 | 305 | 64 |
| OpenHarmony | `param get const.product.model` | 114 | 104 | 210 | 69 |
| OpenHarmony | `aa dump -l \| head -3` | 315 | 231 | 336 | 65 |
| OpenHarmony | `hidumper -e \| head -3` | 341 | 297 | 447 | 40 |
| OpenHarmony | `hilog -x \| head -3` | 165 | 77 | 222 | 39 |
| OpenHarmony | `dmesg \| head -3` | 165 | 92 | 261 | 37 |
| 复合 | `echo hi \| cat` | 165 | 26 | 171 | 64 |
| 复合 | `true && echo AND` | 115 | 29 | 203 | 64 |
| 复合 | `false \|\| echo OR` | 114 | 29 | 179 | 65 |
| 复合 | `echo A; echo B` | 114 | 30 | 197 | 64 |
| 复合 | `echo SUB=$(echo inner)` | 114 | 31 | 196 | 66 |
| 复合 | `echo x > /dev/null && echo REDIR` | 115 | 29 | 196 | 70 |
| 状态 | `false` | 115 | 29 | 171 | 34 |
| 状态 | `export FOO=state; echo $FOO` | 115 | 29 | 153 | 64 |
| 大输出 | `seq 1 3000 \| tail -1` | 215 | 83 | 178 | 65 |
| 大输出 | `seq 1 1000` | 165 | 126 | 203 | 42 |
| Unicode | `printf '中文✓\n'` | 164 | 105 | 180 | 64 |
| Unicode | `printf '\033[31mRED\033[0m\n'` | 165 | 100 | 225 | 66 |

### 分类中位数

| 类别 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---:|---:|---:|---:|
| 平凡 | 114 | 29 | 196 | 154 |
| 文件 | 115 | 109 | 247 | 76 |
| stdin | — | — | 201 | 33 |
| 列表 | 165 | 102 | 244 | 66 |
| 搜索 | 165 | 106 | 243 | 72 |
| OpenHarmony | 190 | 129 | 283 | 52 |
| 复合 | 114 | 29 | 196 | 64 |
| 状态 | 115 | 29 | 162 | 49 |
| 大输出 | 190 | 104 | 190 | 54 |
| Unicode | 164 | 102 | 202 | 65 |
| **全部命令中位数** | **164** | **100** | **204** | **65** |

### 路径强调的冷/热差异

1.1.8 起，路径强调与补全共用设备目录列表的 10 秒缓存；行内结果仍按输入行缓存，控制台样式每行重置。

| 场景 | enhanced 输入渲染（文件/搜索类命令） |
|---|---:|
| 冷缓存：10 秒内首次查询某目录 | 约 350–490 ms |
| 热缓存：同一目录 10 秒内再次输入 | 约 65–100 ms |

冷缓存仍需要一次 hdc 查询每个新目录段；热缓存直接复用列表，不再启动 hdc。上表主结果是在预热后的稳态测量，反映连续操作时的体验；首次进入一个新目录仍会出现一次冷查询。

## 分析

- **执行开销**：增强会话执行中位数约 204 ms，原生交互会话约 100 ms，非交互 `hdc shell CMD` 约 164 ms。
- **固定成本来自每命令 RPC**：`echo` 的非交互 direct 为 114 ms，原生持久 shell 为 29 ms，差额约 85 ms 是 hdc 客户端进程启动和一次连接往返。增强会话按规格为每条命令新建 hdc RPC，因此这部分无法通过本地代码消除；远端包装（PID/状态标记、`trap`、`cd`、`OLDPWD`）再加约一个 hdc 输出轮询周期，使 wrapped direct 达到约 165 ms。
- **1.1.8 的优化**：
  - 目录列表缓存不再在每个提示符后强制清空，改为与补全相同的 10 秒 TTL。连续输入同一目录时，路径强调的输入渲染中位数从约 202 ms 降到 65 ms（文件/搜索类从 360–390 ms 降到约 70 ms）。代价是文件系统变化后最多 10 秒内仍可能按旧列表强调；这与补全缓存的上限一致。
  - C# 流循环的等待间隔从 15 ms 降到 2 ms，缩短进程退出后的收尾；直接调用 `HdcShellProcess.Run` 的 `seq 1 1000` 从约 242 ms 降到约 162 ms。
  - 基准测试修正了 pexpect 默认 50 ms 发送延迟造成的约 100 ms 测量偏差。
- **stdin 类**：原生 direct 不转发 EOF，raw 等待终端输入；增强会话约 195–250 ms 正常返回。这是 1.1.7 修复的行为，不是额外延迟。
- **OpenHarmony 命令**：设备侧本身占主导（`aa dump` 231–336 ms、`hidumper` 297–447 ms），增强包装相对增量与普通命令一致。
- **大输出**：`seq 1 1000` 与 `seq 1 3000 | tail -1` 约 180–200 ms；输出按块流式显示，不等待进程结束。持续日志的首屏和 Ctrl+C 时延由真机实时输出测试单独验证。
- **波动**：单次会话中位数，受设备负载、hdc daemon 状态、USB/网络链路和首次调用缓存影响；`enhanced render` 受粘贴节奏和 PSReadLine 重绘影响，波动比执行耗时大。`echo`、`printf` 等无路径命令的渲染样本偶有 400 ms 以上，属于测试端重绘波动，不影响执行。
- **进一步空间**：若要显著低于约 200 ms，需要复用一条持久 hdc 通道，而不是每命令启动 hdc。`hdc shell` 交互模式要求 TTY（stdin 为管道时会报 `Not support stdio TTY mode` 并阻塞），因此需要主机侧 PTY/ConPTY 支持，并重新设计 Ctrl+C、进程组隔离和状态不持久化；这属于规格和架构变更，本版本未采用。

## 复现

```sh
python3 tests/HdcShell.Bench.py <serial>
```

需要 `pwsh`、`hdc`、`pexpect`、`pyte`、`wcwidth`，并连接一台在线设备。测试会在 `/data/local/tmp` 创建一个临时夹具并在退出时删除；不会修改其他设备文件。增强会话默认从仓库加载模块，也可用 `HDC_TEST_MODULE` 指向安装后的模块：

```sh
HDC_TEST_MODULE=~/.local/share/powershell/Modules/TerminalSuggestions/TerminalSuggestions.psd1 \
  python3 tests/HdcShell.Bench.py <serial>
```
