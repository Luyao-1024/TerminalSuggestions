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
    # Start with a hard reset: binary output or an interrupted command must not
    # leak its SGR attributes into the prompt.
    "$($PSStyle.Reset)$($PSStyle.Foreground.Blue)$script:HdcShellSerial $display$($PSStyle.Reset) $arrow->$($PSStyle.Reset) "
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
    # Output must not inherit an SGR attribute left by the input line or a
    # binary/special file. Start from a hard reset.
    [Console]::Write($PSStyle.Reset)
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
        'l' { return $PSStyle.Foreground.FromRgb(0x00FFFF) }
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

function Get-HdcShellMarkerSuffix {
    param([char]$Marker, [string]$MarkerMode)
    # 'all' is an explicit -F, 'dir' is an explicit -p (directory marker only).
    if ($MarkerMode -eq 'all') { return [string]$Marker }
    if ($MarkerMode -eq 'dir' -and $Marker -eq '/') { return '/' }
    return ''
}

function Write-HdcShellOutput {
    param([object[]]$Lines, [string]$Mode = 'none', [string]$MarkerMode = 'none')
    if ($Mode -eq 'none') { Write-HdcShellText $Lines; return }
    if (-not $Lines -or $Lines.Count -eq 0) { return }
    [Console]::Write($PSStyle.Reset)
    if ($Mode -eq 'long') { Write-HdcShellLongOutput $Lines; return }
    if ($Mode -eq 'single') { Write-HdcShellSingleOutput $Lines $MarkerMode; return }
    Write-HdcShellColumnOutput $Lines $MarkerMode
}

function Write-HdcShellColumnOutput {
    param([object[]]$Lines, [string]$MarkerMode)
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
            [void]$row.Append($PSStyle.Reset)
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
            $suffix = Get-HdcShellMarkerSuffix $marker $MarkerMode
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
    param([object[]]$Lines, [string]$MarkerMode)
    $builder = [System.Text.StringBuilder]::new()
    $pending = 0
    foreach ($line in $Lines) {
        $text = "$line"
        if (-not $text) {
            [void]$builder.AppendLine()
        } elseif ($text.EndsWith(':')) {
            [void]$builder.AppendLine("$($PSStyle.Reset)$($PSStyle.Foreground.BrightBlue)$text$($PSStyle.Reset)")
        } elseif ($text -match '^(.+?)([/@*|=])$') {
            $name = $Matches[1]
            $marker = $Matches[2][0]
            $suffix = Get-HdcShellMarkerSuffix $marker $MarkerMode
            $color = Get-HdcShellFileColor $name (Get-HdcShellMarkerKind $marker)
            $rendered = if ($color) { "$color$name$suffix$($PSStyle.Reset)" } else { $name + $suffix }
            [void]$builder.AppendLine("$($PSStyle.Reset)$rendered")
        } else {
            $color = Get-HdcShellFileColor $text ([char]'-')
            $rendered = if ($color) { "$color$text$($PSStyle.Reset)" } else { $text }
            [void]$builder.AppendLine("$($PSStyle.Reset)$rendered")
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
                $rendered = $head + "$($PSStyle.Foreground.FromRgb(0x00FFFF))$left$($PSStyle.Reset)$arrow" +
                    "$($PSStyle.Foreground.FromRgb(0x00FFFF))$target$($PSStyle.Reset)"
            } else {
                $color = Get-HdcShellFileColor $name $kind
                $rendered = $head + $(if ($color) { "$color$name$($PSStyle.Reset)" } else { $name })
            }
        }
        [void]$builder.AppendLine("$($PSStyle.Reset)$rendered")
        if (++$pending -ge 256) {
            [Console]::Write($builder.ToString())
            [void]$builder.Clear()
            $pending = 0
        }
    }
    if ($builder.Length -gt 0) { [Console]::Write($builder.ToString()) }
}

function New-HdcShellRemoteScript {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Marker,
        [string]$Cwd = '/',
        [string]$OldCwd = '',
        [int]$LastExitCode = 0
    )
    # hdc keeps the RPC channel open as the remote shell's stdin, so closing
    # the host side never reaches the device as EOF. Without this redirect a
    # command that reads stdin (cat, sort, head, read, ...) blocks the whole
    # session forever. The interactive keys are never forwarded to commands,
    # so EOF is the only stdin the enhanced session can honestly provide.
    $finish = "echo '" + $Marker + "'" + '$?' + '; pwd'
    $onInterrupt = "echo '" + $Marker + "130'; pwd; exit 130"
    'exec </dev/null' + "`n" +
        'read -r __ts_pid __ts_name __ts_state __ts_ppid __ts_pgid __ts_rest < /proc/$$/stat' + "`n" +
        "printf '" + $Marker + 'PID:%s:%s\n'' "$$" "$__ts_pgid"' + "`n" +
        "trap '" + $onInterrupt.Replace("'", "'\''") + "' INT" + "`n" +
        "cd '" + $Cwd.Replace("'", "'\''") + "' || exit" + "`n" +
        "OLDPWD='" + $OldCwd.Replace("'", "'\''") + "'" + "`n" +
        '(exit ' + $LastExitCode + ')' + "`n" + $Command + "`n" +
        $finish
}

