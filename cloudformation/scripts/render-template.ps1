[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$cloudFormationRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $cloudFormationRoot 'templates\main.yaml'
$backendPath = Join-Path $cloudFormationRoot 'userdata\backend.sh'
$frontendPath = Join-Path $cloudFormationRoot 'userdata\frontend.sh'

function Add-YamlIndent {
    param([string]$Text, [int]$Spaces = 14)
    $lines = $Text.TrimEnd() -split "`r?`n"
    $indent = ' ' * $Spaces
    return (($lines | ForEach-Object { "$indent$_" }) -join "`n")
}

$template = Get-Content -Raw -Encoding UTF8 $templatePath
$backend = Get-Content -Raw -Encoding UTF8 $backendPath
$frontend = Get-Content -Raw -Encoding UTF8 $frontendPath

$backend = $backend.Replace('@@AWS_REGION@@', '${AWS::Region}')
$backend = $backend.Replace('@@STACK_NAME@@', '${AWS::StackName}')
$backend = $backend.Replace('@@DATABASE_SECRET_ARN@@', '${DatabaseSecretArn}')
$backend = $backend.Replace('@@DJANGO_SECRET_ARN@@', '${DjangoSecretArn}')
$frontend = $frontend.Replace('@@AWS_REGION@@', '${AWS::Region}')
$frontend = $frontend.Replace('@@STACK_NAME@@', '${AWS::StackName}')
$frontend = $frontend.Replace('@@BACKEND_PRIVATE_IP@@', '${BackendPrivateIp}')

$template = $template.Replace('              __BACKEND_USERDATA__', (Add-YamlIndent $backend))
$template = $template.Replace('              __FRONTEND_USERDATA__', (Add-YamlIndent $frontend))

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $template, $utf8NoBom)
