[CmdletBinding()]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'dev',
    [string]$ProjectName,
    [string]$SshCidr,
    [string]$InstanceType,
    [string]$AmiId,
    [string]$Region,
    [string]$AwsProfile,
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'
$cloudFormationRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $cloudFormationRoot
$rendererPath = Join-Path $PSScriptRoot 'render-template.ps1'
$parametersPath = Join-Path $cloudFormationRoot "parameters\$Environment.json"
if (-not (Test-Path $parametersPath)) { throw "No existe el archivo de parametros $parametersPath" }
$parameterDefaults = Get-Content -Raw -Encoding UTF8 $parametersPath | ConvertFrom-Json
$defaultMap = @{}
foreach ($entry in $parameterDefaults) { $defaultMap[$entry.ParameterKey] = $entry.ParameterValue }
$ProjectName = if ($ProjectName) { $ProjectName } else { $defaultMap.ProjectName }
$SshCidr = if ($SshCidr) { $SshCidr } else { $defaultMap.SshCidr }
$InstanceType = if ($InstanceType) { $InstanceType } else { $defaultMap.InstanceType }
$AmiId = if ($AmiId) { $AmiId } else { $defaultMap.AmiId }
$defaultProjectName = if ($Environment -eq 'prod') { 'asistencia-prod-cfn' } else { 'asistencia-lab3-cfn' }
if (-not $ProjectName) { $ProjectName = $defaultProjectName }
$stackName = $ProjectName
$changeSetName = 'deploy-' + (Get-Date -Format 'yyyyMMddHHmmss')
$renderedPath = Join-Path ([System.IO.Path]::GetTempPath()) "$stackName-$changeSetName.yaml"

function Invoke-Aws {
    param([string[]]$Arguments)
    if ($AwsProfile) { $Arguments += @('--profile', $AwsProfile) }
    & aws.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI fallo (exit $LASTEXITCODE): aws $($Arguments -join ' ')" }
}