function Get-HdcShellLsPlan {
    param([Parameter(Mandatory)][string]$Line)
    $trimmed = $Line.Trim()
    if ($trimmed -notmatch '^ls(\s+.*)?$') { return $null }
    if ($trimmed -cmatch '[|&;<>`]') { return $null }
    if ($trimmed -match '\$\(|[\[\]\*\?]') { return $null }
    # Device command names are case sensitive: LS is not ls.
    if (-not ($trimmed -cmatch '^ls(\s+.*)?$')) { return $null }
    $lsArgs = $Matches[1]
    $flags = ''
    $skip = $false
    foreach ($token in ($lsArgs -split '\s+')) {
        if (-not $token) { continue }
        if ($token -match '^-([A-Za-z0-9]+)$') { $flags += $Matches[1]; continue }
        if ($token.StartsWith('-')) { $skip = $true; break }
    }
    # Flag checks are case sensitive: -S sorts by size and is locally reflowed,
    # while -s prints block counts and stays raw.
    if ($skip -or $flags -cmatch '[misQ]') { return $null }
    $markerMode = 'none'
    if ($flags -cmatch '[lngo]') {
        $mode = 'long'
    } elseif ($flags -cmatch '1') {
        $mode = 'single'
    } elseif ($flags -cmatch 'h') {
        # Device ls -h prints its own total line; keep that layout raw.
        return $null
    } else {
        $mode = 'columns'
    }
    $execLine = $Line
    if ($mode -ne 'long') {
        if ($flags -cmatch 'F') {
            # Already requested by the user: keep every type marker.
            $markerMode = 'all'
        } else {
            $execLine = 'ls -F' + $lsArgs
            # -p asks only for the directory marker; other markers must not
            # leak from the internal -F.
            if ($flags -cmatch 'p') { $markerMode = 'dir' }
        }
        # The local renderers expect one entry per line; -C/-x would make the
        # device group them before we reflow.
        $execLine += ' -1'
    }
    [pscustomobject]@{ Mode = $mode; MarkerMode = $markerMode; ExecLine = $execLine }
}

function Test-HdcShellSimpleCat {
    param([AllowEmptyString()][string]$Line)
    # A simple cat can be transported as device-side base64, which is the only
    # way binary bytes survive the hdc shell channel. Pipelines/redirections
    # stay entirely on the device and must not be rewritten.
    $text = $Line.Trim()
    if ($text -cnotmatch '^cat(?:\s|$)') { return $false }
    if ($text -match '[|&;<>`]') { return $false }
    if ($text -match '\$\(' -or $text -match '[\r\n]') { return $false }
    return $true
}

function Get-HdcShellFastCatPath {
    param([AllowEmptyString()][string]$Line, [string]$Cwd, [string]$Application, [string]$Serial)
    $text = $Line.Trim()
    if ($text -cnotmatch '^cat\s') { return $null }
    if ($text -match '[|&;<>`]' -or $text -match '\$\(|[\r\n]') { return $null }
    $pattern = '(?<Comment>\#[^\n]*)|(?<Operator>\d*(?:>>?|<<?)|\|\||&&|[|;&()\n])|(?<Word>(?:''[^'']*(?:''|$)|"(?:\\.|[^"\\])*(?:"|$)|\\.|[^\s''"\\|&;<>()])+)'
    $words = [Collections.Generic.List[string]]::new()
    foreach ($token in [regex]::Matches($text, $pattern)) {
        if ($token.Groups['Comment'].Success -or $token.Groups['Operator'].Success) { return $null }
        if (-not $token.Groups['Word'].Success) { return $null }
        $words.Add((ConvertFrom-HdcShellWord $token.Value))
    }
    if ($words.Count -ne 2 -or $words[0] -cne 'cat') { return $null }
    $path = $words[1]
    if (-not $path -or $path.StartsWith('-')) { return $null }
    if ($path -match '[*?\[\]{}~$]') { return $null }
    $remote = if ($path.StartsWith('/')) { $path }
        elseif (-not $Cwd -or $Cwd -eq '/') { '/' + $path }
        else { $Cwd.TrimEnd('/') + '/' + $path }
    # Only regular files use the file channel. Directories, FIFOs and device
    # nodes keep the ordinary device-side cat semantics.
    $quoted = "'" + $remote.Replace("'", "'\''") + "'"
    try {
        # hdc shell does not propagate the remote exit status; use a visible
        # probe line so a FIFO/directory/missing path is not sent to file recv.
        $response = Invoke-HdcCapture $Application @('-t', $Serial, 'shell',
            "if [ -f $quoted ]; then printf 'YES\n'; else printf 'NO\n'; fi") -TimeoutSeconds 3
    } catch { return $null }
    if (-not (@($response.Lines) -contains 'YES')) { return $null }
    return $remote
}

