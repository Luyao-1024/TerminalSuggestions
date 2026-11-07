# 命令耗时统计

本文记录 Enhanced `hdc shell` 各类命令的实测耗时，并与原生 hdc 路径对照。当前规格见 [AGENTS.md](../AGENTS.md)，功能差异与验证结论见 [hdc-shell-alignment.md](hdc-shell-alignment.md)。

测量日期：2026-11-07。数据来自单台设备、单次会话的中位数；不是硬件上限，也不代表 Windows 实机结果。

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
- `enhanced` 的输入行在按回车前等待渲染完成，避免把用户打字时间混入执行耗时；`enhanced render` 单独列出一列。
- `raw` 和 `enhanced` 都经过同一套 pexpect+pyte 终端模拟，便于横向比较；`direct` 没有终端模拟开销。
- stdin 类命令没有 `direct` / `raw` 数值：非交互 `hdc shell cat` 不会收到 EOF（实测 5 秒仍不返回），原生交互 `hdc shell` 会把终端作为 stdin 等待用户输入。增强会话的 stdin 指向 `/dev/null`，因此可以立即返回。
- 测试夹具创建在 `/data/local/tmp/hdc_bench_<pid>_<time>`，结束时删除；表中以 `<fixture>` 代替实际路径。

## 结果

单位：毫秒。`—` 表示该类路径不适用或会阻塞。

| 类别 | 命令 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---|---:|---:|---:|---:|
| 平凡 | `echo hello` | 116 | 79 | 306 | 505 |
| 平凡 | `pwd` | 116 | 79 | 286 | 212 |
| 平凡 | `true` | 115 | 79 | 303 | 168 |
| 平凡 | `printf 'TXT\n'` | 167 | 160 | 278 | 272 |
| 文件 | `cat <fixture>/plain.txt` | 115 | 79 | 306 | 440 |
| 文件 | `head -1 <fixture>/plain.txt` | 165 | 176 | 310 | 417 |
| 文件 | `tail -1 <fixture>/plain.txt` | 165 | 175 | 279 | 443 |
| 文件 | `grep hello <fixture>/plain.txt` | 165 | 157 | 338 | 568 |
| 文件 | `sed -n 1p <fixture>/plain.txt` | 165 | 175 | 336 | 561 |
| 文件 | `wc -l <fixture>/plain.txt` | 165 | 162 | 354 | 412 |
| 文件 | `sort <fixture>/plain.txt` | 164 | 158 | 327 | 402 |
| stdin | `cat` | — | — | 361 | 83 |
| stdin | `wc` | — | — | 333 | 82 |
| stdin | `head` | — | — | 379 | 83 |
| stdin | `grep x` | — | — | 310 | 212 |
| stdin | `read line` | — | — | 303 | 271 |
| 列表 | `ls <fixture>` | 115 | 174 | 294 | 274 |
| 列表 | `ls -1 <fixture>` | 165 | 177 | 279 | 244 |
| 列表 | `ls -l <fixture>` | 115 | 176 | 340 | 279 |
| 列表 | `ls -R <fixture>` | 115 | 174 | 285 | 277 |
| 列表 | `ls -a <fixture>` | 165 | 175 | 350 | 245 |
| 列表 | `ls -S <fixture>` | 165 | 132 | 309 | 282 |
| 列表 | `ls -m <fixture>` | 165 | 176 | 293 | 275 |
| 列表 | `ls /system/bin \| wc -l` | 165 | 153 | 332 | 284 |
| 搜索 | `find <fixture> -maxdepth 1 -name '*.txt'` | 164 | 175 | 278 | 403 |
| OpenHarmony | `bm dump -a \| head -3` | 214 | 204 | 407 | 243 |
| OpenHarmony | `param get const.product.model` | 114 | 154 | 324 | 263 |
| OpenHarmony | `aa dump -l \| head -3` | 290 | 276 | 465 | 279 |
| OpenHarmony | `hidumper -e \| head -3` | 366 | 347 | 534 | 90 |
| OpenHarmony | `hilog -x \| head -3` | 165 | 142 | 295 | 89 |
| OpenHarmony | `dmesg \| head -3` | 140 | 134 | 370 | 87 |
| 复合 | `echo hi \| cat` | 115 | 79 | 293 | 280 |
| 复合 | `true && echo AND` | 114 | 79 | 257 | 246 |
| 复合 | `false \|\| echo OR` | 114 | 78 | 259 | 277 |
| 复合 | `echo A; echo B` | 115 | 79 | 292 | 279 |
| 复合 | `echo SUB=$(echo inner)` | 115 | 82 | 279 | 248 |
| 复合 | `echo x > /dev/null && echo REDIR` | 114 | 80 | 265 | 470 |
| 状态 | `false` | 115 | 79 | 356 | 84 |
| 状态 | `export FOO=state; echo $FOO` | 115 | 79 | 291 | 275 |
| 大输出 | `seq 1 3000 \| tail -1` | 165 | 134 | 300 | 279 |
| 大输出 | `seq 1 1000` | 165 | 176 | 354 | 278 |
| Unicode | `printf '中文✓\n'` | 165 | 153 | 279 | 247 |
| Unicode | `printf '\033[31mRED\033[0m\n'` | 165 | 176 | 302 | 277 |

