# Path styles use device listings only. Input is decoded as shell text, never
# evaluated: typing a substitution must not execute it on either machine.
function Resolve-HdcShellHighlightPath {
    param([string]$RawWord)
    $value = [Text.StringBuilder]::new()
    $quote = [char]0
    for ($i = 0; $i -lt $RawWord.Length; $i++) {
        $c = $RawWord[$i]
        if ($c -eq $quote) { $quote = [char]0; continue }
        if ($quote -ne "'" -and $c -eq '\' -and $i + 1 -lt $RawWord.Length) {
            $next = $RawWord[$i + 1]
            if ($quote -eq [char]0 -or $next -in @('"', '\', '$', '`')) {
                [void]$value.Append($next); $i++; continue
            }
        }
        if ($quote -eq [char]0 -and $c -in @("'", '"')) { $quote = $c; continue }
        if ($quote -ne "'" -and $c -eq '$') {
            $match = [regex]::Match($RawWord.Substring($i), '^\$(?:\{(?<Name>HOME|PWD|OLDPWD)\}|(?<Name>HOME|PWD|OLDPWD)(?![A-Za-z0-9_]))')
            if (-not $match.Success) { return $null }
            $expanded = switch ($match.Groups['Name'].Value) {
                HOME { Get-HdcShellHomePath }; PWD { $script:HdcShellCwd }; OLDPWD { $script:HdcShellOldCwd }
            }
            if (-not $expanded) { return $null }
            [void]$value.Append($expanded); $i += $match.Length - 1; continue
        }
        if ($quote -ne "'" -and $c -eq '`') { return $null }
        if ($quote -eq [char]0 -and $c -in @('*', '?', '[', '{')) { return $null }
        if ($i -eq 0 -and $c -eq '~' -and ($RawWord.Length -eq 1 -or $RawWord[1] -eq '/')) {
            [void](Get-HdcShellHomePath)
            if (-not $script:HdcShellHome) { return $null }
            [void]$value.Append($(if ($RawWord.Length -eq 1) { $script:HdcShellHome } else { $script:HdcShellHome.TrimEnd('/') })); continue
        }
        [void]$value.Append($c)
    }
    $value.ToString()
}

function Get-HdcShellPathHighlight {
    param([AllowEmptyString()][string]$Line)
    if (-not $script:HdcShellSerial -or -not $script:HdcShellCwd) { return }
    $pattern = @'
(?<Comment>\#[^\n]*)|(?<Operator>\d*(?:>>?|<<?)|\|\||&&|[|;&()\n])|(?<Word>(?:'[^']*(?:'|$)|"(?:\\.|[^"\\])*(?:"|$)|\\.|[^\s'"\\|&;<>()])+)
'@
    foreach ($token in [regex]::Matches($Line, $pattern)) {
        if (-not $token.Groups['Word'].Success) { continue }
        $context = Get-HdcShellCompletionContext $Line ($token.Index + $token.Length)
        if ($context.IsCommand -or $context.InComment -or $token.Value.StartsWith('-')) { continue }
        $path = Resolve-HdcShellHighlightPath $token.Value
        if (-not $path) { continue }
        $probe = $path.TrimEnd('/')
        $exists = $path -match '^/+$'
        if (-not $exists) {
            if (-not $script:HdcShellHighlightListings) { $script:HdcShellHighlightListings = @{} }
            $parent = $probe.Substring(0, $probe.LastIndexOf('/') + 1)
            $key = "$($script:HdcShellSerial)|$($script:HdcShellCwd)|$parent"
            if (-not $script:HdcShellHighlightListings.ContainsKey($key)) {
                $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($candidate in (Get-HdcRemotePath -Word ($parent + '.') -Serial $script:HdcShellSerial `
                    -Cwd $script:HdcShellCwd -HomePath '')) {
                    [void]$paths.Add($candidate.TrimEnd('/'))
                }
                $script:HdcShellHighlightListings[$key] = $paths
            }
            $exists = $script:HdcShellHighlightListings[$key].Contains($probe)
            if (-not $exists -and $token.Index + $token.Length -eq $Line.Length) {
                foreach ($candidate in $script:HdcShellHighlightListings[$key]) {
                    if ($candidate.StartsWith($probe, [StringComparison]::Ordinal)) { $exists = $true; break }
                }
            }
        }
        if ($exists) {
            # zsh overlays quoted-argument styles on top of path styles: a
            # quoted segment stays yellow, while unquoted path text underlines.
            $quote = [char]0
            $start = -1
            for ($i = 0; $i -lt $token.Length; $i++) {
                $c = $token.Value[$i]
                if ($quote -ne [char]0) {
                    if ($c -eq $quote) { $quote = [char]0 }
                    elseif ($quote -eq '"' -and $c -eq '\') { $i++ }
                    continue
                }
                if ($c -in @("'", '"')) {
                    if ($start -ge 0) { $token.Index + $start; $i - $start; $start = -1 }
                    $quote = $c; continue
                }
                if ($start -lt 0) { $start = $i }
                if ($c -eq '\') { $i++ }
            }
            if ($start -ge 0) { $token.Index + $start; $token.Length - $start }
        }
    }
}

function Initialize-HdcShellHighlighting {
    if (-not ('TerminalSuggestions.HdcShellPathConsole' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'HdcShellPathConsole.cs') -ErrorAction Stop
    }
    $script:HdcShellPathConsole = [TerminalSuggestions.HdcShellPathConsole]::Install(
        [Microsoft.PowerShell.PSConsoleReadLine],
        [Func[string, int[]]]{ param($line); [int[]]@(Get-HdcShellPathHighlight $line) })
}

function Reset-HdcShellHighlighting {
    # A completed command can create/remove files. Refresh device listings at
    # the next prompt rather than carrying their TTL across commands.
    foreach ($key in @($script:HdcCache.Keys)) {
        if ($key.StartsWith('ls:')) { $script:HdcCache.Remove($key) }
    }
    $script:HdcShellHighlightListings = @{}
    if ($script:HdcShellPathConsole) { $script:HdcShellPathConsole.Reset() }
}