function Receive-HdcFileToTemp {
    param([string]$Application, [string]$Serial, [string]$RemotePath, [int]$TimeoutSeconds = 10)
    $temp = [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName())
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $Application
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in @('-t', $Serial, 'file', 'recv', $RemotePath, $temp)) {
        $process.StartInfo.ArgumentList.Add($argument)
    }
    $success = $false
    $timedOut = $false
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true); [void]$process.WaitForExit(2000) } catch { }
        }
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if (-not $timedOut -and $text -match '\[Fail\]|Error') { return $null }
        if (-not (Test-Path -LiteralPath $temp)) {
            if ($timedOut) { return [pscustomobject]@{ Path = $null; Size = 0; TimedOut = $true } }
            return $null
        }
        $success = $true
        [pscustomobject]@{
            Path = $temp
            Size = (Get-Item -LiteralPath $temp).Length
            TimedOut = $timedOut
        }
    } catch { return $null }
    finally {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        $process.Dispose()
        if (-not $success) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-HdcShellBase64Bytes {
    param([byte[]]$Bytes)
    [Console]::Write("`e[0m`r`n[hdc shell] 二进制内容，以下为 base64；可用 base64 -d 解码，原文件建议 hdc file recv。`r`n`e[0m")
    $text = [Convert]::ToBase64String($Bytes)
    $builder = [Text.StringBuilder]::new($text.Length + [Math]::Ceiling($text.Length / 76) + 1)
    for ($i = 0; $i -lt $text.Length; $i += 76) {
        $count = [Math]::Min(76, $text.Length - $i)
        [void]$builder.Append($text, $i, $count).Append("`n")
    }
    [Console]::Write($builder.ToString())
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
            Add-Type -Path @(
                (Join-Path $PSScriptRoot 'HdcShellProcess.cs'),
                (Join-Path $PSScriptRoot 'HdcShellSession.cs')) -ErrorAction Stop
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
        # Unix fast path: one long-lived hdc shell with a per-command subshell.
        # Unsupported hosts return null and keep the per-command RPC path.
        $script:HdcShellSession = $null
        $script:HdcShellSessionRetry = $false
        try {
            $script:HdcShellSession = [TerminalSuggestions.HdcShellSession]::StartIfSupported(
                $exe.Source, $Serial, $script:HdcShellMarker)
        } catch { $script:HdcShellSession = $null }
        while ($true) {
            if (-not $script:HdcShellSession -and $script:HdcShellSessionRetry) {
                $script:HdcShellSessionRetry = $false
                try {
                    $script:HdcShellSession = [TerminalSuggestions.HdcShellSession]::StartIfSupported(
                        $exe.Source, $Serial, $script:HdcShellMarker)
                } catch { $script:HdcShellSession = $null }
            }
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
            # A menu that was drawn and not fully erased (fast Enter, lost
            # state or a failed clear) must not leave candidate text beside the
            # next prompt. Erase from the cursor to the end of the screen.
            if ($script:HdcShellCompletionDrawn) {
                [Console]::Write("`e[0J")
                $script:HdcShellCompletionDrawn = $false
            }
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
            if ($trimmed -cmatch '^(exit|logout)(?:\s+[0-9]+)?\s*$') { break }

            # ls is post-processed locally: -F type markers for simple listings,
            # permission/name parsing for long format. Layouts this does not
            # understand (inode/size/comma/quote output, long options, globs and
            # shell syntax) are left untouched.
            $execLine = $line
            $lsMode = 'none'
            $markerMode = 'none'
            $plan = Get-HdcShellLsPlan $line
            if ($plan) {
                $execLine = $plan.ExecLine
                $lsMode = $plan.Mode
                $markerMode = $plan.MarkerMode
            }

            # Unknown commands stream by default. Only simple ls forms whose
            # output is locally reformatted retain the existing buffered view.
            # The persistent session is used when it can carry this command;
            # otherwise the per-command RPC path preserves state and limits.
            [Console]::Write($PSStyle.Reset)
            $result = $null
            # Large regular-file cat goes through hdc's binary file channel:
            # the shell channel is limited to roughly 0.4 MB/s for base64 text,
            # while file recv is tens of MB/s on the same link.
            $fastPath = $null
            try {
                if ($script:HdcShellSession -and $script:HdcShellSession.Alive) {
                    $fastPath = Get-HdcShellFastCatPath -Line $execLine -Cwd $cwd `
                        -Application $exe.Source -Serial $Serial
                }
                if ($fastPath) {
                    $received = Receive-HdcFileToTemp -Application $exe.Source -Serial $Serial `
                        -RemotePath $fastPath -TimeoutSeconds 10
                    if ($received) {
                        try {
                            $bytes = [byte[]]@()
                            if ($received.Path -and (Test-Path -LiteralPath $received.Path)) {
                                $bytes = [IO.File]::ReadAllBytes($received.Path)
                            }
                            [Console]::Write($PSStyle.Reset)
                            if ($bytes.Length -gt 0) {
                                if ([TerminalSuggestions.HdcShellProcess]::LooksLikeBinaryBytes($bytes)) {
                                    Write-HdcShellBase64Bytes $bytes
                                } else {
                                    $stdoutStream = [Console]::OpenStandardOutput()
                                    $stdoutStream.Write($bytes, 0, $bytes.Length)
                                    $stdoutStream.Flush()
                                }
                            }
                            $result = [TerminalSuggestions.HdcShellProcessResult]::new()
                            if ($received.TimedOut) {
                                # Keep the partial bytes readable and make the
                                # truncation explicit instead of falling back to
                                # the slower shell channel.
                                [Console]::WriteLine()
                                [Console]::Write("`e[0m[hdc shell] 读取超时（10 秒），以上为已获取的内容，显示不完整。`e[0m`n")
                                $result.ExitCode = 124
                            } else {
                                $result.ExitCode = 0
                            }
                        } finally {
                            if ($received.Path) {
                                Remove-Item -LiteralPath $received.Path -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
            } catch [System.Management.Automation.PipelineStoppedException] {
                # Ctrl+C during the file-channel preparation must not leave the
                # device shell.
                $script:HdcShellLastExitCode = 130
                $global:LASTEXITCODE = 130
                [Console]::WriteLine('^C')
                continue
            }
            $binaryTransport = Test-HdcShellSimpleCat $execLine
            if (-not $result -and $script:HdcShellSession -and $script:HdcShellSession.Alive -and
                $script:HdcShellSession.CanRun($execLine, $cwd, $script:HdcShellOldCwd,
                    $script:HdcShellLastExitCode, $binaryTransport)) {
                $result = $script:HdcShellSession.Run($execLine, $cwd, $script:HdcShellOldCwd,
                    $script:HdcShellLastExitCode, $script:HdcShellMarker, ($lsMode -ne 'none'),
                    $binaryTransport, [Microsoft.PowerShell.PSConsoleReadLine])
                if ($result.Faulted) {
                    # The command may already have run; do not replay it via a
                    # second RPC. Rebuild the session for the next prompt.
                    try { $script:HdcShellSession.Dispose() } catch { }
                    $script:HdcShellSession = $null
                    $script:HdcShellSessionRetry = $true
                }
            }
            if (-not $result) {
                $remote = New-HdcShellRemoteScript -Command $execLine -Marker $script:HdcShellMarker `
                    -Cwd $cwd -OldCwd $script:HdcShellOldCwd -LastExitCode $script:HdcShellLastExitCode
                $result = [TerminalSuggestions.HdcShellProcess]::Run($exe.Source, $Serial, $remote,
                    $script:HdcShellMarker, $lsMode -ne 'none', [Microsoft.PowerShell.PSConsoleReadLine])
            }
            if ($lsMode -ne 'none' -and $result.Output) {
                $text = $result.Output
                if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
                Write-HdcShellOutput @($text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) $lsMode $markerMode
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
            # A newly created/removed/renamed file must be reflected by the
            # next input line's path emphasis. Read-only commands keep the
            # 10-second listing cache for performance.
            if (Test-HdcShellMayChangeFiles $line) {
                Clear-HdcShellDirectoryCache
            }
        }
    } finally {
        if ($script:HdcShellSession) {
            try { $script:HdcShellSession.Dispose() } catch { }
            finally { $script:HdcShellSession = $null }
        }
        try { Save-HdcShellHistory $script:HdcShellHistoryCwd }
        finally {
            try { Clear-HdcShellCompletionMenu }
            finally {
                $script:HdcShellCompletionState = $null
                $script:HdcShellCompletionDrawn = $false
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