### 分类中位数

| 类别 | direct | raw | enhanced 执行 | enhanced 输入渲染 |
|---|---:|---:|---:|---:|
| 平凡 | 116 | 79 | 294 | 242 |
| 文件 | 165 | 162 | 327 | 440 |
| stdin | — | — | 333 | 83 |
| 列表 | 165 | 174 | 302 | 276 |
| 搜索 | 164 | 175 | 278 | 403 |
| OpenHarmony | 190 | 179 | 388 | 166 |
| 复合 | 114 | 79 | 272 | 278 |
| 状态 | 115 | 79 | 324 | 180 |
| 大输出 | 165 | 155 | 327 | 278 |
| Unicode | 165 | 164 | 290 | 262 |
| **全部命令中位数** | **164** | **156** | **306** | **275** |

## 分析

- **整体开销**：增强会话执行中位数约 306 ms，原生交互会话约 156 ms，非交互 `hdc shell CMD` 约 164 ms。增强路径多出约 140–150 ms。
- **开销构成**：单独把增强会话的远端包装脚本（`read /proc`、PID/状态标记、`trap`、`cd`、`OLDPWD`、结尾 `pwd`）交给一次 `hdc shell` 执行，`echo hello` 从 114 ms 升到 165 ms，约 +50 ms。剩余约 100 ms 来自主机侧 C# 流解码、PSReadLine/提示符重绘和测试端 pyte；真实终端通常比 pyte 更快。
- **不是 stdin 修复带来的**：`exec </dev/null` 只是一次 shell 内重定向，没有可测的额外耗时；stdin 类命令反而从“永不返回”变成约 300–380 ms 正常返回。
- **路径强调的渲染成本**：带路径参数的输入行首次渲染需要查询设备目录，`enhanced render` 约 400–570 ms（文件/搜索类）；无路径命令约 80–300 ms。每个提示符后缓存会刷新，因此这是每条新命令的一次性成本，且与用户实际打字时间重叠；粘贴整行时最明显。
- **`ls` 本地排版**：增强会话比原生 raw 多约 100–180 ms，用于 `-F` 类型探测、分栏/长格式解析和按类型/扩展名着色；大目录（`/system/bin`）仍在约 330 ms 内完成。
- **OpenHarmony 命令**：设备侧本身占主导（`aa dump` 276–465 ms、`hidumper` 347–534 ms），增强包装相对增量与普通命令一致。
- **大输出**：`seq 1 1000` 与 `seq 1 3000 | tail -1` 均在约 300–360 ms 完成；输出按块流式显示，不等待进程结束。持续日志（`hilog`、`dmesg`）的首屏和 Ctrl+C 时延由真机实时输出测试单独验证，不包含在本表的中位数里。
- **波动**：上表为单次会话中位数，受设备负载、hdc daemon 状态、USB/网络链路和首次调用缓存影响；`enhanced render` 受打字/粘贴节奏和 PSReadLine 重绘影响，波动比执行耗时大。Windows 尚未实机测量。

## 复现

```sh
python3 tests/HdcShell.Bench.py <serial>
```

需要 `pwsh`、`hdc`、`pexpect`、`pyte`、`wcwidth`，并连接一台在线设备。测试会在 `/data/local/tmp` 创建一个临时夹具并在退出时删除；不会修改其他设备文件。增强会话默认从仓库加载模块，也可用 `HDC_TEST_MODULE` 指向安装后的模块：

```sh
HDC_TEST_MODULE=~/.local/share/powershell/Modules/TerminalSuggestions/TerminalSuggestions.psd1 \
  python3 tests/HdcShell.Bench.py <serial>
```
