# zsh-style completion state machine. PSReadLine supplies only the menu renderer;
# its blocking MenuComplete loop has different cursor and typing semantics.
function Get-HdcShellBuffer {
    $line = $null; $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
}

function Get-HdcShellWordPoint {
    param([string]$Line, [int]$Cursor, [switch]$Forward)
    if ($Forward) {
        while ($Cursor -lt $Line.Length -and [char]::IsLetterOrDigit($Line[$Cursor])) { $Cursor++ }
        while ($Cursor -lt $Line.Length -and -not [char]::IsLetterOrDigit($Line[$Cursor])) { $Cursor++ }
    } else {
        while ($Cursor -gt 0 -and -not [char]::IsLetterOrDigit($Line[$Cursor - 1])) { $Cursor-- }
        while ($Cursor -gt 0 -and [char]::IsLetterOrDigit($Line[$Cursor - 1])) { $Cursor-- }
    }
    $Cursor
}

function Move-HdcShellWord {
    param([switch]$Forward, [object]$Argument)
    Clear-HdcShellCompletionMenu
    [void](Remove-HdcShellCompletionSuffix Move)
    $script:HdcShellCompletionState = $null
    $buffer = Get-HdcShellBuffer
    $count = 1
    if (-not [Microsoft.PowerShell.PSConsoleReadLine]::TryGetArgAsInt($Argument, [ref]$count, 1)) { return }
    if ($count -lt 0) { $Forward = -not $Forward; $count = -$count }
    $accepting = $Forward -and $buffer.Cursor -eq $buffer.Line.Length
    if ($accepting) {
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptSuggestion()
        $expanded = Get-HdcShellBuffer
        $buffer.Line = $expanded.Line
    }
    $cursor = $buffer.Cursor
    while ($count-- -gt 0) { $cursor = Get-HdcShellWordPoint $buffer.Line $cursor -Forward:$Forward }
    if ($accepting -and $cursor -lt $buffer.Line.Length) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Delete($cursor, $buffer.Line.Length - $cursor)
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor)
}

function Get-HdcShellMenuViewport {
    param([int]$Count, [int]$Columns, [int]$Rows, [int]$AvailableRows,
        [int]$Selected = -1, [int]$FirstRow = 0)
    $visibleRows = [Math]::Max(0, [Math]::Min($Rows, $AvailableRows))
    if ($visibleRows -eq 0) {
        return [pscustomobject]@{ FirstRow = 0; Rows = 0; Indices = [int[]]@(); SelectedIndex = -1 }
    }
    $first = [Math]::Clamp($FirstRow, 0, $Rows - $visibleRows)
    if ($Selected -ge 0) {
        $row = $Selected % $Rows
        if ($row -lt $first) { $first = $row }
        elseif ($row -ge $first + $visibleRows) { $first = $row - $visibleRows + 1 }
    }
    $indices = [Collections.Generic.List[int]]::new()
    for ($column = 0; $column -lt $Columns; $column++) {
        for ($row = $first; $row -lt $first + $visibleRows; $row++) {
            $index = $column * $Rows + $row
            if ($index -lt $Count) { $indices.Add($index) }
        }
    }
    [pscustomobject]@{
        FirstRow = $first; Rows = $visibleRows; Indices = $indices.ToArray()
        SelectedIndex = $indices.IndexOf($Selected)
    }
}

