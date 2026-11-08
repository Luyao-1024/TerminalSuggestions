$script:HdcDevice = $null
$script:HdcCache = @{}
$script:HdcSubcommands = @(
    'shell', 'install', 'uninstall', 'file', 'hilog', 'list', 'target',
    'tconn', 'jpid', 'smode', 'tmode', 'keygen', 'bugreport', 'start', 'kill', 'version'
)

function Find-HdcApplication {
    foreach ($name in @('hdc', 'hdc_std')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) { return $cmd }
    }
}

function Invoke-HdcCapture {
    param([string]$Application, [string[]]$Arguments, [int]$TimeoutSeconds = 15)
    # RPC calls must have closed stdin. Otherwise hdc can read keystrokes from
    # the local editor or wait for terminal input even after a command ends.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $Application
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(100)) {
            if ($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                throw "hdc 查询超时($TimeoutSeconds 秒)。"
            }
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        # Keep blank lines and spaces in filenames; remove only the final
        # record separator, as PowerShell's native output reader would.
        if ($errors) { $text += $errors }
        if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
        [string[]]$lines = if ($text.Length) { @($text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") }) } else { @() }
        [pscustomobject]@{ Lines = $lines; ExitCode = $process.ExitCode }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Get-HdcCached {
    param([string]$Key, [int]$TtlSeconds, [scriptblock]$Fetch)
    $entry = $script:HdcCache[$Key]
    if ($entry -and ((Get-Date) - $entry.Time).TotalSeconds -lt $TtlSeconds) {
        return $entry.Data
    }
    $data = & $Fetch
    # Do not cache empty results: a transient failure would otherwise keep
    # completion broken for the whole TTL.
    if ($null -ne $data -and @($data).Count -gt 0) {
        $script:HdcCache[$Key] = @{ Time = Get-Date; Data = $data }
    }
    return $data
}

function Clear-HdcShellDirectoryCache {
    # A command that may create/remove/rename files must not leave the
    # completion/highlight listing cache stale for the next input line.
    $prefix = if ($script:HdcShellSerial) { "ls:$($script:HdcShellSerial):" } else { 'ls:' }
    foreach ($key in @($script:HdcCache.Keys)) {
        if ($key.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $script:HdcCache.Remove($key)
        }
    }
    $script:HdcShellHighlightListings = @{}
}

function Test-HdcShellMayChangeFiles {
    param([AllowEmptyString()][string]$Line)
    $text = $Line.Trim()
    if (-not $text) { return $false }
    # Pipelines, redirection and compound syntax may hide a mutation; be
    # conservative and refresh the directory view.
    if ($text -match '[|&;<>`]' -or $text -match '\$\(') { return $true }
    $tokens = @($text -split '\s+')
    $first = $tokens[0]
    $second = if ($tokens.Count -gt 1) { $tokens[1] } else { '' }
    switch -CaseSensitive ($first) {
        'ls' { return $false }
        'cat' { return $false }
        'grep' { return $false }
        'head' { return $false }
        'tail' { return $false }
        'wc' { return $false }
        'sort' { return $false }
        'pwd' { return $false }
        'echo' { return $false }
        'printf' { return $false }
        'stat' { return $false }
        'file' { return $false }
        'readlink' { return $false }
        'du' { return $false }
        'df' { return $false }
        'base64' { return $false }
        'xxd' { return $false }
        'od' { return $false }
        'cmp' { return $false }
        'diff' { return $false }
        'md5sum' { return $false }
        'sha256sum' { return $false }
        'seq' { return $false }
        'sleep' { return $false }
        'clear' { return $false }
        'cd' { return $false }
        'exit' { return $false }
        'logout' { return $false }
        'test' { return $false }
        'true' { return $false }
        'false' { return $false }
        ':' { return $false }
        'which' { return $false }
        'type' { return $false }
        'env' { return $false }
        'printenv' { return $false }
        'id' { return $false }
        'uname' { return $false }
        'date' { return $false }
        'uptime' { return $false }
        'free' { return $false }
        'hilog' { return $false }
        'dmesg' { return $false }
        'ps' { return $false }
        'find' { return ($text -match '\s-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)\b') }
        'sed' { return ($text -match '(^|\s)-[A-Za-z]*i') }
        'bm' { return $second -notin @('dump', 'list', 'get', 'help') }
        'aa' { return $second -notin @('dump', 'help') }
        'param' { return $second -ne 'get' }
        default { return $true }
    }
}

function Get-HdcTarget {
    [CmdletBinding()]
    param()
    $hdc = Find-HdcApplication
    if (-not $hdc) {
        Write-Error 'PATH 中找不到 hdc,请先将 OpenHarmony SDK toolchains 目录加入 PATH。'
        return
    }
    Get-HdcCached -Key 'targets' -TtlSeconds 5 -Fetch {
        $output = & $hdc.Source list targets 2>&1
        @($output | ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('[') -and $_ -notmatch '^\[Empty\]' })
    }
}

function Use-HdcDevice {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    param(
        [Parameter(ParameterSetName = 'Set', Position = 0, Mandatory)]
        [string]$Serial,
        [Parameter(ParameterSetName = 'Clear', Mandatory)]
        [switch]$Clear
    )
    if ($Clear) {
        $script:HdcDevice = $null
        $global:HdcCurrentDevice = $null
        Write-Verbose '已清除 hdc 设备上下文。'
        return
    }
    $online = Get-HdcTarget
    if ($online -and $Serial -notin $online) {
        Write-Warning "设备 $Serial 当前不在 hdc list targets 结果中(可能离线或序列号有误)。"
    }
    $script:HdcDevice = $Serial
    $global:HdcCurrentDevice = $Serial
    Write-Verbose "hdc 上下文已切换到 $Serial,后续 hdc 命令自动附加 -t。"
}

function hdc {
    $exe = Find-HdcApplication
    if (-not $exe) {
        Write-Error 'PATH 中找不到 hdc。'
        return
    }
    $shellArgs = @($args)
    $shellSerial = $script:HdcDevice
    if ($shellArgs.Count -ge 3 -and $shellArgs[0] -eq '-t') {
        $shellSerial = $shellArgs[1]
        $shellArgs = @($shellArgs[2..($shellArgs.Count - 1)])
    }
    if (($shellArgs.Count -eq 1 -and $shellArgs[0] -eq 'shell') -or
        ($shellArgs.Count -eq 2 -and $shellArgs[0] -eq 'shell' -and $shellArgs[1] -eq '--raw')) {
        Enter-HdcShell -Serial $shellSerial -Raw:($shellArgs.Count -eq 2)
        return
    }
    $argv = $args
    if ($script:HdcDevice -and $argv -notcontains '-t') {
        $argv = @('-t', $script:HdcDevice) + $argv
    }
    & $exe.Source @argv
}

function Invoke-HdcCommand {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromRemainingArguments)]
        [string[]]$ArgumentList,
        [string]$Serial,
        [switch]$AllDevices
    )
    $exe = Find-HdcApplication
    if (-not $exe) { throw 'PATH 中找不到 hdc。' }
    $targets = @(
        if ($AllDevices) { Get-HdcTarget }
        elseif ($Serial) { $Serial }
        elseif ($script:HdcDevice) { $script:HdcDevice }
        else { $null }
    )
    if ($AllDevices -and -not $targets) { throw '当前没有在线设备。' }
    foreach ($t in $targets) {
        $argv = if ($t) { @('-t', $t) + $ArgumentList } else { $ArgumentList }
        if ($targets.Count -eq 1) {
            & $exe.Source @argv
        } else {
            $output = & $exe.Source @argv 2>&1
            [pscustomobject]@{
                Serial   = $t
                ExitCode = $LASTEXITCODE
                Output   = @($output | ForEach-Object { "$_" })
            }
        }
    }
}

