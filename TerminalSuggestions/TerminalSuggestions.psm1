. $PSScriptRoot/HdcTools.ps1
. $PSScriptRoot/HdcShell.ps1
. $PSScriptRoot/HdcShellEditing.ps1
. $PSScriptRoot/HdcShellHighlighting.ps1
. $PSScriptRoot/HdcShellCompletion.ps1

class TerminalHistoryPredictor : System.Management.Automation.Subsystem.Prediction.ICommandPredictor {
    [guid] $Id = [guid]::new('71b50a4b-97f7-4736-9fc8-94214362d9cf')
    [string] $Name = 'TerminalHistory'
    [string] $Description = '基于历史记录前缀匹配的即时提示,类似 fish / zsh-autosuggestions。'
    [System.Collections.Generic.Dictionary[string, string]] $FunctionsToDefine = $null

    [System.Management.Automation.Subsystem.Prediction.SuggestionPackage] GetSuggestion(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [System.Management.Automation.Subsystem.Prediction.PredictionContext] $context,
        [System.Threading.CancellationToken] $token) {

        $userInput = $context.InputAst.Extent.Text
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            return [System.Management.Automation.Subsystem.Prediction.SuggestionPackage]::new($null)
        }
        if ($userInput.Contains("`n") -or $userInput.Contains("`r") -or $userInput.Contains("`t")) {
            return [System.Management.Automation.Subsystem.Prediction.SuggestionPackage]::new($null)
        }

        $results = [System.Collections.Generic.List[System.Management.Automation.Subsystem.Prediction.PredictiveSuggestion]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $recent = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems()) {
            if ($token.IsCancellationRequested) { break }
            $command = $entry.CommandLine
            if ([string]::IsNullOrWhiteSpace($command)) { continue }
            if ($command.Length -le $userInput.Length) { continue }
            if (-not $command.StartsWith($userInput, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($command.Contains("`n") -or $command.Contains("`r") -or $command.Contains("`t")) { continue }
            if ($seen.Add($command)) { $recent.Add($command) }
        }
        for ($i = $recent.Count - 1; $i -ge 0 -and $results.Count -lt 10; $i--) {
            $results.Add([System.Management.Automation.Subsystem.Prediction.PredictiveSuggestion]::new($recent[$i]))
        }
        return [System.Management.Automation.Subsystem.Prediction.SuggestionPackage]::new($results)
    }

    [bool] CanAcceptFeedback(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [System.Management.Automation.Subsystem.Prediction.PredictorFeedbackKind] $feedback) {
        return $false
    }

    [void] OnSuggestionDisplayed(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [uint32] $session, [int] $countOrIndex) { }

    [void] OnSuggestionAccepted(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [uint32] $session, [string] $suggestionText) { }

    [void] OnCommandLineAccepted(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [System.Collections.Generic.IReadOnlyList[string]] $history) { }

    [void] OnCommandLineExecuted(
        [System.Management.Automation.Subsystem.Prediction.PredictionClient] $client,
        [string] $commandLine, [bool] $success) { }
}

function Enable-TerminalSuggestion {
    [CmdletBinding()]
    param(
        [ValidateSet('InlineView', 'ListView', 'InlineAndListView')]
        [string]$PredictionView = 'InlineView'
    )

    if ($PSVersionTable.PSVersion -lt [version]'7.2') {
        throw '需要 PowerShell 7.2 及以上版本。'
    }
    $module = Get-Module PSReadLine -ErrorAction Stop
    if ($module.Version -lt [version]'2.2') {
        throw "需要 PSReadLine 2.2+(当前 $($module.Version)),请运行 Install-Module PSReadLine -Scope CurrentUser。"
    }

    Set-PSReadLineOption -EditMode Windows -PredictionSource HistoryAndPlugin -PredictionViewStyle $PredictionView
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -Colors @{
        Command          = $PSStyle.Foreground.Green
        Comment          = $PSStyle.Foreground.BrightBlack
        ContinuationPrompt = $PSStyle.Foreground.BrightBlack
        Emphasis         = $PSStyle.Foreground.BrightCyan
        Error            = $PSStyle.Foreground.BrightRed
        Keyword          = $PSStyle.Foreground.BrightCyan
        ListPrediction   = $PSStyle.Foreground.BrightBlack
        ListPredictionSelected = "$($PSStyle.Background.FromRgb(0x2c3c55))"
        Member           = $PSStyle.Foreground.White
        Number           = $PSStyle.Foreground.BrightBlue
        Operator         = $PSStyle.Foreground.BrightCyan
        Parameter        = $PSStyle.Foreground.FromRgb(0x9aa5b1)
        Selection        = "$($PSStyle.Background.FromRgb(0x3b5275))"
        String           = $PSStyle.Foreground.Yellow
        Type             = $PSStyle.Foreground.Cyan
        Variable         = $PSStyle.Foreground.BrightMagenta
        InlinePrediction = $PSStyle.Foreground.FromRgb(0x6c7a96)
    }

    $info = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystemInfo(
        [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor)
    if (-not ($info.Implementations | Where-Object { $_.Id -eq [guid]'71b50a4b-97f7-4736-9fc8-94214362d9cf' })) {
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            [TerminalHistoryPredictor]::new())
    }

    Set-PSReadLineKeyHandler -Chord RightArrow -Function ForwardChar
    Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -Function AcceptSuggestion
    Set-PSReadLineKeyHandler -Chord 'Alt+RightArrow' -Function AcceptNextSuggestionWord
    Set-PSReadLineKeyHandler -Chord UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Chord Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Chord F2 -Function SwitchPredictionView
    Set-PSReadLineKeyHandler -Chord F8 -Function HistorySearchBackward

    Write-Verbose 'TerminalSuggestions 已启用:语法高亮、历史预测、菜单补全。'
}

function Disable-TerminalSuggestion {
    [CmdletBinding()]
    param()
    $info = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystemInfo(
        [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor)
    foreach ($item in $info.Implementations) {
        if ($item.Id -eq [guid]'71b50a4b-97f7-4736-9fc8-94214362d9cf') {
            [System.Management.Automation.Subsystem.SubsystemManager]::UnregisterSubsystem(
                [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor, $item.Id)
        }
    }
    Set-PSReadLineOption -PredictionSource History -PredictionViewStyle InlineView
}

Export-ModuleMember -Function Enable-TerminalSuggestion, Disable-TerminalSuggestion,
    Use-HdcDevice, Get-HdcTarget, Invoke-HdcCommand, hdc, Enter-HdcShell
