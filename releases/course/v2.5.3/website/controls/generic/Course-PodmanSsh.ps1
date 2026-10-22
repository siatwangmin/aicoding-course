#Requires -Version 5.1
# Inspect only the identity selected by the current local machine configuration.
. (Join-Path $PSScriptRoot 'Course-Native.ps1')

function Assert-CoursePodmanSshBinding($MachineInfo,$Connection) {
    $name=[string]$MachineInfo.Name
    if($name -notmatch '^podman-machine-[a-zA-Z0-9_-]+$'){throw 'PODMAN_SSH_MACHINE_REQUIRED'}
    $expectedName=if($MachineInfo.Rootful){$name+'-root'}else{$name}
    $expectedUser=if($MachineInfo.Rootful){'root'}else{[string]$MachineInfo.SSHConfig.RemoteUsername}
    $port=[int]$MachineInfo.SSHConfig.Port;$identity=[string]$MachineInfo.SSHConfig.IdentityPath
    if($expectedUser -notmatch '^[a-z_][a-z0-9_-]*$' -or $port -lt 1 -or $port -gt 65535 -or -not [IO.Path]::IsPathRooted($identity)){throw 'PODMAN_SSH_MACHINE_METADATA_INVALID'}
    if($Connection.Name -cne $expectedName -or $Connection.IsMachine -ne $true -or -not $Connection.Identity -or [IO.Path]::GetFullPath($Connection.Identity) -ine [IO.Path]::GetFullPath($identity)){throw 'PODMAN_SSH_CONNECTION_IDENTITY_MISMATCH'}
    try{$uri=[uri]$Connection.URI}catch{throw 'PODMAN_SSH_CONNECTION_URI_INVALID'}
    $socketMatches=if($MachineInfo.Rootful){$uri.AbsolutePath -ceq '/run/podman/podman.sock'}else{$uri.AbsolutePath -cmatch '^/run/user/[0-9]+/podman/podman\.sock$'}
    if($uri.Scheme -cne 'ssh' -or $uri.Host -cne '127.0.0.1' -or $uri.Port -ne $port -or $uri.UserInfo -cne $expectedUser -or -not $socketMatches -or $uri.Query -or $uri.Fragment){throw 'PODMAN_SSH_CONNECTION_ROLE_MISMATCH: preserve the machine; restore its recorded rootless/rootful connection.'}
    Assert-CoursePlainPath $identity
    return [pscustomobject]@{machine=$name;connection=$expectedName;username=$expectedUser;rootful=[bool]$MachineInfo.Rootful;identity=$identity;port=$port}
}
function Get-CoursePodmanKeyPermissions([string]$Path) {
    Assert-CoursePlainPath $Path
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'PODMAN_SSH_PRIVATE_KEY_MISSING'}
    $acl=Get-Acl -LiteralPath $Path
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $trusted=@($current,'S-1-5-18','S-1-5-32-544')
    $unexpected=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $trusted})
    return [pscustomobject]@{ownerMatches=($owner -eq $current);protected=$acl.AreAccessRulesProtected;unexpectedAllowSids=@($unexpected|ForEach-Object {$_.IdentityReference.Value}|Select-Object -Unique);safe=($owner -eq $current -and $acl.AreAccessRulesProtected -and $unexpected.Count -eq 0);sddl=$acl.Sddl}
}
function Repair-CoursePodmanKeyPermissions([string]$Path) {
    $before=Get-CoursePodmanKeyPermissions $Path
    if(-not $before.ownerMatches){throw 'PODMAN_SSH_PRIVATE_KEY_OWNER_MISMATCH: preserve the original owner; do not take ownership automatically.'}
    if($before.safe){return [pscustomobject]@{changed=$false;keyBytesPreserved=$true;beforeSddl=$before.sddl;afterSddl=$before.sddl}}
    $digest=(Get-FileHash -LiteralPath $Path).Hash
    $legacyAclApi=[IO.File].GetMethods().Name -contains 'GetAccessControl'
    $acl=if($legacyAclApi){[IO.File]::GetAccessControl($Path,[Security.AccessControl.AccessControlSections]::Access)}else{[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path),[Security.AccessControl.AccessControlSections]::Access)}
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))){[void]$acl.RemoveAccessRuleSpecific($rule)}
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))
    }
    # Change DACL only. Do not request ownership/SACL privileges or elevation.
    if($legacyAclApi){[IO.File]::SetAccessControl($Path,$acl)}else{[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path),$acl)}
    $after=Get-CoursePodmanKeyPermissions $Path
    if(-not $after.safe -or (Get-FileHash -LiteralPath $Path).Hash -cne $digest){throw 'PODMAN_SSH_PRIVATE_KEY_REPAIR_UNVERIFIED'}
    return [pscustomobject]@{changed=$true;keyBytesPreserved=$true;beforeSddl=$before.sddl;afterSddl=$after.sddl}
}
function Get-CourseSshPublicFingerprint([string]$PublicKey) {
    $parts=$PublicKey.Trim() -split '\s+'
    if($parts.Count -lt 2 -or $parts[0] -notmatch '^(ssh-|ecdsa-)'){throw 'PODMAN_SSH_PUBLIC_KEY_INVALID'}
    try{$bytes=[Convert]::FromBase64String($parts[1])}catch{throw 'PODMAN_SSH_PUBLIC_KEY_INVALID'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return 'SHA256:'+([Convert]::ToBase64String($hash.ComputeHash($bytes)).TrimEnd('='))}finally{$hash.Dispose()}
}
function Test-CoursePodmanSshIdentity($MachineInfo,$Connection,[switch]$Repair,[string]$EvidenceDirectory) {
    $binding=Assert-CoursePodmanSshBinding $MachineInfo $Connection
    $permissions=Get-CoursePodmanKeyPermissions $binding.identity
    $repaired=$false
    if(-not $permissions.safe){
        if(-not $Repair){throw 'PODMAN_SSH_PRIVATE_KEY_PERMISSIONS: run environment Prepare to repair the selected private key ACL.'}
        if(-not $EvidenceDirectory){throw 'PODMAN_SSH_REPAIR_EVIDENCE_REQUIRED'}
        if(-not $permissions.ownerMatches){throw 'PODMAN_SSH_PRIVATE_KEY_OWNER_MISMATCH'}
        Assert-CoursePlainPath $EvidenceDirectory
        # Record ACL metadata before mutation. Never copy/log the private key.
        $backup=Join-Path $EvidenceDirectory ('ssh-acl-before-'+[guid]::NewGuid().ToString('N')+'.json')
        Write-CourseJson $backup @{identity=$binding.identity;sddl=$permissions.sddl;machine=$binding.machine;checkedAt=[datetimeoffset]::UtcNow.ToString('o')}
        $result=Repair-CoursePodmanKeyPermissions $binding.identity;$repaired=$result.changed
    }
    $keygen=Join-Path (Get-CourseWindowsOpenSshDirectory) 'ssh-keygen.exe'
    $public=Invoke-SetupNative $keygen @('-y','-P','','-f',$binding.identity) 15
    if($public.ExitCode -ne 0){throw 'PODMAN_SSH_PRIVATE_KEY_READ_FAILED: inspect key format/passphrase separately from server authorization.'}
    $text=if($public.Stdout){$public.Stdout}else{$public.Output}
    $fingerprint=Get-CourseSshPublicFingerprint $text
    $publicPath=$binding.identity+'.pub'
    if(Test-Path -LiteralPath $publicPath){
        Assert-CoursePlainPath $publicPath
        if((Get-CourseSshPublicFingerprint ([IO.File]::ReadAllText($publicPath))) -cne $fingerprint){throw 'PODMAN_SSH_KEYPAIR_MISMATCH: preserve both files; do not regenerate or replace guest authorizations automatically.'}
    }
    return [pscustomobject]@{status='verified';machine=$binding.machine;connection=$binding.connection;username=$binding.username;identity=$binding.identity;fingerprint=$fingerprint;permissionsRepaired=[bool]$repaired;keyBytesPreserved=$true;serverAuthorization='not-checked';checkedAt=[datetimeoffset]::UtcNow.ToString('o')}
}