function Clear-HdcShellCompletionMenu {
    $state = $script:HdcShellCompletionState
    if (-not $state -or -not $state.Menu) {
        # The menu was drawn but its state was already discarded (for example
        # by a fast Enter or a redraw). Leave the drawn flag set so the prompt
        # loop erases the leftovers before drawing the next prompt.
        return
    }
    $menu = $state.Menu
    # Detach before drawing/clearing: even a failed console operation must not
    # leave an invalid menu to throw again during cancellation or shell cleanup.
    $state.Menu = $null
    $api = $script:HdcShellMenuApi
    $console = $api.Console
    $top = $api.Top.GetValue($menu)
    $rows = $api.Rows.GetValue($menu)
    $resized = $state.MenuWidth -ne $console.BufferWidth -or
        $state.MenuHeight -ne $console.WindowHeight -or $state.MenuBufferHeight -ne $console.BufferHeight
    if ($resized -or $top -lt 0 -or $top + $rows -gt $console.BufferHeight) {
        # Coordinates saved before a resize/scroll no longer describe the
        # screen. Re-anchor the existing input without accepting or editing it;
        # the prompt loop still erases any stale menu rows.
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, 0)
        return
    }
    try {
        if (-not [TerminalSuggestions.HdcShellMenuRenderer]::TryInvoke($api.Clear, $menu, @())) {
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, 0)
        }
        # Keep the drawn flag set: the prompt loop performs one idempotent
        # erase-to-end-of-screen before drawing the next prompt, which also
        # covers console implementations whose Clear leaves a row behind.
    } finally { $console.CursorVisible = $true }
}

function Show-HdcShellCompletionMenu {
    param([switch]$Retry)
    $state = $script:HdcShellCompletionState
    $api = $script:HdcShellMenuApi
    $console = $api.Console
    $layout = $api.Create.Invoke($api.Instance, [object[]]@(,$state.Completion.CompletionMatches))
    $state.NavigationMenu = $layout
    $api.Selection.SetValue($layout, [Math]::Max(0, $state.Selected))
    $buffer = Get-HdcShellBuffer
    $point = $api.BufferPoint.Invoke($api.Instance, @($buffer.Line.Length, $null))
    $initialY = $api.InitialY.GetValue($api.Instance)
    $endY = $api.PointY.GetValue($point)
    $inputRows = [Math]::Max(1, $endY - $initialY + 1 + (Get-PSReadLineOption).ExtraPromptLineCount)
    if ($initialY -lt 0 -or $endY -lt 0 -or $endY -ge $console.BufferHeight) {
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, 0)
    }
    # Drawing a selectable block taller than the screen scrolls the saved
    # prompt cursor above row zero. Keep one spare row for console wrapping.
    $available = [Math]::Min($console.WindowHeight, $console.BufferHeight) - $inputRows - 1
    $view = Get-HdcShellMenuViewport -Count $state.Completion.CompletionMatches.Count `
        -Columns $api.Columns.GetValue($layout) -Rows $api.Rows.GetValue($layout) `
        -AvailableRows $available -Selected $state.Selected -FirstRow $state.ViewRow
    $state.ViewRow = $view.FirstRow
    if ($view.Rows -eq 0) { return }
    $matches = [Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    foreach ($index in $view.Indices) { $matches.Add($state.Completion.CompletionMatches[$index]) }
    $menu = $api.Create.Invoke($api.Instance, [object[]]@(,$matches))
    $api.Rows.SetValue($menu, $view.Rows)
    $api.Columns.SetValue($menu, $api.Columns.GetValue($layout))
    $api.ColumnWidth.SetValue($menu, $api.ColumnWidth.GetValue($layout))
    $state.Menu = $menu
    $state.MenuWidth = $console.BufferWidth
    $state.MenuHeight = $console.WindowHeight
    $state.MenuBufferHeight = $console.BufferHeight
    if ($view.SelectedIndex -ge 0) { $api.Selection.SetValue($menu, $view.SelectedIndex) }
    $drawn = $false
    try {
        $drawn = [TerminalSuggestions.HdcShellMenuRenderer]::TryInvoke($api.Draw, $menu, @($null, $true))
        if ($drawn) { $script:HdcShellCompletionDrawn = $true }
        if ($drawn -and $view.SelectedIndex -ge 0) {
            $drawn = [TerminalSuggestions.HdcShellMenuRenderer]::TryInvoke(
                $api.Highlight, $menu, @($view.SelectedIndex, $true, $false, (Get-PSReadLineOption).EmphasisColor))
        }
    } finally { $console.CursorVisible = $true }
    if (-not $drawn) {
        $state.Menu = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, 0)
        # Recompute the viewport after a resize in the middle of a frame. No
        # extra key or confirmation is needed, and the input stays unchanged.
        if (-not $Retry) { Show-HdcShellCompletionMenu -Retry }
    }
}

