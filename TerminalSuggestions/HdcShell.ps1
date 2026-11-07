$script:HdcShellSerial = $null
$script:HdcShellBins = @()
$script:HdcShellMarker = '@@HDCSHELL_RC@@'

function Get-HdcShellBinary {
    param([string]$Serial)
    $exe = Find-HdcApplication
    if (-not $exe) { return @() }
    Get-HdcCached -Key "bins:$Serial" -TtlSeconds 300 -Fetch {
        # Discover executables from the device PATH, never from the host PATH.
        $response = Invoke-HdcCapture $exe.Source @('-t', $Serial, 'shell', (
            'IFS=:; for d in $PATH; do [ -n "$d" ] || d=.; ' +
            'find -L "$d" -maxdepth 1 -type f -executable -print 2>/dev/null; done'))
        $output = $response.Lines
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($line in $output) {
            $text = ("$line" -split '/')[-1]
            if ($text.EndsWith(':')) { continue }
            if ($text -match '^[A-Za-z_][A-Za-z0-9_.+-]*$') { [void]$names.Add($text) }
        }
        @($names | Sort-Object -CaseSensitive)
    }
}

function Get-HdcShellHistoryFile {
    param([string]$Path)
    if (-not $Path) { $Path = '/' }
    # '/' -> '%2F' keeps one file per remote directory, independent of device.
    $name = $Path.Replace('%', '%25').Replace('/', '%2F')
    if ($name.Length -gt 180) {
        $hash = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Path))
        $name = 'h' + [Convert]::ToHexString($hash).Substring(0, 32)
    }
    Join-Path $script:HdcShellHistoryRoot ($name + '.txt')
}

function Get-HdcShellHomePath {
    if ($null -eq $script:HdcShellHome) {
        $exe = Find-HdcApplication
        if (-not $exe) { return '' }
        $script:HdcShellHome = ((Invoke-HdcCapture $exe.Source @('-t', $script:HdcShellSerial,
            'shell', 'printf ''%s'' "$HOME"') -TimeoutSeconds 3).Lines -join '').Trim()
    }
    $script:HdcShellHome
}

function Get-HdcShellPrompt {
    $display = if ($script:HdcShellCwd -eq '/') { '/' } else { ($script:HdcShellCwd.TrimEnd('/') -split '/')[-1] }
    $arrow = if ($script:HdcShellLastExitCode -eq 0) { $PSStyle.Foreground.Green } else { $PSStyle.Foreground.Red }
    "$($PSStyle.Foreground.Blue)$script:HdcShellSerial $display$($PSStyle.Reset) $arrow->$($PSStyle.Reset) "
}