function New-CoursePodmanRootKeyScript([string]$PublicKey,[string]$OperationId) {
    # Only a derived public key enters Linux; no paths/commands from user input.
    $parts=$PublicKey.Trim() -split '\s+'
    if($parts.Count -lt 2 -or $parts[0] -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$' -or $parts[1] -notmatch '^[A-Za-z0-9+/]+={0,2}$' -or $OperationId -notmatch '^[a-f0-9]{32}$'){throw 'PODMAN_SSH_PUBLIC_KEY_INVALID'}
    $null=Get-CourseSshPublicFingerprint $PublicKey
    $script=@'
set -eu
test ! -L /root
test ! -L /root/.ssh
test ! -L /root/.ssh/authorized_keys
test ! -e /root/.ssh || test -d /root/.ssh
test ! -e /root/.ssh/authorized_keys || test -f /root/.ssh/authorized_keys
umask 077
mkdir -p /root/.ssh
test "$(stat -c %u /root/.ssh)" = 0
test ! -e /root/.ssh/authorized_keys || test "$(stat -c %u /root/.ssh/authorized_keys)" = 0
test ! -L /root/.ssh/.ai-coding-authorization.lock
exec 9>/root/.ssh/.ai-coding-authorization.lock
flock -w 10 9
if test -f /root/.ssh/authorized_keys && awk -v t='__TYPE__' -v k='__KEY__' '{for(i=1;i<NF;i++)if($i==t && $(i+1)==k)found=1}END{exit !found}' /root/.ssh/authorized_keys; then
  echo ALREADY_AUTHORIZED
  exit 0
fi
backup=/root/.ssh/authorized_keys.course-before-__ID__
test ! -e "$backup"
if test -f /root/.ssh/authorized_keys; then cp -p /root/.ssh/authorized_keys "$backup"; fi
tmp=$(mktemp /root/.ssh/.authorized_keys.course.XXXXXX)
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if test -f /root/.ssh/authorized_keys; then cat /root/.ssh/authorized_keys > "$tmp"; fi
printf '\n%s %s ai-coding-podman\n' '__TYPE__' '__KEY__' >> "$tmp"
chmod 700 /root/.ssh
chmod 600 "$tmp"
mv -f "$tmp" /root/.ssh/authorized_keys
echo ADDED
'@
    return ($script.Replace('__TYPE__',$parts[0]).Replace('__KEY__',$parts[1]).Replace('__ID__',$OperationId).Replace("`r`n","`n")+"`n")
}

function Invoke-CoursePodmanAccountProbe($Binding,[string]$Username) {
    if($Username -notmatch '^[a-z_][a-z0-9_-]*$'){throw 'PODMAN_SSH_MACHINE_METADATA_INVALID'}
    # Podman machine ssh may prompt on authentication failure. Probe the exact
    # recorded loopback endpoint with one identity, no agent/config or prompts.
    $ssh=Join-Path (Get-CourseWindowsOpenSshDirectory) 'ssh.exe'
    return Invoke-SetupNative $ssh @('-F','NUL','-T','-n','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','ConnectTimeout=5','-p',[string]$Binding.port,'-i',$Binding.identity,($Username+'@127.0.0.1'),'true') 10
}

function Test-CoursePodmanRootAuthorization($MachineInfo,$Connection,[string]$Cli,[switch]$Repair,[string]$EvidenceDirectory) {
    $binding=Assert-CoursePodmanSshBinding $MachineInfo $Connection
    # This recovery is specific to Podman's local WSL provider, not other VMs.
    if(-not $MachineInfo.ConfigDir -or (Split-Path $MachineInfo.ConfigDir.Path -Leaf) -ine 'wsl'){return [pscustomobject]@{status='not-applicable';repaired=$false}}
    $probe=Invoke-CoursePodmanAccountProbe $binding 'root'
    if($probe.ExitCode -eq 0){return [pscustomobject]@{status='verified';repaired=$false}}
    if(-not $Repair){throw 'PODMAN_SSH_ROOT_AUTHORIZATION_REQUIRED: WSL startup also uses root SSH; run environment Prepare to verify and synchronize the existing public key.'}
    if($probe.Output -notmatch '(?i)unable to authenticate|Permission denied.*publickey|handshake.*failed'){throw 'PODMAN_SSH_ROOT_UNAVAILABLE: inspect root SSH transport/service; no authorization changed.'}
    if(-not $EvidenceDirectory){throw 'PODMAN_SSH_REPAIR_EVIDENCE_REQUIRED'}
    Assert-CoursePlainPath $EvidenceDirectory
    $user=[string]$MachineInfo.SSHConfig.RemoteUsername
    if($user -eq 'root'){throw 'PODMAN_SSH_ROOT_RECOVERY_USER_REQUIRED'}
    # Prove this same identity is already authorized by the recorded machine user.
    $userProbe=Invoke-CoursePodmanAccountProbe $binding $user
    if($userProbe.ExitCode -ne 0){throw 'PODMAN_SSH_USER_AUTHORIZATION_FAILED: preserve keys; root synchronization requires the original user connection.'}
    $public=Invoke-SetupNative (Join-Path (Get-CourseWindowsOpenSshDirectory) 'ssh-keygen.exe') @('-y','-P','','-f',$binding.identity) 15
    if($public.ExitCode -ne 0){throw 'PODMAN_SSH_PRIVATE_KEY_READ_FAILED'}
    $text=if($public.Stdout){$public.Stdout}else{$public.Output}
    $id=[guid]::NewGuid().ToString('N');$fingerprint=Get-CourseSshPublicFingerprint $text
    $script=New-CoursePodmanRootKeyScript $text $id
    $path=Join-Path $EvidenceDirectory ('ssh-root-authorization-'+$id+'.json')
    $evidence=@{machine=$binding.machine;user=$user;fingerprint=$fingerprint;status='planned';backupPath=('/root/.ssh/authorized_keys.course-before-'+$id);privateKeyChanged=$false;checkedAt=[datetimeoffset]::UtcNow.ToString('o')}
    Write-CourseJson $path $evidence
    $wsl=Join-Path $env:SystemRoot 'System32\wsl.exe'
    $sync=Invoke-SetupNative $wsl @('--distribution',$binding.machine,'--user','root','--exec','sh','-s') 20 -InputText $script
    if($sync.ExitCode -ne 0){$evidence.status='sync-failed';Write-CourseJson $path $evidence;throw 'PODMAN_SSH_ROOT_SYNC_FAILED: inspect the original WSL account/files; backup and original keys preserved.'}
    $recheck=Invoke-CoursePodmanAccountProbe $binding 'root'
    $evidence.status=if($recheck.ExitCode -eq 0){'verified'}else{'authorization-unverified'}
    $evidence.repaired=($sync.Stdout.Trim() -eq 'ADDED');Write-CourseJson $path $evidence
    if($recheck.ExitCode -ne 0){throw 'PODMAN_SSH_ROOT_AUTHORIZATION_UNVERIFIED: public key synchronization did not restore root SSH; inspect sshd policy, do not retry or regenerate keys.'}
    return [pscustomobject]@{status='verified';repaired=$evidence.repaired;fingerprint=$fingerprint;evidence=$path;backupPath=$evidence.backupPath}
}
