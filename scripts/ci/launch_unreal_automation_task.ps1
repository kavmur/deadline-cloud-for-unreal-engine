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

$taskName = "UnrealAutomation-$RunId"
$runner = Join-Path $SourceRoot "scripts\ci\run_unreal_automation_tests.ps1"
if (-not (Test-Path $runner)) {
    throw "The Unreal automation runner was not found at $runner"
}

$service = New-Object -ComObject "Schedule.Service"
$service.Connect()
$folder = $service.GetFolder("\")

try {
    $folder.DeleteTask($taskName, 0)
} catch {
    # The task normally does not exist on an ephemeral host.
}

$task = $service.NewTask(0)
$task.RegistrationInfo.Description = "Runs Unreal automation tests in the logged-in desktop session"
$task.Principal.UserId = "$env:COMPUTERNAME\UnrealTestRunner"
$task.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN
$task.Principal.RunLevel = 1
$task.Settings.Enabled = $true
$task.Settings.StartWhenAvailable = $true
$task.Settings.ExecutionTimeLimit = "PT110M"
$task.Settings.MultipleInstances = 0

$action = $task.Actions.Create(0)
$action.Path = "PowerShell.exe"
$action.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -SourceRoot `"$SourceRoot`" -ResultUri `"$ResultUri`" -RunId `"$RunId`" -SourceVersion `"$SourceVersion`""
$action.WorkingDirectory = $SourceRoot

$registeredTask = $folder.RegisterTaskDefinition(
    $taskName,
    $task,
    6, # TASK_CREATE_OR_UPDATE
    $null,
    $null,
    3, # TASK_LOGON_INTERACTIVE_TOKEN
    $null
)
$registeredTask.Run($null) | Out-Null

Write-Host "Started $taskName with TASK_LOGON_INTERACTIVE_TOKEN"
