[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$StackName,
    [string]$Region = 'us-east-1',
    [string]$AwsProfile
)

$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ShouldProcess("$StackName in $Region", 'Delete CloudFormation stack and all managed resources')) {
    $awsArgs = @('cloudformation', 'delete-stack', '--stack-name', $StackName, '--region', $Region)
    if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }
    & aws.exe @awsArgs
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo solicitar la eliminacion del stack.' }
    $waitArgs = @('cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $StackName, '--region', $Region)
    if ($AwsProfile) { $waitArgs += @('--profile', $AwsProfile) }
    & aws.exe @waitArgs
    if ($LASTEXITCODE -ne 0) { throw 'La eliminacion del stack no termino correctamente.' }
}