function Get-HdcRemotePath {
    param([AllowEmptyString()][string]$Word, [string]$Serial, [string]$Cwd,
        [switch]$DirectoriesOnly, [switch]$ExecutablesOnly, [string]$HomePath)
    $exe = Find-HdcApplication
    if (-not $exe) { return @() }
    $absolute = $Word.StartsWith('/')
    $slash = $Word.LastIndexOf('/')
    if ($Word.EndsWith('/')) {
        # 'service/el2/' lists service/el2 and keeps the typed prefix.
        $parent = $Word.TrimEnd('/')
        if (-not $parent) { $parent = '/' }
        $prefix = $Word
    } elseif ($slash -ge 0) {
        $parent = if ($slash -eq 0) { '/' } else { $Word.Substring(0, $slash) }
        $prefix = $Word.Substring(0, $slash + 1)
    } else {
        $parent = '.'
        $prefix = ''
    }
    # Relative paths must resolve from the tracked remote directory, not from
    # the device shell's default cwd.
    $lookupParent = $parent
    if ($HomePath -and ($parent -eq '~' -or $parent.StartsWith('~/'))) {
        $lookupParent = $HomePath.TrimEnd('/') + $parent.Substring(1)
    }
    $quoted = "'" + $lookupParent.Replace("'", "'\''") + "'"
    $listing = if ($ExecutablesOnly) {
        'p=' + $quoted + '; find -L "$p" -mindepth 1 -maxdepth 1 -type f -executable -printf ''%f\n'' 2>/dev/null; ' +
        'find -L "$p" -mindepth 1 -maxdepth 1 -type d -printf ''%f/\n'' 2>/dev/null'
    } else { "ls -1apL -- $quoted 2>/dev/null" }
    $remote = if ($Cwd -and -not $absolute) {
        "cd '" + $Cwd.Replace("'", "'\''") + "' 2>/dev/null && " + $listing
    } else {
        $listing
    }
    $argv = @()
    if ($Serial) { $argv += @('-t', $Serial) }
    $argv += @('shell', $remote)
    $keyParent = if ($absolute) { $lookupParent } else { "$Cwd|$lookupParent" }
    $lines = Get-HdcCached -Key "ls:${Serial}:${ExecutablesOnly}:$keyParent" -TtlSeconds 10 -Fetch {
        try { $response = Invoke-HdcCapture $exe.Source $argv -TimeoutSeconds 3 }
        catch { return @() }
        if ($response.ExitCode -ne 0) { return @() }
        $output = $response.Lines
        @($output | ForEach-Object { "$($_)".TrimEnd("`r") } |
            Where-Object { $_ -and -not $_.StartsWith('[Fail]') })
    }
    # $null piped into ForEach-Object still iterates once, which would turn the
    # typed word itself into a bogus candidate.
    if ($null -eq $lines -or @($lines).Count -eq 0) { return @() }
    $leaf = $Word.Substring([Math]::Min($prefix.Length, $Word.Length))
    @($lines | Where-Object {
        (-not $DirectoriesOnly -or $_.EndsWith('/')) -and
        (-not $_.StartsWith('.') -or $leaf.StartsWith('.'))
    } | ForEach-Object { $prefix + $_ })
}

