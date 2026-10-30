#Requires -Version 5.1
# Pure archive helper. Unlike executable bootstrap scripts, this has no parameters.
function Expand-CourseMaterials {
    param([string]$Archive,[string]$Staging,[int]$MaxEntries=2000)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root=[IO.Path]::GetFullPath($Staging).TrimEnd('\')+'\'
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        if($MaxEntries -lt 1 -or $MaxEntries -gt 5000 -or $zip.Entries.Count -gt $MaxEntries -or ($zip.Entries|Measure-Object Length -Sum).Sum -gt 200MB){throw 'Unexpected archive size.'}
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('/','\')
            $target=[IO.Path]::GetFullPath((Join-Path $Staging $name))
            if([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or -not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'Unsafe archive path.'}
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Staging)
    }finally{$zip.Dispose()}
}