function Import-HdcShellHistory {
    param([string]$Path)
    [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
    if (-not $script:HdcShellHistoryRoot) { return }
    $file = Get-HdcShellHistoryFile $Path
    if (-not (Test-Path -LiteralPath $file)) { return }
    foreach ($line in [System.IO.File]::ReadLines($file)) {
        if ($line.Trim()) { [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($line) }
    }
}

function Save-HdcShellHistory {
    param([string]$Path)
    if (-not $Path -or -not $script:HdcShellHistoryRoot) { return }
    $file = Get-HdcShellHistoryFile $Path
    # Keep the newest occurrence of each command, oldest first, so the file
    # does not grow when the same history is loaded and saved repeatedly.
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $keep = [System.Collections.Generic.List[string]]::new()
    $items = @([Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems())
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        $command = $items[$i].CommandLine
        if ($command -and $seen.Add($command)) { $keep.Add($command) }
    }
    if ($keep.Count -eq 0) {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        return
    }
    $keep.Reverse()
    Set-Content -LiteralPath $file -Value $keep -Encoding UTF8
}

function Write-HdcShellText {
    param([object[]]$Lines)
    if (-not $Lines -or $Lines.Count -eq 0) { return }
    # One console write per 256 lines keeps large outputs fast without
    # building a second full copy of the text in memory.
    $builder = [System.Text.StringBuilder]::new()
    $pending = 0
    foreach ($line in $Lines) {
        [void]$builder.AppendLine("$line")
        if (++$pending -ge 256) {
            [Console]::Write($builder.ToString())
            [void]$builder.Clear()
            $pending = 0
        }
    }
    if ($builder.Length -gt 0) { [Console]::Write($builder.ToString()) }
}

function Find-HdcShellMarker {
    param([object[]]$Lines)
    if (-not $Lines) { return $null }
    $marker = $script:HdcShellMarker
    # The marker is appended last (followed only by pwd), so scan backwards:
    # this is O(1) for normal commands instead of a regex over every line.
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = "$($Lines[$i])"
        if ($line.Length -le $marker.Length) { continue }
        # Commands that end without a newline (clear, printf) glue the marker
        # onto their last line, so match anywhere in the line, not just at 0.
        $position = $line.IndexOf($marker, [StringComparison]::Ordinal)
        if ($position -lt 0) { continue }
        $code = $line.Substring($position + $marker.Length)
        if ($code -match '^\d+$') {
            return [pscustomobject]@{ Index = $i; Position = $position; Code = [int]$code }
        }
    }
    return $null
}

function Get-HdcShellFileColor {
    param([string]$Name, [char]$Kind = [char]0)
    switch ($Kind) {
        'd' { return $PSStyle.Foreground.BrightBlue }
        'x' { return $PSStyle.Foreground.BrightGreen }
        'l' { return $PSStyle.Foreground.BrightCyan }
        'p' { return $PSStyle.Foreground.BrightYellow }
        's' { return $PSStyle.Foreground.BrightMagenta }
        'c' { return $PSStyle.Foreground.BrightYellow }
        'b' { return $PSStyle.Foreground.BrightYellow }
    }
    if (-not $Name) { return '' }
    $lower = $Name.ToLowerInvariant()
    if ($lower -match '\.(tar|tgz|tbz|txz|zip|gz|bz2|xz|zst|7z|rar|jar|deb|rpm|apk|hap|hsp|app|whl|iso)$') {
        return $PSStyle.Foreground.BrightRed
    }
    if ($lower -match '\.(png|jpe?g|gif|bmp|svg|webp|ico|tiff?)$') {
        return $PSStyle.Foreground.BrightMagenta
    }
    if ($lower -match '\.(mp4|mkv|avi|mov|webm|mp3|wav|flac|ogg|m4a)$') {
        return $PSStyle.Foreground.Magenta
    }
    return ''
}

function Get-HdcShellMarkerKind {
    param([char]$Marker)
    switch ($Marker) {
        '/' { return [char]'d' }
        '*' { return [char]'x' }
        '@' { return [char]'l' }
        '|' { return [char]'p' }
        '=' { return [char]'s' }
    }
    return [char]'-'
}

function Write-HdcShellOutput {
    param([object[]]$Lines, [string]$Mode = 'none', [bool]$KeepMarker = $false)
    if ($Mode -eq 'none') { Write-HdcShellText $Lines; return }
    if (-not $Lines -or $Lines.Count -eq 0) { return }
    if ($Mode -eq 'long') { Write-HdcShellLongOutput $Lines; return }
    if ($Mode -eq 'single') { Write-HdcShellSingleOutput $Lines $KeepMarker; return }
    Write-HdcShellColumnOutput $Lines $KeepMarker
}

function Write-HdcShellColumnOutput {
    param([object[]]$Lines, [bool]$KeepMarker)
    $width = try { [Console]::WindowWidth } catch { 80 }
    if ($width -le 0) { $width = 80 }
    $names = [System.Collections.Generic.List[string]]::new()
    $colors = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($names.Count -eq 0) { return }
        $max = 0
        foreach ($name in $names) {
            if ($name.Length -gt $max) { $max = $name.Length }
        }
        $colWidth = $max + 2
        $cols = [Math]::Max(1, [Math]::Floor(($width - 1) / $colWidth))
        $rows = [Math]::Ceiling($names.Count / $cols)
        $builder = [System.Text.StringBuilder]::new()
        for ($r = 0; $r -lt $rows; $r++) {
            $row = [System.Text.StringBuilder]::new()
            for ($c = 0; $c -lt $cols; $c++) {
                $index = $c * $rows + $r
                if ($index -ge $names.Count) { continue }
                $pad = $names[$index].PadRight($colWidth)
                if ($colors[$index]) {
                    [void]$row.Append($colors[$index])
                    [void]$row.Append($pad)
                    [void]$row.Append($PSStyle.Reset)
                } else {
                    [void]$row.Append($pad)
                }
            }
            [void]$builder.AppendLine($row.ToString().TrimEnd())
        }
        [Console]::Write($builder.ToString())
        $names.Clear()
        $colors.Clear()
    }
    foreach ($line in $Lines) {
        $text = "$line"
        if (-not $text) { & $flush; [Console]::WriteLine(); continue }
        if ($text.EndsWith(':')) {
            & $flush
            [Console]::WriteLine("$($PSStyle.Foreground.BrightBlue)$text$($PSStyle.Reset)")
            continue
        }
        # 'ls -F' markers: / dir, * executable, @ symlink, | fifo, = socket
        if ($text -match '^(.+?)([/@*|=])$') {
            $name = $Matches[1]
            $marker = $Matches[2][0]
            $suffix = if ($KeepMarker) { [string]$marker } else { '' }
            $names.Add($name + $suffix)
            $colors.Add((Get-HdcShellFileColor $name (Get-HdcShellMarkerKind $marker)))
        } else {
            $names.Add($text)
            $colors.Add((Get-HdcShellFileColor $text ([char]'-')))
        }
    }
    & $flush
}

