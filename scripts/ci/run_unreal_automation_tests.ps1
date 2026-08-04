param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$ResultUri,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$SourceVersion
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$engineRoot = "C:\Program Files\Epic Games\UE_5.6"
$editor = Join-Path $engineRoot "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$runRoot = "C:\UnrealCI\runs\$RunId"
$resultRoot = Join-Path $runRoot "results"
$stdoutPath = Join-Path $resultRoot "UnrealEditor.stdout.log"
$stderrPath = Join-Path $resultRoot "UnrealEditor.stderr.log"
$transcriptPath = Join-Path $resultRoot "runner.log"
$resultPath = Join-Path $resultRoot "result.json"

New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
Start-Transcript -Path $transcriptPath -Force

$status = "failed"
$completedCount = 0
$failedCount = 0
$failureMessage = $null

try {
    if (-not (Test-Path $editor)) {
        throw "UE 5.6 editor was not found at $editor"
    }

    Get-Process "UnrealEditor", "UnrealEditor-Cmd" -ErrorAction SilentlyContinue |
        Stop-Process -Force

    $buildStarted = (Get-Date).ToUniversalTime()
    Push-Location $SourceRoot
    try {
        $env:SETUPTOOLS_SCM_PRETEND_VERSION = "0.0.0"
        python scripts/build_plugin.py --ueversion 5.6 --install --test
        if ($LASTEXITCODE -ne 0) {
            throw "build_plugin.py failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }

    $installedDll = Join-Path $engineRoot "Engine\Plugins\UnrealDeadlineCloudService\Binaries\Win64\UnrealEditor-UnrealDeadlineCloudService.dll"
    if (-not (Test-Path $installedDll)) {
        throw "The installed UnrealDeadlineCloudService DLL was not found"
    }
    if ((Get-Item $installedDll).LastWriteTimeUtc -lt $buildStarted.AddSeconds(-2)) {
        throw "The installed UnrealDeadlineCloudService DLL was not refreshed by this build"
    }

    $uatLog = Join-Path $env:APPDATA "Unreal Engine\AutomationTool\Logs\C+Program+Files+Epic+Games+UE_5.6\Log.txt"
    if (-not (Test-Path $uatLog)) {
        throw "The Unreal AutomationTool build log was not found"
    }
    if (-not (Select-String -Path $uatLog -Pattern "BUILD SUCCESSFUL" -Quiet)) {
        throw "The Unreal AutomationTool log does not contain BUILD SUCCESSFUL"
    }
    if (Select-String -Path $uatLog -Pattern "error C[0-9]+" -Quiet) {
        throw "The Unreal AutomationTool log contains a C++ compiler error"
    }

    $fixtureRoot = Join-Path $SourceRoot "scripts\ci\fixtures\MeerkatDemo-CI"
    $ciProjectRoot = Join-Path $runRoot "MeerkatDemo-CI"
    if (-not (Test-Path (Join-Path $fixtureRoot "MeerkatDemo.uproject"))) {
        throw "The stripped MeerkatDemo CI fixture was not found at $fixtureRoot"
    }
    Remove-Item $ciProjectRoot -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $fixtureRoot $ciProjectRoot -Recurse -Force
    $project = Get-Item (Join-Path $ciProjectRoot "MeerkatDemo.uproject")

    $logDirectory = Join-Path $project.DirectoryName "Saved\Logs"
    if (Test-Path $logDirectory) {
        Remove-Item $logDirectory -Recurse -Force
    }

    $commonArguments = @(
        "`"$($project.FullName)`"",
        "-RenderOffScreen",
        "-ForceRes",
        "-ResX=1920",
        "-ResY=1080",
        "-unattended",
        "-nosplash",
        "-NoSound",
        "-SCCProvider=None",
        "`"-LogCmds=LogPython off`"",
        "-log"
    )
    $previousMetadataDisabled = $env:AWS_EC2_METADATA_DISABLED
    try {
        # UE must behave like an offline workstation. Keep the instance role available
        # to this runner so it can download source and upload results.
        $env:AWS_EC2_METADATA_DISABLED = "true"

        $testPrefixes = @(
            "DeadlineCloud.SaveAsJobPreset",
            "DeadlineCloud.Validation",
            "DeadlineCloud.UpdateDialog",
            "DeadlineCloud.PluginDependencies",
            "DeadlineCloud.FOpenDeadlineJob",
            "DeadlineCloud.FOpenDeadlineStep",
            "DeadlineCloud.FOpenDeadlineEnvironment",
            "DeadlineCloud.FDeadlineHostRequirements",
            "DeadlineCloud.DeadlineCloudMRQJobUI",
            "DeadlineCloud.DeadlineCloudJobUI",
            "DeadlineCloud.DeadlineCloudStepUI",
            "DeadlineCloud.DeadlineCloudEnvironmentUI",
            "DeadlineCloud.DeadlineCloudHostRequirementsUI",
            "DeadlineCloud.DeadlineCloudSavePresetWidget"
        )
        $testSelection = $testPrefixes -join "+"
        $arguments = $commonArguments + @(
            "`"-ExecCmds=Automation RunTests $testSelection`"",
            "`"-testexit=Automation Test Queue Empty`""
        )

        $process = Start-Process `
            -FilePath $editor `
            -ArgumentList $arguments `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -Wait
        Write-Host "UnrealEditor-Cmd exit code: $($process.ExitCode)"
    } finally {
        if ($null -eq $previousMetadataDisabled) {
            Remove-Item Env:\AWS_EC2_METADATA_DISABLED -ErrorAction SilentlyContinue
        } else {
            $env:AWS_EC2_METADATA_DISABLED = $previousMetadataDisabled
        }
    }

    $ueLog = Get-ChildItem $logDirectory -Filter "*.log" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $ueLog) {
        throw "No Unreal Editor log was produced"
    }
    Copy-Item $ueLog.FullName (Join-Path $resultRoot "UnrealEditor.log") -Force

    Copy-Item $uatLog (Join-Path $resultRoot "AutomationTool.log") -Force

    $completed = @(
        Select-String -Path $ueLog.FullName -Pattern "Test Completed\. Result=\{(Success|Fail)\}.*DeadlineCloud"
    )
    $failed = @($completed | Where-Object { $_.Line -match "Result=\{Fail\}" })
    $completedCount = $completed.Count
    $failedCount = $failed.Count
    $completed | ForEach-Object { Write-Host $_.Line }

    if ($completedCount -ne 45) {
        throw "Expected 45 offline test completions, found $completedCount"
    }
    if ($failedCount -gt 0) {
        throw "$failedCount offline DeadlineCloud tests failed"
    }

    $status = "passed"
} catch {
    $failureMessage = $_.Exception.Message
    Write-Error $failureMessage
} finally {
    $result = [ordered]@{
        status = $status
        completed = $completedCount
        failed = $failedCount
        expected = 45
        runId = $RunId
        sourceRevision = $SourceVersion
        failure = $failureMessage
        finishedAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json), $utf8WithoutBom)

    Stop-Transcript
    aws s3 cp $resultRoot "$ResultUri/" --recursive --no-progress
    if ($LASTEXITCODE -ne 0) {
        throw "Could not upload Unreal automation results to $ResultUri"
    }
}

if ($status -ne "passed") {
    exit 1
}