Push-Location $repoRoot
try {
    & (Join-Path $PSScriptRoot 'validate.ps1')
    Invoke-Aws -Arguments @('sts', 'get-caller-identity', '--output', 'json')

    & $rendererPath -OutputPath $renderedPath

    if ((Get-Item $renderedPath).Length -gt 51200) {
        throw 'La plantilla renderizada excede el limite de 51200 bytes de TemplateBody.'
    }

    $identityArgs = @('sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
    $regionArgs = @('configure', 'get', 'region')
    if ($AwsProfile) {
        $identityArgs += @('--profile', $AwsProfile)
        $regionArgs += @('--profile', $AwsProfile)
    }
    $caller = aws.exe @identityArgs
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo identificar la cuenta AWS.' }
    $configuredRegion = aws.exe @regionArgs
    if ($LASTEXITCODE -ne 0 -or -not $configuredRegion) { $configuredRegion = 'us-east-1' }
    $region = if ($Region) { $Region } else { $configuredRegion }
    $statusArgs = @('cloudformation', 'describe-stacks', '--stack-name', $stackName, '--query', 'Stacks[0].StackStatus', '--output', 'text', '--region', $region)
    if ($AwsProfile) { $statusArgs += @('--profile', $AwsProfile) }
    $stackStatus = aws.exe @statusArgs 2>$null
    $stackExists = $LASTEXITCODE -eq 0
    $changeSetType = if ($stackExists) { 'UPDATE' } else { 'CREATE' }
    $parameterArgs = @(
        "ParameterKey=ProjectName,ParameterValue=$ProjectName",
        "ParameterKey=InstanceType,ParameterValue=$InstanceType",
        "ParameterKey=SshCidr,ParameterValue=$SshCidr",
        "ParameterKey=AmiId,ParameterValue=$AmiId"
    )
    $templateUri = 'file://' + $renderedPath
    $createArgs = @(
        'cloudformation', 'create-change-set',
        '--stack-name', $stackName,
        '--change-set-name', $changeSetName,
        '--change-set-type', $changeSetType,
        '--template-body', $templateUri,
        '--parameters'
    ) + $parameterArgs + @(
        '--capabilities', 'CAPABILITY_IAM',
        '--description', "Control asistencia $Environment deployment",
        '--region', $region,
        '--output', 'json'
    )
    Invoke-Aws -Arguments $createArgs
    $changeStatusArgs = @('cloudformation', 'describe-change-set', '--stack-name', $stackName, '--change-set-name', $changeSetName, '--region', $region, '--query', '{Status:Status,Reason:StatusReason}', '--output', 'json')
    if ($AwsProfile) { $changeStatusArgs += @('--profile', $AwsProfile) }
    $changeSetReady = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $changeStatus = aws.exe @changeStatusArgs | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar el estado del change set.' }
        if ($changeStatus.Status -eq 'CREATE_COMPLETE') {
            $changeSetReady = $true
            break
        }
        if ($changeStatus.Status -eq 'FAILED') {
            if ($changeStatus.Reason -match 'didn.t contain changes') {
                if ($changeSetType -eq 'CREATE') {
                    Invoke-Aws -Arguments @('cloudformation', 'delete-stack', '--stack-name', $stackName, '--region', $region)
                    Invoke-Aws -Arguments @('cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $stackName, '--region', $region)
                } else {
                    Invoke-Aws -Arguments @('cloudformation', 'delete-change-set', '--stack-name', $stackName, '--change-set-name', $changeSetName, '--region', $region)
                }
                Write-Host 'No hay cambios para aplicar.'
                return
            }
            if ($changeSetType -eq 'CREATE') {
                Invoke-Aws -Arguments @('cloudformation', 'delete-stack', '--stack-name', $stackName, '--region', $region)
                Invoke-Aws -Arguments @('cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $stackName, '--region', $region)
            }
            throw "CloudFormation no pudo crear el change set: $($changeStatus.Reason)"
        }
        Start-Sleep -Seconds 5
    }
    if (-not $changeSetReady) { throw 'Timeout esperando que CloudFormation prepare el change set.' }
    $changeArgs = @('cloudformation', 'describe-change-set', '--stack-name', $stackName, '--change-set-name', $changeSetName, '--region', $region, '--query', 'Changes[].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}', '--output', 'table')
    if ($AwsProfile) { $changeArgs += @('--profile', $AwsProfile) }
    $changes = aws.exe @changeArgs
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer el change set.' }
    $changes

    if (-not $AutoApprove) {
        $confirmation = Read-Host "Ejecutar este change set en la cuenta $caller, region $region? Escribe YES"
        if ($confirmation -cne 'YES') {
            if ($changeSetType -eq 'CREATE') {
                Invoke-Aws -Arguments @('cloudformation', 'delete-stack', '--stack-name', $stackName, '--region', $region)
                Invoke-Aws -Arguments @('cloudformation', 'wait', 'stack-delete-complete', '--stack-name', $stackName, '--region', $region)
            } else {
                Invoke-Aws -Arguments @('cloudformation', 'delete-change-set', '--stack-name', $stackName, '--change-set-name', $changeSetName, '--region', $region)
            }
            Write-Host 'Change set eliminado; no se modifico infraestructura.'
            return
        }
    }

    Invoke-Aws -Arguments @('cloudformation', 'execute-change-set', '--stack-name', $stackName, '--change-set-name', $changeSetName, '--region', $region)
    if ($changeSetType -eq 'CREATE') {
        Invoke-Aws -Arguments @('cloudformation', 'wait', 'stack-create-complete', '--stack-name', $stackName, '--region', $region)
    } else {
        Invoke-Aws -Arguments @('cloudformation', 'wait', 'stack-update-complete', '--stack-name', $stackName, '--region', $region)
    }
    $outputArgs = @('cloudformation', 'describe-stacks', '--stack-name', $stackName, '--region', $region, '--query', 'Stacks[0].Outputs', '--output', 'json')
    if ($AwsProfile) { $outputArgs += @('--profile', $AwsProfile) }
    $outputs = aws.exe @outputArgs | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'El stack se completo, pero no se pudieron leer los outputs.' }
    $outputMap = @{}
    foreach ($output in $outputs) { $outputMap[$output.OutputKey] = $output.OutputValue }

    $healthOk = $false
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $outputMap.UrlHealth -TimeoutSec 20 -UseBasicParsing
            if ($response.StatusCode -eq 200) { $healthOk = $true; break }
        } catch {
            Start-Sleep -Seconds 20
        }
    }
    if (-not $healthOk) { throw "El stack se creo, pero el health check HTTPS no respondio 200: $($outputMap.UrlHealth)" }

    Write-Host "`nDespliegue listo:"
    $outputAliases = @{
        BackendId = 'backend_id'
        FrontendId = 'frontend_id'
        IpBackend = 'ip_backend'
        IpFrontend = 'ip_frontend'
        UrlHealth = 'url_health'
        UrlSistema = 'url_sistema'
    }
    foreach ($key in ($outputAliases.Keys | Sort-Object)) {
        Write-Host "$($outputAliases[$key]): $($outputMap[$key])"
    }
    Write-Host "`nPrimer administrador: conectate al backend con EC2 Instance Connect y ejecuta:"
    Write-Host 'sudo -u asistencia /opt/backend/venv/bin/python /opt/backend/manage.py seed_admin --nombre "Administrador" --correo "admin@example.test"'
    Write-Host 'La contrasena se solicita de forma interactiva; no se incluye en parametros ni archivos.'
} finally {
    Pop-Location
    Remove-Item -LiteralPath $renderedPath -Force -ErrorAction SilentlyContinue
}
