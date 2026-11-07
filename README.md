# TerminalSuggestions

PowerShell 终端体验增强模块，为 OpenHarmony 的 `hdc`（类似 adb）提供补全、设备上下文管理和增强版 `hdc shell`。

使用 PSReadLine 和 .NET 实现，无需 GUI 终端模拟器。当前规格与开发约束见 [AGENTS.md](AGENTS.md)，差异检视和验证记录见 [hdc shell 对齐检视](docs/hdc-shell-alignment.md)。

## 环境准备

- PowerShell 7.2+、PSReadLine 2.2+；不支持 Windows PowerShell 5.1。
- 使用设备功能前，将 OpenHarmony SDK 的 `toolchains` 目录加入 `PATH`。
- Windows 通常使用 `...\OpenHarmony\Sdk\<version>\toolchains\hdc.exe`，Linux 使用对应 SDK 目录中的 `hdc`。Windows 尚未实机验证。

## 安装

将模块目录加入 `PSModulePath`，或将以下配置写入 `$PROFILE`：

```powershell
$env:PSModulePath = "/path/to/powershell" + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module TerminalSuggestions
Enable-TerminalSuggestion
```

这会启用普通 PowerShell 的高亮、历史预测和菜单补全。需要停用自定义预测时使用 `Disable-TerminalSuggestion`。

## 选择设备与执行命令

```powershell
Get-HdcTarget                       # 查看在线设备
Use-HdcDevice <serial>               # 设置默认设备
Invoke-HdcCommand shell echo hi      # 在当前设备执行命令
Invoke-HdcCommand -AllDevices shell echo hi
Use-HdcDevice -Clear                 # 清除默认设备
```

设置默认设备后，可以直接使用 `hdc`；也可通过 `hdc -t <serial> ...` 临时指定设备。

导入模块后，输入 `hdc` 并按 Tab 可补全子命令、设备序列号、安装包和相关路径。例如：

```powershell
hdc <Tab>
hdc -t <Tab>
hdc install <Tab>
hdc shell /data/<Tab>
```

其中 `<Tab>` 表示按 Tab 键。

## 使用增强 hdc shell

```powershell
hdc shell                         # 当前设备
hdc -t <serial> shell              # 指定设备
Enter-HdcShell -Serial <serial>    # 直接调用入口
```

设备会话提供路径强调、历史预测、Tab 补全、着色目录列表和实时命令输出。提示符示例：

```text
3DK0224A12000841 hmdfs ->
```

直接执行 `hilog`、`dmesg` 等设备命令即可。Ctrl+C 中断当前命令并留在设备会话；`exit` 或空行 Ctrl+D 退出。

需要运行 `vi`、`top` 等交互程序时，使用原始透传模式：

```powershell
hdc shell --raw
```

完整的按键、颜色、输出、历史及能力边界见 [规格与约束](AGENTS.md#增强-hdc-shell)。

## 项目导航

| 路径 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 产品规格、开发约束和验收要求 |
| `TerminalSuggestions/` | PowerShell 模块与 C# 适配器 |
| `tests/` | 基础、按键对照、终端属性和真机检查 |
| [docs/hdc-shell-alignment.md](docs/hdc-shell-alignment.md) | 对齐差异、历史变更和验证记录 |
