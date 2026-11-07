$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot '../TerminalSuggestions/HdcShellProcess.cs')
$checks = 0
function Check($Value, $Expected, $Message) {
    if ($Value -cne $Expected) { throw "$Message : expected [$Expected], got [$Value]" }
    $script:checks++
}
$marker = '@@HDC_TEST_MARKER@@'
$encoded = $marker + "PID:321:321`n" + "first`n`e[96mUnicode 中文`e[0m" + $marker + "7`n/data/local`n"
$expected = "first`n`e[96mUnicode 中文`e[0m"
foreach ($size in @(1, 2, 3, 7, 19, 4096)) {
    $builder = [Text.StringBuilder]::new()
    $stream = [TerminalSuggestions.HdcShellOutputStream]::new($marker, [Action[string]]{ param($s); [void]$builder.Append($s) })
    for ($i = 0; $i -lt $encoded.Length; $i += $size) {
        $stream.Push($encoded.Substring($i, [Math]::Min($size, $encoded.Length - $i)))
    }
    $stream.Finish()
    Check $builder.ToString() $expected "Exact output with $size-character chunks"
    Check $stream.Pid 321 'Process identity never appears in output'
    Check $stream.Group 321 'The process group is decoded'
    Check $stream.ExitCode 7 'Remote exit status is decoded'
    Check $stream.Directory '/data/local' 'Remote cwd is decoded'
}
$builder = [Text.StringBuilder]::new()
$stream = [TerminalSuggestions.HdcShellOutputStream]::new($marker, [Action[string]]{ param($s); [void]$builder.Append($s) })
$stream.Push('no newline yet')
Check $builder.ToString() 'no newline yet' 'Output is displayed before a newline or process exit'
$partial = 'body@@HDC_TE'
$builder.Clear() | Out-Null
$stream.Push($partial)
$stream.Finish()
Check $builder.ToString() $partial 'An ordinary partial marker suffix is not lost on EOF'
$builder.Clear() | Out-Null
$stream.Push($marker + "not-a-control-record`n")
$stream.Finish()
Check $builder.ToString() ($marker + "not-a-control-record`n") 'Malformed metadata is displayed without swallowing output'
Write-Host "PASS: $checks stream protocol checks"
