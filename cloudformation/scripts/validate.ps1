$ErrorActionPreference = 'Stop'
$cloudFormationRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $cloudFormationRoot
$renderDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('control-asistencia-cfn-' + [guid]::NewGuid().ToString('N'))
$renderedPath = Join-Path $renderDirectory 'main.yaml'
$previousTemplatesDir = $env:TEMPLATES_DIR
Push-Location $repoRoot
try {
    & (Join-Path $PSScriptRoot 'render-template.ps1') -OutputPath $renderedPath
    if (-not (Get-Command cfn-lint -ErrorAction SilentlyContinue)) {
        throw 'Falta cfn-lint. Instala dependencias con: python -m pip install -r cloudformation\tests\requirements.txt'
    }
    cfn-lint $renderedPath
    if ($LASTEXITCODE -ne 0) { throw 'cfn-lint reporto errores.' }

    $env:TEMPLATES_DIR = $renderDirectory
    python -m pytest cloudformation\tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Fallaron los tests de seguridad.' }

    & (Join-Path $PSScriptRoot 'scan-template.ps1') -TemplatePath $renderedPath

    Write-Host 'Validacion local completada. La validacion remota AWS se ejecuta al crear el change set.'
} finally {
    $env:TEMPLATES_DIR = $previousTemplatesDir
    Pop-Location
    Remove-Item -LiteralPath $renderDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
