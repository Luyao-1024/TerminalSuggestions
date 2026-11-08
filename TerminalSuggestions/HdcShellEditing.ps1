# POSIX shell words, rather than PowerShell tokens. Never evaluate input while
# completing: quotes, escaped spaces and shell operators only describe spans.
function ConvertFrom-HdcShellWord {
    param([AllowEmptyString()][string]$Text)
    $value = [Text.StringBuilder]::new()
    $quote = [char]0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq $quote) { $quote = [char]0; continue }
        if ($quote -ne "'" -and $c -eq '\' -and $i + 1 -lt $Text.Length) {
            $next = $Text[$i + 1]
            if ($quote -eq [char]0 -or $next -in @('"', '\', '$', '`')) {
                [void]$value.Append($next); $i++; continue
            }
        }
        if ($quote -eq [char]0 -and $c -in @("'", '"')) { $quote = $c; continue }
        [void]$value.Append($c)
    }
    $value.ToString()
}

function Get-HdcShellCompletionContext {
    param([string]$Line, [int]$Cursor)
    $Cursor = [Math]::Clamp($Cursor, 0, $Line.Length)
    $pattern = @'
(?<Comment>\#[^\n]*)|(?<Operator>\d*(?:>>?|<<?)|\|\||&&|[|;&()\n])|(?<Word>(?:'[^']*(?:'|$)|"(?:\\.|[^"\\])*(?:"|$)|\\.|[^\s'"\\|&;<>()])+)
'@
    $tokens = @([regex]::Matches($Line, $pattern))
    $current = $null
    $words = [Collections.Generic.List[string]]::new()
    $redirect = $false
    $comment = $false
    foreach ($token in $tokens) {
        if ($token.Index -gt $Cursor) { break }
        if ($token.Groups['Comment'].Success -and $Cursor -le $token.Index + $token.Length) {
            $comment = $true; break
        }
        if ($token.Groups['Word'].Success -and $Cursor -le $token.Index + $token.Length) {
            $current = $token; break
        }
        if ($token.Index + $token.Length -gt $Cursor) { break }
        if ($token.Groups['Operator'].Success) {
            if ($token.Value -match '[<>]') { $redirect = $true }
            else { $words.Clear(); $redirect = $false }
        } elseif ($token.Groups['Word'].Success) {
            if ($redirect) { $redirect = $false; continue }
            $word = ConvertFrom-HdcShellWord $token.Value
            if ($words.Count -eq 0 -and $word -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
            if ($words.Count -eq 0 -and $word -in @('if', 'while', 'until', 'then', 'do', 'else', '!', 'command', 'exec')) { continue }
            $words.Add($word)
        }
    }
    $start = if ($current) { $current.Index } else { $Cursor }
    $length = if ($current) { $current.Length } else { 0 }
    $prefix = ConvertFrom-HdcShellWord $Line.Substring($start, $Cursor - $start)
    $rawSuffix = if ($current) { $current.Value.Substring($Cursor - $start) } else { '' }
    $rawPrefix = $Line.Substring($start, $Cursor - $start)
    if ($rawPrefix.StartsWith('"')) { $rawSuffix = '"' + $rawSuffix }
    elseif ($rawPrefix.StartsWith("'")) { $rawSuffix = "'" + $rawSuffix }
    [pscustomobject]@{
        Start = $start; Length = $length; Prefix = $prefix
        RawPrefix = $rawPrefix; RawWord = if ($current) { $current.Value } else { '' }
        Suffix = ConvertFrom-HdcShellWord $rawSuffix
        HasFollowingSpace = $start + $length -lt $Line.Length -and [char]::IsWhiteSpace($Line[$start + $length])
        Words = $words.ToArray(); Command = if ($words.Count) { $words[0] } else { '' }
        IsCommand = $words.Count -eq 0 -and -not $redirect
        IsRedirect = $redirect; InComment = $comment
    }
}

function ConvertTo-HdcShellCompletionText {
    param([string]$Text, $Context)
    $directory = $Text.EndsWith('/')
    $raw = $Context.RawPrefix
    if ($raw.StartsWith("'")) {
        $result = "'" + $Text.Replace("'", "'\''")
        if (-not $directory -or ($Context.RawWord.Length -gt 1 -and $Context.RawWord.EndsWith("'"))) { $result += "'" }
    } elseif ($raw.StartsWith('"')) {
        $result = '"' + [regex]::Replace($Text, '([\\"$`])', '\$1')
        if (-not $directory -or ($Context.RawWord.Length -gt 1 -and $Context.RawWord.EndsWith('"'))) { $result += '"' }
    } else {
        $result = [regex]::Replace($Text, '([\\\s''"$`&|;()<>\[\]{}*?!#])', '\$1')
    }
    if (-not $directory) { $result += ' ' }
    $result
}

