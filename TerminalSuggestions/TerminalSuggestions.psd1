@{
    RootModule        = 'TerminalSuggestions.psm1'
    ModuleVersion     = '1.3.4'
    GUID              = 'a3ce7042-4f5b-4c8e-9d21-8b7e6f0a1c34'
    Author            = 'luyao'
    Description       = '终端体验增强:PSReadLine 语法高亮主题、fish 风格历史预测提示、菜单补全与历史搜索。参考 oh_dev_tools 的 hdc shell 终端策略。'
    PowerShellVersion = '7.2'
    RequiredModules   = @(@{ ModuleName = 'PSReadLine'; ModuleVersion = '2.2' })
    FunctionsToExport = @('Enable-TerminalSuggestion', 'Disable-TerminalSuggestion',
                          'Use-HdcDevice', 'Get-HdcTarget', 'Invoke-HdcCommand', 'hdc', 'Enter-HdcShell')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('PSReadLine', 'Prediction', 'SyntaxHighlighting', 'Terminal')
            PreRelease = 'beta1'
        }
    }
}