function Set-HdcShellCompletionSelection {
    param([int]$Index)
    $state = $script:HdcShellCompletionState
    $count = $state.Completion.CompletionMatches.Count
    $state.Selected = (($Index % $count) + $count) % $count
    $state.Active = $true
    Clear-HdcShellCompletionMenu
    $candidate = $state.Completion.CompletionMatches[$state.Selected]
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace($state.Completion.ReplacementIndex, $state.Length, $candidate.CompletionText)
    if ($candidate.ListItemText.EndsWith('/') -and $candidate.CompletionText[-1] -in @("'", '"')) {
        $position = $state.Completion.ReplacementIndex + $candidate.CompletionText.Length - 1
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($position)
    }
    $state.Length = $candidate.CompletionText.Length
    $buffer = Get-HdcShellBuffer
    $state.Expected = $buffer.Line
    $state.Cursor = $buffer.Cursor
    $state.Suffix = if ($candidate.ListItemText.EndsWith('/')) { '/' } elseif ($candidate.CompletionText.EndsWith(' ')) { ' ' } else { '' }
    $state.SuffixIndex = if ($state.Suffix) {
        $state.Completion.ReplacementIndex + $candidate.CompletionText.LastIndexOf($state.Suffix)
    } else { -1 }
    if ($count -gt 1) { Show-HdcShellCompletionMenu }
}

function Test-HdcShellCompletionState {
    if (-not $script:HdcShellCompletionState) { return $false }
    $buffer = Get-HdcShellBuffer
    if ($buffer.Line -cne $script:HdcShellCompletionState.Expected -or $buffer.Cursor -ne $script:HdcShellCompletionState.Cursor) {
        Clear-HdcShellCompletionMenu
        $script:HdcShellCompletionState = $null
        return $false
    }
    $true
}

function Remove-HdcShellCompletionSuffix {
    param([string]$Trigger)
    if (-not (Test-HdcShellCompletionState)) { return $false }
    $state = $script:HdcShellCompletionState
    $consume = $false
    $remove = $false
    if ($state.Suffix -eq '/') {
        $remove = $Trigger -in @(' ', 'Enter', ';', '&', '|', 'Move')
        $consume = $Trigger -eq '/'
    } elseif ($state.Suffix -eq ' ') {
        $remove = $Trigger -in @('Enter', ';', '&', '|', '/', 'Move')
        $consume = $Trigger -eq ' '
    }
    if ($remove) { [Microsoft.PowerShell.PSConsoleReadLine]::Delete($state.SuffixIndex, 1) }
    $consume
}