function Write-HdcShellSingleOutput {
    param([object[]]$Lines, [bool]$KeepMarker)
    $builder = [System.Text.StringBuilder]::new()
    $pending = 0
    foreach ($line in $Lines) {
        $text = "$line"
        if (-not $text) {
            [void]$builder.AppendLine()
        } elseif ($text.EndsWith(':')) {
            [void]$builder.AppendLine("$($PSStyle.Foreground.BrightBlue)$text$($PSStyle.Reset)")
        } elseif ($text -match '^(.+?)([/@*|=])$') {
            $name = $Matches[1]
            $marker = $Matches[2][0]
            $suffix = if ($KeepMarker) { [string]$marker } else { '' }
            $color = Get-HdcShellFileColor $name (Get-HdcShellMarkerKind $marker)
            $rendered = if ($color) { "$color$name$suffix$($PSStyle.Reset)" } else { $name + $suffix }
            [void]$builder.AppendLine($rendered)
        } else {
            $color = Get-HdcShellFileColor $text ([char]'-')
            $rendered = if ($color) { "$color$text$($PSStyle.Reset)" } else { $text }
            [void]$builder.AppendLine($rendered)
        }
        if (++$pending -ge 256) {
            [Console]::Write($builder.ToString())
            [void]$builder.Clear()
            $pending = 0
        }
    }
    if ($builder.Length -gt 0) { [Console]::Write($builder.ToString()) }
}

