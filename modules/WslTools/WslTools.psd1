@{
    RootModule        = 'WslTools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f2c7e1-4b8d-4f9a-a6e3-2c1d5b8f7e0a'
    Author            = 'Particular Software'
    Description       = 'WSL helper functions for the setup-wsl-action GitHub Action.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-Wsl')
    FileList          = @('WslTools.psm1')
}