function Invoke-HdcShellComplete {
    param([switch]$Reverse)
    if ((Test-HdcShellCompletionState) -and $script:HdcShellCompletionState.Completion.CompletionMatches.Count -gt 1) {
        $state = $script:HdcShellCompletionState
        if (-not $state.Listed -and -not $Reverse) {
            Show-HdcShellCompletionMenu
            $state.Listed = $true
            return
        }
        $index = if ($state.Selected -lt 0) {
            if ($Reverse) { $state.Completion.CompletionMatches.Count - 1 } else { 0 }
        } else { $state.Selected + $(if ($Reverse) { -1 } else { 1 }) }
        Set-HdcShellCompletionSelection $index
        return
    }
    Clear-HdcShellCompletionMenu
    $buffer = Get-HdcShellBuffer
    $completion = Get-HdcShellCompletion $buffer.Line $buffer.Cursor
    if ($completion.CompletionMatches.Count -eq 0) { $script:HdcShellCompletionState = $null; return }
    $script:HdcShellCompletionState = @{
        Completion = $completion; Original = $buffer.Line; OriginalCursor = $buffer.Cursor
        Expected = $buffer.Line; Cursor = $buffer.Cursor; Length = $completion.ReplacementLength
        Selected = -1; Active = $false; Listed = $false; Menu = $null; ViewRow = 0
        Suffix = ''; SuffixIndex = -1
    }
    $state = $script:HdcShellCompletionState
    if ($completion.CompletionMatches.Count -eq 1) {
        Set-HdcShellCompletionSelection 0
        $state.Active = $false
        return
    }
    $prefix = $completion.CompletionMatches[0].CompletionText
    foreach ($candidate in $completion.CompletionMatches) {
        $length = [Math]::Min($prefix.Length, $candidate.CompletionText.Length)
        $i = 0
        while ($i -lt $length -and [char]::ToUpperInvariant($prefix[$i]) -eq [char]::ToUpperInvariant($candidate.CompletionText[$i])) { $i++ }
        $prefix = $prefix.Substring(0, $i)
    }
    $typedLength = $buffer.Cursor - $completion.ReplacementIndex
    if ($prefix.Length -gt $typedLength) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($completion.ReplacementIndex, $state.Length, $prefix)
        $state.Length = $prefix.Length
        $buffer = Get-HdcShellBuffer
        $state.Expected = $buffer.Line; $state.Cursor = $buffer.Cursor
        $state.Original = $buffer.Line; $state.OriginalCursor = $buffer.Cursor
    } else { Show-HdcShellCompletionMenu; $state.Listed = $true }
    if ($Reverse) { Set-HdcShellCompletionSelection ($completion.CompletionMatches.Count - 1) }
}