function Write-HdcShellLongOutput {
    param([object[]]$Lines)
    $builder = [System.Text.StringBuilder]::new()
    $pending = 0
    foreach ($line in $Lines) {
        $text = "$line"
        $rendered = $text
        if (-not $text) {
            $rendered = ''
        } elseif ($text.EndsWith(':')) {
            $rendered = "$($PSStyle.Foreground.BrightBlue)$text$($PSStyle.Reset)"
        } elseif ($text -match '^(?<mode>[-dlbcps][rwxsStT-]{9}\S*)\s+(?<meta>.+?)\s+(?<date>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}|[A-Z][a-z]{2}\s+\d+\s+(?:\d{2}:\d{2}|\d{4}))\s+(?<name>.+)$') {
            $mode = $Matches['mode']
            $name = $Matches['name']
            $kind = $mode[0]
            $perms = $mode.Substring(1)
            if ($kind -eq '-' -and $perms -match '[xsStT]') { $kind = [char]'x' }
            $typeColor = Get-HdcShellFileColor $name $kind
            $typeChar = if ($typeColor) { "$typeColor$($mode[0])$($PSStyle.Reset)" } else { "$($mode[0])" }
            $tail = $text.Substring($mode.Length, $text.Length - $name.Length - $mode.Length)
            $head = $typeChar + $perms + $tail
            $arrow = ' -> '
            $arrowIndex = if ($mode[0] -eq 'l') { $name.IndexOf($arrow) } else { -1 }
            if ($arrowIndex -ge 0) {
                $left = $name.Substring(0, $arrowIndex)
                $target = $name.Substring($arrowIndex + $arrow.Length)
                $rendered = $head + "$($PSStyle.Foreground.BrightCyan)$left$($PSStyle.Reset)$arrow" +
                    "$($PSStyle.Foreground.BrightCyan)$target$($PSStyle.Reset)"
            } else {
                $color = Get-HdcShellFileColor $name $kind
                $rendered = $head + $(if ($color) { "$color$name$($PSStyle.Reset)" } else { $name })
            }
        }
        [void]$builder.AppendLine($rendered)
        if (++$pending -ge 256) {
            [Console]::Write($builder.ToString())
            [void]$builder.Clear()
            $pending = 0
        }
    }
    if ($builder.Length -gt 0) { [Console]::Write($builder.ToString()) }
}

