[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StackName,
    [string]$Region = 'us-east-1',
    [string]$AwsProfile
)

$ErrorActionPreference = 'Stop'
$awsArgs = @('cloudformation', 'detect-stack-drift', '--stack-name', $StackName, '--region', $Region)
if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }
$result = & aws.exe @awsArgs | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar la deteccion de drift.' }
$driftId = $result.StackDriftDetectionId
$describeArgs = @('cloudformation', 'describe-stack-drift-detection-status', '--stack-drift-detection-id', $driftId, '--region', $Region)
if ($AwsProfile) { $describeArgs += @('--profile', $AwsProfile) }
do {
    Start-Sleep -Seconds 5
    $status = & aws.exe @describeArgs | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar el resultado de drift.' }
} while ($status.DetectionStatus -eq 'DETECTION_IN_PROGRESS')
$status | Format-List
if ($status.DetectionStatus -ne 'DETECTION_COMPLETE') { throw "Deteccion de drift termino con $($status.DetectionStatus)." }
if ($status.StackDriftStatus -eq 'DRIFTED') {
    $resourceArgs = @('cloudformation', 'describe-stack-resource-drifts', '--stack-name', $StackName, '--stack-resource-drift-status-filters', 'MODIFIED', 'DELETED', 'NOT_CHECKED', '--region', $Region)
    if ($AwsProfile) { $resourceArgs += @('--profile', $AwsProfile) }
    & aws.exe @resourceArgs
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron listar recursos con drift.' }
}