function Initialize-HdcShellCompletion {
    if (-not ('TerminalSuggestions.HdcShellMenuRenderer' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'HdcShellMenuRenderer.cs') -ErrorAction Stop
    }
    $type = [Microsoft.PowerShell.PSConsoleReadLine]
    $flags = [Reflection.BindingFlags]'Instance,NonPublic,Public'
    $instance = $type.GetField('_singleton', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
    $create = $type.GetMethod('CreateCompletionMenu', $flags)
    if (-not $create) { throw '此 PSReadLine 版本不支持设备补全菜单。' }
    $menuType = $create.ReturnType
    $bufferPoint = $type.GetMethod('ConvertOffsetToPoint', $flags)
    $script:HdcShellMenuApi = @{
        Instance = $instance; Create = $create
        Console = $type.GetField('_console', $flags).GetValue($instance)
        InitialY = $type.GetField('_initialY', $flags); BufferPoint = $bufferPoint
        PointY = $bufferPoint.ReturnType.GetField('Y', $flags)
        Top = $menuType.GetField('Top', $flags); Rows = $menuType.GetField('Rows', $flags)
        Columns = $menuType.GetField('Columns', $flags); ColumnWidth = $menuType.GetField('ColumnWidth', $flags)
        Draw = $menuType.GetMethod('DrawMenu', $flags); Clear = $menuType.GetMethod('Clear', $flags)
        Highlight = $menuType.GetMethod('UpdateMenuSelection', $flags)
        Selection = $menuType.GetField('CurrentSelection', $flags)
    }
    $script:HdcShellCompletionState = $null
    $script:HdcShellCompletionDrawn = $false
    Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -BriefDescription HdcForwardChar -ScriptBlock {
        param($key, $arg)
        Clear-HdcShellCompletionMenu
        [void](Remove-HdcShellCompletionSuffix Move)
        $script:HdcShellCompletionState = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+b' -BriefDescription HdcBackwardChar -ScriptBlock {
        param($key, $arg)
        Clear-HdcShellCompletionMenu
        [void](Remove-HdcShellCompletionSuffix Move)
        $script:HdcShellCompletionState = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::BackwardChar($key, $arg)
    }
    Set-PSReadLineKeyHandler -Chord Tab -BriefDescription HdcComplete -ScriptBlock { Invoke-HdcShellComplete }
    Set-PSReadLineKeyHandler -Chord Shift+Tab -BriefDescription HdcReverseComplete -ScriptBlock { Invoke-HdcShellComplete -Reverse }
    Set-PSReadLineKeyHandler -Chord Enter,'Ctrl+m' -BriefDescription HdcAcceptLine -ScriptBlock {
        if ((Test-HdcShellCompletionState) -and $script:HdcShellCompletionState.Active) {
            Clear-HdcShellCompletionMenu
            $script:HdcShellCompletionState.Active = $false
            return
        }
        Clear-HdcShellCompletionMenu
        [void](Remove-HdcShellCompletionSuffix Enter)
        $script:HdcShellCompletionState = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
    $insert = {
        param($key, $arg)
        Clear-HdcShellCompletionMenu
        $consume = Remove-HdcShellCompletionSuffix ([string]$key.KeyChar)
        $script:HdcShellCompletionState = $null
        if (-not $consume) { [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg) }
    }
    foreach ($character in [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./\:;''"$&|()<>[]{}*?!#=-') {
        Set-PSReadLineKeyHandler -Chord ([string]$character) -BriefDescription HdcInsert -ScriptBlock $insert
    }
    Set-PSReadLineKeyHandler -Chord Spacebar -BriefDescription HdcInsert -ScriptBlock $insert
    foreach ($chord in @('UpArrow', 'DownArrow', 'LeftArrow', 'RightArrow')) {
        Set-PSReadLineKeyHandler -Chord $chord -BriefDescription HdcMenuMove -ScriptBlock {
            param($key, $arg)
            if ((Test-HdcShellCompletionState) -and $script:HdcShellCompletionState.Active) {
                $state = $script:HdcShellCompletionState
                $name = switch ($key.Key) { UpArrow { 'MoveUp' }; DownArrow { 'MoveDown' }; LeftArrow { 'MoveLeft' }; RightArrow { 'MoveRight' } }
                $navigation = $state.NavigationMenu
                [void]$navigation.GetType().GetMethod($name).Invoke($navigation, @())
                Set-HdcShellCompletionSelection ($script:HdcShellMenuApi.Selection.GetValue($navigation))
            } else {
                Clear-HdcShellCompletionMenu
                [void](Remove-HdcShellCompletionSuffix Move)
                $script:HdcShellCompletionState = $null
                switch ($key.Key) {
                    UpArrow { [Microsoft.PowerShell.PSConsoleReadLine]::HistorySearchBackward($key, $arg) }
                    DownArrow { [Microsoft.PowerShell.PSConsoleReadLine]::HistorySearchForward($key, $arg) }
                    LeftArrow { [Microsoft.PowerShell.PSConsoleReadLine]::BackwardChar($key, $arg) }
                    RightArrow { [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg) }
                }
            }
        }
    }
    Set-PSReadLineKeyHandler -Chord Escape -BriefDescription HdcConfirmMenu -ScriptBlock {
        if (Test-HdcShellCompletionState) {
            Clear-HdcShellCompletionMenu
            $script:HdcShellCompletionState.Active = $false
        } else { [Microsoft.PowerShell.PSConsoleReadLine]::Abort() }
    }
    Set-PSReadLineKeyHandler -Chord 'Ctrl+g','Ctrl+c' -BriefDescription HdcCancelMenu -ScriptBlock {
        param($key, $arg)
        if ((Test-HdcShellCompletionState) -and $script:HdcShellCompletionState.Active) {
            $state = $script:HdcShellCompletionState
            Clear-HdcShellCompletionMenu
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $state.Expected.Length, $state.Original)
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($state.OriginalCursor)
            $script:HdcShellCompletionState = $null
        } elseif ($key.KeyChar -eq [char]3) {
            Clear-HdcShellCompletionMenu
            $script:HdcShellCompletionState = $null
            $script:HdcShellCancelled = $true
            [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine($key, $arg)
        } else { [Microsoft.PowerShell.PSConsoleReadLine]::Abort() }
    }
}
