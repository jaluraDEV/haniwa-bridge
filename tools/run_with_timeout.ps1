param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string]$ArgumentList = "",
    [string]$WorkingDirectory = "",
    [int]$TimeoutSeconds = 15
)

$startParams = @{
    FilePath = $FilePath
    PassThru = $true
    NoNewWindow = $true
}
if ($ArgumentList -ne "") {
    $startParams["ArgumentList"] = $ArgumentList
}
if ($WorkingDirectory -ne "") {
    $startParams["WorkingDirectory"] = $WorkingDirectory
}

$p = Start-Process @startParams
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    $p.Kill()
    Write-Host "TIMEOUT after $TimeoutSeconds seconds"
    exit 124
}
Write-Host "Process finished with exit code $($p.ExitCode)"
exit $p.ExitCode