function Enter-HdcShell {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Serial,
        [switch]$Raw
    )
    $exe = Find-HdcApplication
    if (-not $exe) { throw 'PATH 中找不到 hdc。' }
    if (-not $Serial) { $Serial = $script:HdcDevice }
    if (-not $Serial) {
        $targets = @(Get-HdcTarget)
        if ($targets.Count -eq 1) { $Serial = $targets[0] }
        elseif ($targets.Count -eq 0) { throw '没有在线设备。' }
        else { throw '多台设备在线,请先 Use-HdcDevice 选择,或 Enter-HdcShell -Serial <序列号>。' }
    }
    if ($Raw) {
        & $exe.Source -t $Serial shell
        return
    }

    $script:HdcShellSerial = $Serial
    $script:HdcShellBins = $null
    $script:HdcShellHome = $null
    $script:HdcShellBuiltins = @('cd', 'exit', 'logout', 'export', 'unset', 'echo', 'pwd', 'set', 'source',
        'read', 'test', 'kill', 'jobs', 'fg', 'bg', 'alias', 'unalias', 'type', 'which',
        'env', 'printenv', 'exec', 'eval', 'shift', 'trap', 'umask', 'wait', 'reboot')

    $savedEditor = Save-HdcShellEditor
    $savedHistory = @([Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems() |
        ForEach-Object { $_.CommandLine })
    $savedPrompt = (Get-Command prompt -ErrorAction SilentlyContinue).ScriptBlock
    $savedMarker = $script:HdcShellMarker
    $script:HdcShellMarker = '@@HDCSHELL_' + [guid]::NewGuid().ToString('N') + '@@'

    # Get-Item does not resolve the 'global:' path prefix; read the existing
    # definition through Get-Command so it can be put back on exit.
    $savedTabExpansion = (Get-Command TabExpansion2 -ErrorAction SilentlyContinue).ScriptBlock

    $historyDir = Split-Path (Get-PSReadLineOption).HistorySavePath -Parent
    $script:HdcShellHistoryRoot = Join-Path $historyDir 'HdcShellHistory'
    if (-not (Test-Path -LiteralPath $script:HdcShellHistoryRoot)) {
        New-Item -ItemType Directory -Path $script:HdcShellHistoryRoot -Force | Out-Null
    }

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
        if (-not ('TerminalSuggestions.HdcShellProcess' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'HdcShellProcess.cs') -ErrorAction Stop
        }
        Enable-HdcShellEditor
        $script:HdcShellOldCwd = ''
        $script:HdcShellLastExitCode = 0

        $cwd = [string]((Invoke-HdcCapture $exe.Source @('-t', $Serial, 'shell', 'pwd')).Lines | Select-Object -First 1)
        if (-not $cwd.StartsWith('/')) { $cwd = '/' }
        $script:HdcShellHistoryCwd = $cwd
        Import-HdcShellHistory $cwd

        # Completion goes through PSReadLine's own MenuComplete so the candidate
        # menu is drawn with PSReadLine's cursor bookkeeping instead of ours.
        $completionOverride = {
            [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
            [OutputType([System.Management.Automation.CommandCompletion])]
            param(
                [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory, Position = 0)]
                [AllowEmptyString()][string]$inputScript,
                [Parameter(ParameterSetName = 'ScriptInputSet', Position = 1)]
                [int]$cursorColumn = $inputScript.Length,
                [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 0)]
                [System.Management.Automation.Language.Ast]$ast,
                [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 1)]
                [System.Management.Automation.Language.Token[]]$tokens,
                [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 2)]
                [System.Management.Automation.Language.IScriptPosition]$positionOfCursor,
                [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
                [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
                [hashtable]$options = $null
            )
            if ($PSCmdlet.ParameterSetName -eq 'ScriptInputSet') {
                Get-HdcShellCompletion -Line $inputScript -Cursor $cursorColumn
            } else {
                Get-HdcShellCompletion -Line $ast.Extent.Text -Cursor (
                    $positionOfCursor.Offset - $ast.Extent.StartOffset)
            }
        }
        Set-Item Function:\global:TabExpansion2 -Value $completionOverride
        Set-Item Function:\global:prompt -Value { Get-HdcShellPrompt }
        while ($true) {
            # History and gray suggestions follow the remote directory; the
            # files are keyed by path only, so all devices share them.
            if ($script:HdcShellHistoryCwd -ne $cwd) {
                Save-HdcShellHistory $script:HdcShellHistoryCwd
                Import-HdcShellHistory $cwd
                $script:HdcShellHistoryCwd = $cwd
            }
            $script:HdcShellCwd = $cwd
            Reset-HdcShellHighlighting
            $script:HdcShellExit = $false
            $script:HdcShellCancelled = $false
            $script:HdcShellCompletionState = $null
            [Console]::Write((& prompt))
            try {
                $line = [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine(
                    [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace, $ExecutionContext, $null)
            } catch [System.Management.Automation.PipelineStoppedException] {
                break
            }
            # CancelLine leaves the cursor right after '^C'/'^D'; the next prompt
            # needs a fresh line so it does not run into the cancelled buffer.
            if ($script:HdcShellExit) { [Console]::WriteLine(); break }
            if ($script:HdcShellCancelled) {
                $script:HdcShellLastExitCode = 130
                $global:LASTEXITCODE = 130
                [Console]::WriteLine()
                continue
            }
            if ($null -eq $line) { [Console]::WriteLine(); continue }
            $trimmed = $line.Trim()
            if (-not $trimmed) { continue }
            if ($trimmed -match '^(exit|logout)(?:\s+[0-9]+)?\s*$') { break }

            # ls is post-processed locally: -F type markers for simple listings,
            # permission/name parsing for long format. Layouts this does not
            # understand (inode/size/comma/quote output, long options, globs and
            # shell syntax) are left untouched.
            $execLine = $line
            $lsMode = 'none'
            $keepMarker = $false
            if ($trimmed -match '^ls(\s+.*)?$' -and $trimmed -notmatch '[|&;<>`]' -and
                $trimmed -notmatch '\$\(|[\[\]\*\?]') {
                $lsArgs = $Matches[1]
                $flags = ''
                $skip = $false
                foreach ($token in ($lsArgs -split '\s+')) {
                    if (-not $token) { continue }
                    if ($token -match '^-([A-Za-z0-9]+)$') { $flags += $Matches[1]; continue }
                    if ($token.StartsWith('-')) { $skip = $true; break }
                }
                if (-not $skip -and $flags -notmatch '[misQ]') {
                    if ($flags -match '[lngo]') {
                        $lsMode = 'long'
                    } elseif ($flags -match '1') {
                        $lsMode = 'single'
                    } else {
                        $lsMode = 'columns'
                    }
                    if ($lsMode -ne 'long') {
                        if ($flags -match 'F') {
                            # Already requested by the user: keep the type markers visible.
                            $keepMarker = $true
                        } else {
                            $execLine = 'ls -F' + $lsArgs
                            if ($flags -match 'p') { $keepMarker = $true }
                        }
                        # The local renderers expect one entry per line; -C/-x
                        # would make the device group them before we reflow.
                        $execLine += ' -1'
                    }
                }
            }

            # Newlines keep trailing comments from swallowing the status marker.
            # Restore OLDPWD and $? alongside cwd before executing a new command.
            $finish = "echo '" + $script:HdcShellMarker + "'" + '$?' + '; pwd'
            $onInterrupt = "echo '" + $script:HdcShellMarker + "130'; pwd; exit 130"
            $remote = 'read -r __ts_pid __ts_name __ts_state __ts_ppid __ts_pgid __ts_rest < /proc/$$/stat' + "`n" +
                "printf '" + $script:HdcShellMarker + 'PID:%s:%s\n'' "$$" "$__ts_pgid"' + "`n" +
                "trap '" + $onInterrupt.Replace("'", "'\''") + "' INT" + "`n" +
                "cd '" + $cwd.Replace("'", "'\''") + "' || exit" + "`n" +
                "OLDPWD='" + $script:HdcShellOldCwd.Replace("'", "'\''") + "'" + "`n" +
                '(exit ' + $script:HdcShellLastExitCode + ')' + "`n" + $execLine + "`n" +
                $finish
            # Unknown commands stream by default. Only simple ls forms whose
            # output is locally reformatted retain the existing buffered view.
            $result = [TerminalSuggestions.HdcShellProcess]::Run($exe.Source, $Serial, $remote,
                $script:HdcShellMarker, $lsMode -ne 'none', [Microsoft.PowerShell.PSConsoleReadLine])
            if ($lsMode -ne 'none' -and $result.Output) {
                $text = $result.Output
                if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
                Write-HdcShellOutput @($text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) $lsMode $keepMarker
            }
            if ($result.Interrupted) { [Console]::WriteLine('^C') }
            $global:LASTEXITCODE = $result.ExitCode
            $script:HdcShellLastExitCode = $result.ExitCode
            if ($result.Directory) {
                $newCwd = $result.Directory
                if ($newCwd.StartsWith('/') -and $newCwd -cne $cwd) {
                    $script:HdcShellOldCwd = $cwd
                    $cwd = $newCwd
                }
            }
        }
    } finally {
        try { Save-HdcShellHistory $script:HdcShellHistoryCwd }
        finally {
            try { Clear-HdcShellCompletionMenu }
            finally {
                $script:HdcShellCompletionState = $null
                $script:HdcShellHistoryCwd = $null
                [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
                # Rebuild the original host history without re-writing it to disk or
                # applying the device shell's leading-space filter to host entries.
                Set-PSReadLineOption -AddToHistoryHandler $savedEditor.Options.AddToHistoryHandler `
                    -HistoryNoDuplicates:$false -HistorySaveStyle SaveNothing
                foreach ($h in $savedHistory) { [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($h) }
                Restore-HdcShellEditor $savedEditor
                $script:HdcShellMarker = $savedMarker
                $script:HdcShellSerial = $null
                $script:HdcShellHome = $null
                $script:HdcShellCwd = $null
                if ($savedPrompt) { Set-Item Function:\global:prompt -Value $savedPrompt }
                else { Remove-Item Function:\global:prompt -ErrorAction SilentlyContinue }
                if ($savedTabExpansion) {
                    Set-Item Function:\global:TabExpansion2 -Value $savedTabExpansion
                } else {
                    Remove-Item Function:\global:TabExpansion2 -ErrorAction SilentlyContinue
                }
                Write-Host "已退出 hdc shell。" -ForegroundColor Cyan
            }
        }
    }
}
