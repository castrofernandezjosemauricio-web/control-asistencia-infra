param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')]
    [string]$Bucket
)
$ErrorActionPreference = 'Stop'
$awsCommand = Get-Command aws.exe -CommandType Application -ErrorAction SilentlyContinue
if ($awsCommand) {
    $awsExecutable = $awsCommand.Source
} else {
    $awsExecutable = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
    if (-not (Test-Path -LiteralPath $awsExecutable)) {
        throw 'AWS CLI no encontrado. Instala AWS CLI v2 y abre una nueva terminal.'
    }
}
function Invoke-Aws {
    param([string[]]$Arguments)
    & $awsExecutable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Fallo AWS CLI: $($Arguments[0]) $($Arguments[1])" }
}
# Ejecutar una sola vez con un nombre nuevo y globalmente unico.
# Se detiene si el bucket ya existe: no modifica buckets ajenos al laboratorio.
Invoke-Aws -Arguments @('sts', 'get-caller-identity')
Invoke-Aws -Arguments @('s3api', 'create-bucket', '--bucket', $Bucket, '--region', 'us-east-1')
Invoke-Aws -Arguments @('s3api', 'put-public-access-block', '--bucket', $Bucket, '--public-access-block-configuration', 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true')
Invoke-Aws -Arguments @('s3api', 'put-bucket-versioning', '--bucket', $Bucket, '--versioning-configuration', 'Status=Enabled')
$encryptionFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
try {
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' | Set-Content -LiteralPath $encryptionFile -Encoding Ascii
    Invoke-Aws -Arguments @('s3api', 'put-bucket-encryption', '--bucket', $Bucket, '--server-side-encryption-configuration', "file://$encryptionFile")
} finally {
    Remove-Item -LiteralPath $encryptionFile -ErrorAction SilentlyContinue
}
Write-Host "Bucket preparado: $Bucket. Configura backend.hcl antes de migrar el estado."
