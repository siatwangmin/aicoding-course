#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Course-Context.ps1')
function Resolve-CourseProjectRoot([string]$Directory) {
    $inputPath=(Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    Assert-CoursePlainPath $inputPath
    if(-not(Test-Path -LiteralPath $inputPath -PathType Container)){throw 'PROJECT_DIRECTORY_REQUIRED'}
    $cursor=$inputPath;$candidates=@();$depth=0
    while($cursor -and $depth -le 12){
        Assert-CoursePlainPath $cursor
        $manifest=Join-Path $cursor '.ai-coding\project.json'
        if(Test-Path -LiteralPath $manifest -PathType Leaf){
            $project=Read-CourseJson $manifest
            if(-not $project.sourceDirectory){throw 'PROJECT_SOURCE_BINDING_REQUIRED'}
            $source=[IO.Path]::GetFullPath((Join-Path $cursor $project.sourceDirectory));Assert-CoursePlainPath $source
            $prefix=$cursor.TrimEnd('\')+'\'
            if($source -ne $cursor -and -not $source.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'PROJECT_SOURCE_ESCAPES_ROOT'}
            if($cursor -eq $inputPath){return $cursor}
            if($inputPath -eq $source -or $inputPath.StartsWith($source.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$candidates+= $cursor}
        }
        $next=Split-Path $cursor -Parent
        if(-not $next -or $next -eq $cursor){break}
        $cursor=$next;$depth++
    }
    if($candidates.Count -ne 1){throw 'PROJECT_ROOT_MISSING_OR_AMBIGUOUS: pass the B directory containing .ai-coding/project.json; no project state was created.'}
    return $candidates[0]
}