function Get-HdcBundleName {
    param([string]$Serial)
    $exe = Find-HdcApplication
    if (-not $exe) { return @() }
    $argv = @()
    if ($Serial) { $argv += @('-t', $Serial) }
    $argv += @('shell', 'bm', 'dump', '-a')
    Get-HdcCached -Key "bundles:$Serial" -TtlSeconds 60 -Fetch {
        try { $response = Invoke-HdcCapture $exe.Source $argv -TimeoutSeconds 3 }
        catch { return @() }
        if ($response.ExitCode -ne 0) { return @() }
        $output = $response.Lines
        $names = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($line in $output) {
            foreach ($m in [regex]::Matches("$line", '\b[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*){2,}\b')) {
                [void]$names.Add($m.Value)
            }
        }
        @($names | Sort-Object)
    }
}

function New-HdcCompletion {
    param([string]$Text, [string]$Tip = $Text)
    $quoted = if ($Text -match '\s') { "'$Text'" } else { $Text }
    [System.Management.Automation.CompletionResult]::new($quoted, $Text, 'Text', $Tip)
}

$script:HdcCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $tokens = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })
    $prev = if ($wordToComplete -and $tokens.Count -ge 2) { $tokens[-2] } else { $tokens[-1] }
    if ($prev -eq '-t') {
        return Get-HdcTarget | Where-Object { $_.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { New-HdcCompletion $_ }
    }

    $serial = $null
    for ($i = 1; $i -lt $tokens.Count - 1; $i++) {
        if ($tokens[$i] -eq '-t') { $serial = $tokens[$i + 1] }
    }
    if (-not $serial) { $serial = $script:HdcDevice }

    $positional = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -eq '-t') { $i++; continue }
        $positional.Add($tokens[$i])
    }
    if ($wordToComplete -and $positional.Count -and $positional[-1] -eq $wordToComplete) {
        $positional.RemoveAt($positional.Count - 1)
    }
    $match = {
        param($items)
        @($items | Where-Object { $_.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { New-HdcCompletion $_ })
    }

    if ($positional.Count -eq 0) { return & $match $script:HdcSubcommands }
    $cmd = $positional[0]
    switch ($cmd) {
        'list' { if ($positional.Count -eq 1) { return & $match @('targets') } }
        'target' { if ($positional.Count -eq 1) { return & $match @('mount', 'boot') } }
        'install' {
            if ($positional.Count -eq 1) {
                $dir = if ($wordToComplete) { Split-Path $wordToComplete -Parent } else { '' }
                $leaf = if ($wordToComplete) { Split-Path $wordToComplete -Leaf } else { '' }
                $search = if ($dir) { Join-Path $dir "$leaf*" } else { "$wordToComplete*" }
                return Get-ChildItem -Path $search -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.hap', '.hsp', '.app' } |
                    ForEach-Object { New-HdcCompletion $_.FullName }
            }
        }
        'uninstall' {
            if ($positional.Count -eq 1) { return & $match (Get-HdcBundleName $serial) }
        }
        'file' {
            if ($positional.Count -eq 1) { return & $match @('send', 'recv') }
            $sub = $positional[1]
            if ($positional.Count -eq 2) {
                if ($sub -eq 'send') {
                    return Get-ChildItem -Path "$wordToComplete*" -ErrorAction SilentlyContinue |
                        ForEach-Object { New-HdcCompletion $_.FullName }
                }
                if ($sub -eq 'recv') {
                    return & $match (Get-HdcRemotePath $wordToComplete $serial)
                }
            }
            if ($positional.Count -eq 3) {
                if ($sub -eq 'send') { return & $match (Get-HdcRemotePath $wordToComplete $serial) }
                if ($sub -eq 'recv') {
                    return Get-ChildItem -Path "$wordToComplete*" -ErrorAction SilentlyContinue |
                        ForEach-Object { New-HdcCompletion $_.FullName }
                }
            }
        }
        'shell' {
            if ($wordToComplete.StartsWith('/')) {
                return & $match (Get-HdcRemotePath $wordToComplete $serial)
            }
        }
    }
}

Register-ArgumentCompleter -CommandName hdc -ScriptBlock $script:HdcCompleter
