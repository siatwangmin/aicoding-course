#Requires -Version 5.1
# Resolve only a recorded execution package; importing does not install anything.
function Resolve-CourseExecutionRoot([string]$ProjectDirectory) {
    $record = $null
    if ($ProjectDirectory) {
        $cursor = [IO.Path]::GetFullPath($ProjectDirectory)
        while ($cursor) {
            $file = Join-Path $cursor '.ai-coding/local.json'
            if (Test-Path -LiteralPath $file) {
                $local = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($local.executionRoot) { $record = $local; break }
            }
            $parent = Split-Path $cursor -Parent
            if ($parent -eq $cursor) { break }; $cursor = $parent
        }
    }
    if (-not $record) {
        $file = Join-Path $env:USERPROFILE '.ai-coding/execution.json'
        if (-not (Test-Path -LiteralPath $file)) { throw 'EXECUTION_PACKAGE_MISSING: restore the preparation in its own workspace.' }
        $record = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $root = [IO.Path]::GetFullPath($record.executionRoot)
    $manifest = Join-Path $root 'execution-manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) { throw 'RECORDED_EXECUTION_PACKAGE_MISSING' }
    $identity = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.executionId -and $record.executionId -cne $identity.contentId) { throw 'EXECUTION_ID_MISMATCH' }
    foreach ($item in $identity.files.PSObject.Properties) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $item.Name))
        if (-not $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'EXECUTION_PATH_ESCAPES_ROOT' }
        $cursor = $path
        while ($cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'EXECUTION_LINK_REFUSED' }
            $cursor = Split-Path $cursor -Parent
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $item.Value) { throw ('EXECUTION_FILE_MISMATCH: '+$item.Name) }
    }
    return $root
}
