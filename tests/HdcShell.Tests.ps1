# Standalone regression checks: pwsh -NoProfile -File tests/HdcShell.Tests.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../TerminalSuggestions/TerminalSuggestions.psd1') -Force
& (Get-Module TerminalSuggestions) {
    $script:Checks = 0
    function Assert-Equal($Actual, $Expected, [string]$Because) {
        if (($Actual | ConvertTo-Json -Depth 6 -Compress) -cne ($Expected | ConvertTo-Json -Depth 6 -Compress)) {
            throw "$Because : expected [$Expected], got [$Actual]"
        }
        $script:Checks++
    }
    function Assert-True($Actual, [string]$Because) {
        if (-not $Actual) { throw $Because }
        $script:Checks++
    }
    function Complete([string]$Line, [int]$Cursor = $Line.Length) {
        Get-HdcShellCompletion $Line $Cursor
    }
    $originalRemotePath = (Get-Command Get-HdcRemotePath).ScriptBlock
    function Get-HdcRemotePath {
        param($Word, $Serial, $Cwd, [switch]$DirectoriesOnly, [switch]$ExecutablesOnly, $HomePath)
        $script:LastLookup = @{ Word = $Word; Cwd = $Cwd; Directories = [bool]$DirectoriesOnly; Executables = [bool]$ExecutablesOnly }
        $files = @('/data/local/', '/data/log/', '/data/lost+found/', '/data/a b/', "/data/a'b/", '/data/file.txt', './ls', './notes.txt')
        if ($DirectoriesOnly) { $files = @($files | Where-Object { $_.EndsWith('/') }) }
        if ($ExecutablesOnly) { $files = @('./ls') }
        $files
    }
    $script:HdcShellBins = @('ls', 'lsof', 'cat', 'echo', 'CaseTool', 'casetool')
    $script:HdcShellBuiltins = @('cd', 'exit', 'echo')
    $script:HdcShellSerial = 'test-device'
    $script:HdcShellCwd = '/remote'
    $script:HdcShellHome = '/root'

    Assert-Equal @((Complete 'l').CompletionMatches.ListItemText) @('ls', 'lsof') 'Complete only device commands'
    Assert-Equal @((Complete 'git').CompletionMatches).Count 0 'Host Git is not a remote candidate'
    Assert-Equal @((Complete 'case').CompletionMatches).Count 2 'Case-distinct device commands survive deduplication'
    foreach ($line in @('echo x | l', 'echo x || l', 'echo x && l', 'echo x; l', 'if l', 'A=1 l', 'echo "a|b"; l')) {
        Assert-Equal @((Complete $line).CompletionMatches.ListItemText) @('ls', 'lsof') "Command position: $line"
    }
    Assert-Equal @((Complete 'echo hi # l').CompletionMatches).Count 0 'Comments have no completion'
    $c = Complete 'cd /data/lo'
    Assert-Equal @($c.CompletionMatches.ListItemText) @('/data/local/', '/data/log/', '/data/lost+found/') 'cd lists directories'
    Assert-True $script:LastLookup.Directories 'cd asks the device for directories'
    Assert-Equal $script:LastLookup.Cwd '/remote' 'Relative lookup uses tracked remote cwd'
    Assert-True (-not @((Complete 'cat /data/').CompletionMatches.ListItemText).Contains('git')) 'Path completion never consults the host'
    Assert-Equal (Complete 'cd "/data/a b').CompletionMatches[0].CompletionText '"/data/a b/' 'A quoted directory retains the open quote like zsh'
    Assert-Equal (Complete 'cd /data/a\ b').CompletionMatches[0].CompletionText '/data/a\ b/' 'Escaped spaces retain sh backslash quoting'
    Assert-Equal (Complete 'cd /data/a').CompletionMatches[1].CompletionText "/data/a\'b/" 'Single quotes are escaped for sh'
    $context = Get-HdcShellCompletionContext 'cd ~/a' 6
    Assert-Equal (ConvertTo-HdcShellCompletionText '~/a b/' $context) '~/a\ b/' 'Home expansion and zsh quoting are retained'
    Assert-Equal (Complete 'cat /data/fi').CompletionMatches[0].CompletionText '/data/file.txt ' 'A file completion supplies exactly one separator'
    Assert-Equal (Get-HdcShellWordPoint 'echo alpha beta' 0 -Forward) 5 'zsh forward-word includes its separator'
    Assert-Equal (Get-HdcShellWordPoint 'echo /data/local/tmp' 8 -Forward) 11 'zsh word acceptance includes the next slash'
    Assert-Equal (Get-HdcShellWordPoint 'echo alpha beta' 15) 11 'zsh backward-word stops at word start'
    $line = 'cd /data/locl && echo keep'
    $c = Complete $line 12
    Assert-Equal $c.ReplacementIndex 3 'Mid-word completion starts at the word boundary'
    Assert-Equal $c.ReplacementLength 10 'Mid-word completion replaces only the same word'
    Assert-Equal ($line.Remove($c.ReplacementIndex, $c.ReplacementLength).Insert($c.ReplacementIndex, $c.CompletionMatches[0].CompletionText)) 'cd /data/local/ && echo keep' 'Completion preserves later commands'
    Assert-Equal @((Complete 'cd /data/loX' 11).CompletionMatches).Count 0 'An unmatched suffix prevents completion like zsh'
    [void](Complete 'echo hi > /data/l')
    Assert-True (-not $script:LastLookup.Directories) 'Redirection targets can be regular files'
    [void](Complete './l')
    Assert-True $script:LastLookup.Executables 'A command path requests executable files'
    $options = @((Complete 'ls -').CompletionMatches.ListItemText)
    foreach ($flag in @('-a', '-A', '-r', '-R')) { Assert-True ($options -ccontains $flag) "Preserve case-sensitive option $flag" }
    Assert-Equal @((Complete 'bm d').CompletionMatches.ListItemText) @('disable', 'dump') 'OpenHarmony subcommands'
    Assert-True (@((Complete 'bm dump -').CompletionMatches.ListItemText) -contains '-n') 'OpenHarmony subcommand options'

    # A full command grid can be hundreds of rows tall. Only rendering is
    # windowed: global candidate indices and column-major ordering survive.
    $view = Get-HdcShellMenuViewport -Count 13 -Columns 3 -Rows 5 -AvailableRows 3
    Assert-Equal @($view.Indices) @(0, 1, 2, 5, 6, 7, 10, 11, 12) 'Viewport preserves full-grid columns'
    $view = Get-HdcShellMenuViewport -Count 13 -Columns 3 -Rows 5 -AvailableRows 3 -FirstRow 2 -Selected 12
    Assert-Equal @($view.Indices) @(2, 3, 4, 7, 8, 9, 12) 'Partial last columns keep correct cell positions'
    Assert-Equal $view.SelectedIndex 6 'Highlight maps global index to the displayed cell'
    $view = Get-HdcShellMenuViewport -Count 500 -Columns 6 -Rows 84 -AvailableRows 12 -Selected 499
    Assert-True ($view.Indices -contains 499) 'Reverse selection reaches the last candidate beyond the viewport'
    Assert-Equal $view.Rows 12 'Menu height is bounded by available terminal rows'
    $view = Get-HdcShellMenuViewport -Count 500 -Columns 6 -Rows 84 -AvailableRows 0
    Assert-Equal $view.Rows 0 'An input occupying the terminal leaves no drawable menu rows'
    Assert-Equal $view.Indices.Count 0 'A zero-height menu does not draw or discard candidates'
    $first = 0
    foreach ($selected in 0..499) {
        $view = Get-HdcShellMenuViewport -Count 500 -Columns 6 -Rows 84 -AvailableRows 7 -FirstRow $first -Selected $selected
        if ($view.Indices -notcontains $selected -or $view.FirstRow -lt 0 -or $view.FirstRow + $view.Rows -gt 84) {
            throw "Viewport lost candidate $selected or exceeded terminal bounds"
        }
        $first = $view.FirstRow
    }
    Assert-True $true 'All 500 candidates stay reachable while the viewport scrolls'

    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/local') @(3, 11) 'An existing device path is emphasized before Enter'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/missing') @() 'A missing device path is not emphasized'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/Local') @() 'Path existence is case sensitive'
    Assert-Equal @(Get-HdcShellPathHighlight 'cat /data/file.txt /data/local') @(4, 14, 19, 11) 'Each existing path argument gets its own span'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd "/data/a b"') @() 'Quoted path styles override underline like zsh'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/"a b"') @(3, 6) 'Mixed quotes retain emphasis on the unquoted path segment'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/loc') @() 'A path prefix is not emphasized; only complete paths are'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/loc ') @() 'A trailing space ends path-prefix emphasis'
    Assert-Equal @(Get-HdcShellPathHighlight 'cd /data/a\ b') @(3, 10) 'Escaped spaces are decoded for device lookup'
    Assert-Equal @(Get-HdcShellPathHighlight 'echo hi # /data/local') @() 'Comments do not trigger path highlighting'
    Assert-Equal @(Get-HdcShellPathHighlight 'cat </data/file.txt') @(5, 14) 'Redirection targets use remote path emphasis'
    Assert-Equal (Resolve-HdcShellHighlightPath '"$HOME/a b"') '/root/a b' 'Quoted HOME expands from the device'
    Assert-Equal (Resolve-HdcShellHighlightPath '~/a') '/root/a' 'Tilde expands from the device home'
    Assert-Equal (Resolve-HdcShellHighlightPath "'~/a'") '~/a' 'A quoted tilde stays literal'
    Assert-Equal (Resolve-HdcShellHighlightPath '\$HOME') '$HOME' 'An escaped dollar stays literal'
    Assert-Equal @(Get-HdcShellCommandHighlight 'l') @() 'A one-character command prefix is not highlighted'
    Assert-Equal @(Get-HdcShellCommandHighlight 'ls') @(0, 2) 'An exact device command is highlighted'
    Assert-Equal @(Get-HdcShellCommandHighlight 'lsof') @(0, 4) 'A longer exact device command is highlighted'
    Assert-Equal @(Get-HdcShellCommandHighlight 'lso') @() 'A command prefix is not highlighted'
    Assert-Equal @(Get-HdcShellCommandHighlight 'cd /') @(0, 2) 'An exact shell builtin is highlighted'
    Assert-Equal @(Get-HdcShellCommandHighlight 'LS') @() 'Command matching is case sensitive'
    Assert-Equal @(Get-HdcShellCommandHighlight 'nope') @() 'An unknown command is not highlighted'
    Assert-Equal (Resolve-HdcShellHighlightPath '$(touch /tmp/must-not-execute)') $null 'Highlighting never evaluates command substitution'
    Assert-Equal (Resolve-HdcShellHighlightPath '$UNKNOWN/path') $null 'Unknown variables are not expanded on the host'

    # Directory listings share the 10 s completion cache across prompts; only
    # the per-input frame cache and console styles reset for the next line.
    $savedCache = $script:HdcCache
    $savedListings = $script:HdcShellHighlightListings
    $script:HdcCache = @{ 'ls:test' = @{ Time = Get-Date; Data = @('entry') } }
    $script:HdcShellHighlightListings = @{ frame = $true }
    Reset-HdcShellHighlighting
    Assert-True $script:HdcCache.ContainsKey('ls:test') 'Directory listings keep their TTL across a prompt'
    Assert-Equal $script:HdcShellHighlightListings.Count 0 'The per-input frame cache resets'
    $script:HdcCache = $savedCache
    $script:HdcShellHighlightListings = $savedListings

    # Check real editor state restoration, including pre-existing custom keys.
    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -BriefDescription TestCustom -ScriptBlock { 'original binding' }
    $saved = Save-HdcShellEditor
    Enable-HdcShellEditor
    Assert-True (-not [object]::ReferenceEquals($saved.Console, $saved.ConsoleField.GetValue($saved.Instance))) 'The device editor adds its path renderer'
    $styled = [TerminalSuggestions.HdcShellPathConsole]::Emphasize("`e[32mcd `e[0m/data`e[39m next", 'cd /data next', 0, 0, @(3, 5))
    Assert-True ($styled.Contains("`e[38;2;0;255;255m`e[4m/data`e[39m`e[24m next")) 'Path color and underline end before the next argument'
    $styled = [TerminalSuggestions.HdcShellPathConsole]::Emphasize("`e[33m'a`e[0m b'`e[90m prediction", "'a b'", 0, 0, @(0, 5))
    Assert-True ($styled.Contains("`e[0m`e[38;2;0;255;255m`e[4m b'")) 'A native color reset inside a path does not lose its color or underline'
    Assert-True ($styled.EndsWith("`e[90m`e[24m prediction")) 'Gray prediction text never inherits path emphasis'
    $styled = [TerminalSuggestions.HdcShellPathConsole]::Emphasize("`e[38;2;0;128;255m/data next", '/data next', 0, 0, @(0, 5))
    Assert-True ($styled.Contains("`e[38;2;0;255;255m`e[4m/data`e[38;2;0;128;255m`e[24m next")) 'The following text recovers its original RGB color including zero components'
    $styled = [TerminalSuggestions.HdcShellPathConsole]::Emphasize("`e[39mls`e[0m -l", 'ls -l', 0, 0, @(), @(0, 2))
    Assert-True ($styled.Contains("`e[32mls")) 'An exact device command is painted green'
    Add-Type -TypeDefinition @'