function Get-HdcShellCompletion {
    param([AllowEmptyString()][string]$Line, [int]$Cursor)
    if ($null -eq $Line) { $Line = '' }
    $context = Get-HdcShellCompletionContext $Line $Cursor
    $word = $context.Prefix
    $candidates = @(
        if ($context.InComment) { # No completion inside shell comments.
        } elseif ($word -eq '~') {
            '~/'
        } elseif ($context.IsCommand -and $word -notmatch '/') {
            if ($null -eq $script:HdcShellBins) { $script:HdcShellBins = @(Get-HdcShellBinary $script:HdcShellSerial) }
            @($script:HdcShellBins) + @($script:HdcShellBuiltins)
        } elseif (($context.Command -eq 'bm' -and $context.Words[-1] -eq '-n') -or
                  ($context.Command -eq 'aa' -and $context.Words[-1] -eq '-b')) {
            Get-HdcBundleName $script:HdcShellSerial
        } elseif (-not $context.IsRedirect -and $word.StartsWith('-')) {
            if ($context.Words.Count -gt 1) {
                $script:HdcShellOptions[$context.Command + ' ' + $context.Words[1]]
            }
            $script:HdcShellOptions[$context.Command]
        } elseif (-not $context.IsRedirect -and $context.Words.Count -eq 1 -and
            $script:HdcShellSubcommands.ContainsKey($context.Command)) {
            $script:HdcShellSubcommands[$context.Command]
        } else {
            if ($word.StartsWith('~/')) { [void](Get-HdcShellHomePath) }
            $directories = $context.Command -in @('cd', 'rmdir') -and -not $context.IsRedirect
            Get-HdcRemotePath -Word $word -Serial $script:HdcShellSerial -Cwd $script:HdcShellCwd `
                -DirectoriesOnly:$directories -ExecutablesOnly:$context.IsCommand -HomePath $script:HdcShellHome
        }
    )
    $results = [Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
    foreach ($candidate in ($candidates | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)) {
        # Match this machine's case-insensitive OMZ prefix behavior while
        # preserving the case of device filenames on insertion.
        if (-not $candidate.StartsWith($word, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $suffixTarget = if ($candidate.EndsWith('/') -and -not $context.Suffix.EndsWith('/')) { $candidate.TrimEnd('/') } else { $candidate }
        if ($context.Suffix -and -not $suffixTarget.EndsWith($context.Suffix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $text = ConvertTo-HdcShellCompletionText $candidate $context
        # ProviderContainer appends the HOST directory separator (backslash on
        # Windows). Device paths already carry '/', so keep them shell text.
        $results.Add([System.Management.Automation.CompletionResult]::new($text, $candidate, 'ParameterValue', $candidate))
    }
    [System.Management.Automation.CommandCompletion]::new($results, -1, $context.Start, $context.Length)
}

# Save values rather than PSReadLine's mutable option/handler objects.
function Copy-HdcShellKeyTable {
    param([Collections.IDictionary]$Table)
    $copy = [Activator]::CreateInstance($Table.GetType())
    foreach ($entry in $Table.GetEnumerator()) {
        $value = if ($entry.Value -is [Collections.IDictionary]) { Copy-HdcShellKeyTable $entry.Value } else { $entry.Value }
        $copy.Add($entry.Key, $value)
    }
    return ,$copy
}

function Save-HdcShellEditor {
    $options = Get-PSReadLineOption
    $saved = @{ Options = @{}; Colors = @{} }
    foreach ($name in @('EditMode', 'PredictionSource', 'PredictionViewStyle', 'HistoryNoDuplicates',
        'HistorySearchCaseSensitive', 'HistorySearchCursorMovesToEnd', 'HistorySaveStyle',
        'WordDelimiters', 'AddToHistoryHandler', 'PromptText')) {
        $saved.Options[$name] = $options.$name
    }
    foreach ($property in $options.PSObject.Properties) {
        if ($property.Name.EndsWith('Color')) {
            $name = $property.Name.Substring(0, $property.Name.Length - 5)
            if ($name -eq 'DefaultToken') { $name = 'Default' }
            $saved.Colors[$name] = $property.Value
        }
    }
    # Get-PSReadLineKeyHandler exposes descriptions, but no script callbacks.
    # Preserve the two dispatch tables (PSReadLine 2.2–2.4) to restore custom
    # callbacks and multi-key chords exactly. Fail before changing the editor
    # if a future PSReadLine changes this private compatibility boundary.
    $type = [Microsoft.PowerShell.PSConsoleReadLine]
    $instanceField = $type.GetField('_singleton', [Reflection.BindingFlags]'Static,NonPublic')
    if (-not $instanceField) { throw '此 PSReadLine 版本无法安全保存快捷键。' }
    $saved.Instance = $instanceField.GetValue($null)
    $saved.ConsoleField = $type.GetField('_console', [Reflection.BindingFlags]'Instance,NonPublic')
    $saved.Console = $saved.ConsoleField.GetValue($saved.Instance)
    $saved.Dispatch = @{}
    foreach ($name in @('_dispatchTable', '_chordDispatchTable')) {
        $field = $type.GetField($name, [Reflection.BindingFlags]'Instance,NonPublic')
        if (-not $field) { throw '此 PSReadLine 版本无法安全保存快捷键。' }
        $saved.Dispatch[$name] = @{ Field = $field; Value = (Copy-HdcShellKeyTable $field.GetValue($saved.Instance)) }
    }
    $saved
}

function Restore-HdcShellEditor {
    param([hashtable]$Saved)
    $Saved.ConsoleField.SetValue($Saved.Instance, $Saved.Console)
    $script:HdcShellPathConsole = $null
    $options = $Saved.Options.Clone()
    $promptText = $options.PromptText
    [void]$options.Remove('PromptText')
    Set-PSReadLineOption @options -Colors $Saved.Colors
    # The options object allows null, but the cmdlet parameter rejects it.
    # Preserve a host with no error prompt as well as a custom prompt array.
    (Get-PSReadLineOption).PromptText = $promptText
    foreach ($entry in $Saved.Dispatch.Values) {
        $entry.Field.SetValue($Saved.Instance, $entry.Value)
    }
}

function Enable-HdcShellEditor {
    # Use the native history predictor against the directory-local history.
    # External predictors must not suggest host commands in a device shell.
    $script:HdcShellHasDefaultHistoryFilter = $null -ne [Microsoft.PowerShell.PSConsoleReadLine].GetMethod('GetDefaultAddToHistoryOption')
    Set-PSReadLineOption -EditMode Emacs -PredictionSource History -PredictionViewStyle InlineView `
        -HistoryNoDuplicates -HistorySearchCaseSensitive -HistorySearchCursorMovesToEnd `
        -HistorySaveStyle SaveNothing -PromptText '' `
        -WordDelimiters ';:,.[]{}()/\|!?^&*-=+''"–—―' -AddToHistoryHandler {
            param($line)
            if ($line.StartsWith(' ')) { return 'SkipAdding' }
            # Retain PSReadLine's credential filter while saving remote history
            # ourselves, never into ConsoleHost_history.txt.
            if ($script:HdcShellHasDefaultHistoryFilter) {
                $decision = [Microsoft.PowerShell.PSConsoleReadLine]::GetDefaultAddToHistoryOption($line)
                if ($decision -ne 'MemoryAndFile') { return 'SkipAdding' }
            }
            'MemoryOnly'
        } -Colors @{
            Default = "`e[39m"; Command = "`e[39m"; String = "`e[33m"
            Keyword = "`e[33m"; Parameter = "`e[39m"; Operator = "`e[39m"
            Number = "`e[39m"; Variable = "`e[36m"; Comment = "`e[90m"
            Error = "`e[1;31m"; InlinePrediction = "`e[90m"
        }
    Set-PSReadLineKeyHandler -Chord RightArrow,'Ctrl+f' -Function ForwardChar
    Set-PSReadLineKeyHandler -Chord 'Ctrl+RightArrow','Alt+f','Alt+RightArrow','Escape,f' `
        -BriefDescription HdcForwardWord -ScriptBlock { param($key, $arg); Move-HdcShellWord -Forward -Argument $arg }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+LeftArrow','Alt+b','Escape,b' `
        -BriefDescription HdcBackwardWord -ScriptBlock { param($key, $arg); Move-HdcShellWord -Argument $arg }
    Set-PSReadLineKeyHandler -Chord UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Chord 'Ctrl+r' -Function ReverseSearchHistory
    Set-PSReadLineKeyHandler -Chord 'Ctrl+s' -Function ForwardSearchHistory
    Set-PSReadLineKeyHandler -Chord 'Ctrl+c' -BriefDescription HdcCancelLine -ScriptBlock {
        param($key, $arg)
        $script:HdcShellCancelled = $true
        [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine($key, $arg)
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+Delete' -Function KillWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+Backspace' -Function BackwardKillWord
    Set-PSReadLineKeyHandler -Chord 'End','Ctrl+e' -BriefDescription HdcEndOfLine -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($cursor -eq $line.Length) { [Microsoft.PowerShell.PSConsoleReadLine]::AcceptSuggestion($key, $arg) }
        else { [Microsoft.PowerShell.PSConsoleReadLine]::EndOfLine($key, $arg) }
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -BriefDescription HdcDeleteOrExit -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if (-not $line) {
            $script:HdcShellExit = $true
            [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine()
        } else { [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar($key, $arg) }
    }
    Initialize-HdcShellHighlighting
    Initialize-HdcShellCompletion
}

$script:HdcShellOptions = @{
    ls = @('-a', '-A', '-l', '-h', '-d', '-R', '-r', '-t', '-S', '-1', '-F', '-p', '--color')
    cd = @('-', '-L', '-P'); cat = @('-n', '-b', '-s', '-v', '-e', '-t')
    grep = @('-i', '-n', '-r', '-R', '-v', '-w', '-l', '-c', '-E', '-F', '-e')
    find = @('-name', '-iname', '-type', '-maxdepth', '-mindepth', '-print', '-exec')
    ps = @('-A', '-e', '-f', '-o', '-p', '-T'); rm = @('-r', '-R', '-f', '-i')
    cp = @('-r', '-R', '-a', '-f', '-i', '-p'); mv = @('-f', '-i', '-n')
    mkdir = @('-p', '-m'); du = @('-h', '-s', '-a', '-d'); df = @('-h', '-i')
    hilog = @('-h', '-x', '-b', '-t', '-L', '-D', '-T', '-P', '-e', '-z')
    'bm install' = @('-h', '-p', '-r', '-u', '-s')
    'bm uninstall' = @('-h', '-n', '-k'); 'bm dump' = @('-h', '-a', '-n')
    'aa start' = @('-h', '-b', '-a', '-m', '-d', '-D')
    'aa force-stop' = @('-h', '-b')
}
$script:HdcShellSubcommands = @{
    bm = @('help', 'install', 'uninstall', 'dump', 'clean', 'enable', 'disable')
    aa = @('help', 'start', 'stop-service', 'force-stop', 'test', 'dump')
    param = @('get', 'set', 'wait', 'save')
}
