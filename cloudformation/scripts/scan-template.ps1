[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TemplatePath
)

$ErrorActionPreference = 'Stop'
$resolvedPath = (Resolve-Path -LiteralPath $TemplatePath).Path
$trivy = Get-Command trivy.exe -ErrorAction SilentlyContinue
if (-not $trivy) {
    $trivy = Get-Command trivy -ErrorAction SilentlyContinue
}
if (-not $trivy) {
    throw 'No se encontro Trivy. Instala con: winget install --id AquaSecurity.Trivy --exact --source winget'
}
$checkov = Get-Command checkov.exe -ErrorAction SilentlyContinue
if (-not $checkov) {
    $checkov = Get-Command checkov -ErrorAction SilentlyContinue
}
if (-not $checkov) {
    throw 'No se encontro Checkov. Instala con: python -m pip install -r cloudformation\tests\requirements.txt'
}

Write-Host "`n=== Trivy: configuracion IaC ==="
& $trivy.Source config --format table --severity HIGH,CRITICAL --exit-code 0 $resolvedPath
if ($LASTEXITCODE -ne 0) { throw "Trivy termino con error de ejecucion (exit $LASTEXITCODE)." }

Write-Host "`n=== Checkov: framework CloudFormation ==="
& $checkov.Source --framework cloudformation --file $resolvedPath --compact --soft-fail
if ($LASTEXITCODE -ne 0) { throw "Checkov termino con error de ejecucion (exit $LASTEXITCODE)." }

Write-Host "`nEscaneo completado. Revisa los hallazgos reportados; el modo soft-fail permite discutirlos en la defensa."