public static class HdcMenuCoordinateProbe {
    public static void ResizeDuringFrame() {
        throw new System.ArgumentOutOfRangeException("top", "terminal resized during rendering");
    }
}
'@
    $errorCount = $Error.Count
    $drawn = [TerminalSuggestions.HdcShellMenuRenderer]::TryInvoke(
        [HdcMenuCoordinateProbe].GetMethod('ResizeDuringFrame'), $null, @())
    Assert-Equal $drawn $false 'A resize invalidates the frame instead of throwing from the key handler'
    Assert-Equal $Error.Count $errorCount 'A recoverable frame resize does not add a PowerShell error'
    $options = Get-PSReadLineOption
    Assert-Equal @($options.PromptText) @('') 'PowerShell parse errors cannot overwrite the device status arrow'
    Assert-Equal $options.EditMode.ToString() 'Emacs' 'Device editing uses OMZ-style Emacs keys'
    Assert-Equal $options.HistorySaveStyle.ToString() 'SaveNothing' 'Device history cannot merge with host history'
    Assert-Equal $options.PredictionSource.ToString() 'History' 'Device predictions exclude host plugins'
    Assert-True $options.HistorySearchCaseSensitive 'History suggestions are case sensitive'
    Assert-Equal (Get-PSReadLineKeyHandler -Chord 'Ctrl+f').Function 'HdcForwardChar' 'Ctrl+F moves within an edited line'
    Assert-Equal (Get-PSReadLineKeyHandler -Chord 'Ctrl+c').Function 'HdcCancelMenu' 'Ctrl+C cancels without exiting'
    Assert-Equal (Get-PSReadLineKeyHandler -Chord 'Ctrl+r').Function 'ReverseSearchHistory' 'Ctrl+R searches device history'
    Assert-Equal $options.InlinePredictionColor "`e[90m" 'Suggestions use zsh fg=8'
    Assert-Equal ($options.AddToHistoryHandler.Invoke(' echo secret')) 'SkipAdding' 'Leading spaces opt out of history'
    Restore-HdcShellEditor $saved
    Assert-Equal @((Get-PSReadLineOption).PromptText) @($saved.Options.PromptText) 'The host prompt error marker is restored'
    Assert-True ([object]::ReferenceEquals($saved.Console, $saved.ConsoleField.GetValue($saved.Instance))) 'The original host renderer is restored'
    Assert-Equal (Get-PSReadLineOption).EditMode.ToString() 'Windows' 'Host editing mode is restored'
    Assert-Equal (Get-PSReadLineKeyHandler -Chord 'Ctrl+f').Function 'TestCustom' 'Custom host key is restored'
    foreach ($key in $saved.Colors.Keys) {
        $property = if ($key -eq 'Default') { 'DefaultTokenColor' } else { $key + 'Color' }
        Assert-Equal (Get-PSReadLineOption).$property $saved.Colors[$key] "Restore $property"
    }

    # hdc keeps the RPC channel open as the remote shell's stdin; the remote
    # script must point stdin at /dev/null so reads terminate instead of
    # blocking the whole session.
    $remote = New-HdcShellRemoteScript -Command 'cat' -Marker '@@M@@' -Cwd '/data' -OldCwd '/root' -LastExitCode 7
    Assert-True ($remote.StartsWith("exec </dev/null`n")) 'Device commands receive EOF on stdin instead of blocking'
    Assert-True ($remote.Contains("`ncat`n")) 'User command text stays unmodified'
    Assert-True ($remote.Contains("OLDPWD='/root'")) 'OLDPWD is still restored before the command'
    Assert-True ($remote.EndsWith("echo '@@M@@'`$?; pwd")) 'Status marker still follows the command'

    # File-channel cat keeps partial data and reports a timeout.
    if (-not $IsWindows) {
        $fakeHdc = Join-Path ([IO.Path]::GetTempPath()) ('slow-hdc-' + [guid]::NewGuid().ToString('N'))
        $received = $null
        try {
            [IO.File]::WriteAllText($fakeHdc,
                "#!/bin/sh`nfor a; do last=`$a; done`nprintf 'PARTIAL' > `"`$last`"`nsleep 30`n")
            & chmod +x $fakeHdc
            $received = Receive-HdcFileToTemp -Application $fakeHdc -Serial test -RemotePath file -TimeoutSeconds 1
            Assert-True ($null -ne $received -and $received.TimedOut) 'A slow file-channel read times out'
            Assert-Equal ([IO.File]::ReadAllText($received.Path)) 'PARTIAL' 'Partial file content survives a timeout'
        } finally {
            if ($received -and $received.Path) {
                Remove-Item -LiteralPath $received.Path -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $fakeHdc -Force -ErrorAction SilentlyContinue
        }
    }

    # ls flag handling is case sensitive and keeps unsupported layouts raw.
    $plan = Get-HdcShellLsPlan 'ls -S /data'
    Assert-Equal $plan.Mode 'columns' 'Uppercase -S is a sort flag, not lowercase -s'
    Assert-Equal $plan.ExecLine 'ls -F -S /data -1' 'Sort listings are still locally reflowed'
    Assert-Equal (Get-HdcShellLsPlan 'ls -s /data') $null 'Lowercase -s keeps the device block layout'
    Assert-Equal (Get-HdcShellLsPlan 'ls -m /data') $null 'Comma output stays on the device'
    Assert-Equal (Get-HdcShellLsPlan 'ls -h /data') $null 'Device total line is not reflowed as a filename'
    Assert-Equal (Get-HdcShellLsPlan 'ls -lh /data').Mode 'long' 'Long human-readable output stays long'
    Assert-Equal (Get-HdcShellLsPlan 'ls -1 /data').Mode 'single' 'Single-column output'
    Assert-Equal (Get-HdcShellLsPlan 'ls -p /data').MarkerMode 'dir' 'Explicit -p keeps only directory markers'
    Assert-Equal (Get-HdcShellLsPlan 'ls -F /data').MarkerMode 'all' 'Explicit -F keeps all type markers'
    Assert-Equal (Get-HdcShellLsPlan 'LS /data') $null 'Only lowercase ls is locally reformatted'
    Assert-Equal (Get-HdcShellLsPlan 'Ls /data') $null 'Device commands are case sensitive'
    Assert-Equal (Get-HdcShellLsPlan 'ls /data | cat') $null 'Pipelines bypass local ls rendering'
    Assert-Equal (Get-HdcShellLsPlan 'ls /data/*.txt') $null 'Globs bypass local ls rendering'
    Assert-Equal (Get-HdcShellMarkerSuffix '/' 'dir') '/' '-p shows the directory marker'
    Assert-Equal (Get-HdcShellMarkerSuffix '*' 'dir') '' '-p hides executable markers'
    Assert-Equal (Get-HdcShellMarkerSuffix '*' 'all') '*' '-F shows executable markers'
    Assert-Equal (Get-HdcShellMarkerSuffix '/' 'none') '' 'Unrequested markers stay hidden'

    # Simple cat is transported as device-side base64; pipelines and
    # redirections must stay untouched on the device.
    Assert-True (Test-HdcShellSimpleCat 'cat /system/bin/init') 'Plain cat uses binary-safe transport'
    Assert-True (Test-HdcShellSimpleCat 'cat -n "/a b"') 'Quoted paths and options are allowed'
    Assert-True (Test-HdcShellSimpleCat 'cat') 'Bare cat is allowed'
    Assert-True (-not (Test-HdcShellSimpleCat 'cat /x | wc -c')) 'Pipelines are not rewritten'
    Assert-True (-not (Test-HdcShellSimpleCat 'cat /x > /tmp/y')) 'Redirections are not rewritten'
    Assert-True (-not (Test-HdcShellSimpleCat 'cat /x && echo done')) 'Compound commands are not rewritten'
    Assert-True (-not (Test-HdcShellSimpleCat 'cat $(echo /x)')) 'Command substitution is not rewritten'
    Assert-True (-not (Test-HdcShellSimpleCat 'CAT /x')) 'Command names stay case sensitive'

    # Exercise the actual remote path builder with mocked device output.
    Set-Item Function:Get-HdcRemotePath -Value $originalRemotePath
    function Invoke-HdcCapture {
        param($Application, $Arguments, $TimeoutSeconds)
        $script:LastRemote = $Arguments[-1]
        [pscustomobject]@{ ExitCode = 0; Lines = @('./', '../', '.hidden/', 'folder/', 'Folder/', 'error.log', 'failed.txt', 'a b', "a'b") }
    }
    function Find-HdcApplication { [pscustomobject]@{ Source = '/fake/hdc' } }
    $script:HdcCache = @{}
    $files = @(Get-HdcRemotePath -Word '/data/' -Serial test -Cwd /)
    Assert-True ($files -contains '/data/error.log') 'A valid filename containing error is retained'
    Assert-True ($files -contains '/data/failed.txt') 'A valid filename containing failed is retained'
    Assert-True ($files -contains '/data/a b') 'Whitespace in remote filenames is retained'
    Assert-True ($files -notcontains '/data/.hidden/') 'Dotfiles stay hidden without a dot prefix'
    $files = @(Get-HdcRemotePath -Word '/data/.' -Serial test -Cwd / -DirectoriesOnly)
    Assert-True ($files -contains '/data/./') 'Dot-directory completion'
    Assert-True ($files -contains '/data/../') 'Parent-directory completion'
    Assert-True ($files -contains '/data/.hidden/') 'A dot prefix enables hidden directories'
    Assert-True ($files -notcontains '/data/a b') 'cd filters out regular files'
    Assert-True (($files -ccontains '/data/folder/') -and ($files -ccontains '/data/Folder/')) 'Case-distinct paths survive'
    [void](Get-HdcRemotePath -Word 'dir/a' -Serial test -Cwd "/data/a'b")
    Assert-True ($script:LastRemote.Contains("cd '/data/a'\''b' 2>/dev/null &&")) 'Remote cwd uses sh quoting and failure-safe lookup'
    [void](Get-HdcRemotePath -Word '~/a' -Serial test -Cwd / -HomePath /root)
    Assert-True ($script:LastRemote.Contains("'/root'")) 'Home paths resolve on the device'
    [void](Get-HdcRemotePath -Word './a' -Serial test -Cwd / -ExecutablesOnly)
    Assert-True ($script:LastRemote.Contains('-type f -executable')) 'Command-path completion filters executable files'

    # Exercise all entry forms without starting an interactive shell.
    function Find-HdcApplication { [pscustomobject]@{ Source = '/fake/hdc' } }
    function Enter-HdcShell { param($Serial, [switch]$Raw); $script:Entered = "$Serial|$Raw" }
    $script:HdcDevice = 'current'
    hdc shell
    Assert-Equal $script:Entered 'current|False' 'Default device enters enhanced shell'
    hdc -t explicit shell
    Assert-Equal $script:Entered 'explicit|False' 'Explicit device also enters enhanced shell'
    hdc -t explicit shell --raw
    Assert-Equal $script:Entered 'explicit|True' 'Explicit raw mode stays available'
    "PASS: $script:Checks checks"
}
