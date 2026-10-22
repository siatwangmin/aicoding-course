#Requires -Version 5.1
# Read-only diagnostics: no network calls, credential access or trust-store changes.
function ConvertTo-CourseBackgroundTime($Value) {
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){throw 'BACKGROUND_TIME_REQUIRED'}
    if($Value -is [datetimeoffset]){return $Value.ToUniversalTime()}
    if($Value -is [datetime]){return ([datetimeoffset]$Value).ToUniversalTime()}
    return [datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Test-CourseBackgroundProcess($ProcessId,$StartedAt) {
    if(-not $ProcessId -or -not $StartedAt){return $false}
    try {
        $process=Get-Process -Id $ProcessId -ErrorAction Stop
        return (ConvertTo-CourseBackgroundTime $process.StartTime) -eq (ConvertTo-CourseBackgroundTime $StartedAt)
    }catch{return $false}
}
function Get-CourseFailureClass([string]$Text) {
    if($Text -match '(?i)x509:|unknown authority|unable to verify the first certificate|unable to get local issuer|UNABLE_TO_VERIFY_LEAF_SIGNATURE|UNABLE_TO_GET_ISSUER_CERT_LOCALLY|SELF_SIGNED_CERT_IN_CHAIN|DEPTH_ZERO_SELF_SIGNED_CERT|CERT_HAS_EXPIRED|CERT_UNTRUSTED|certificate verify failed|self[- ]signed certificate'){return 'CertificateTrust'}
    if($Text -match '(?i)proxy authentication|(?:HTTP(?:/\d(?:\.\d)?)?|status(?: code)?)\s*[:=]?\s*407\b'){return 'ProxyAuthentication'}
    if($Text -match '(?i)no such host|could not resolve|name resolution|ENOTFOUND|EAI_AGAIN'){return 'NameResolution'}
    if($Text -match '(?i)checksum.*mismatch|digest.*mismatch|sha256.*mismatch|HASH_MISMATCH'){return 'IntegrityMismatch'}
    if($Text -match '(?i)timed out|timeout|ETIMEDOUT'){return 'NetworkTimeout'}
    return 'NeedsDiagnosis'
}
function Get-CourseFailureAdvice([string]$Class) {
    switch($Class){
        CertificateTrust {'Check the exact host, Node or machine trust chain and verified CA; do not disable TLS or import all roots.'}
        ProxyAuthentication {'Check the current proxy authentication and preserve organization settings.'}
        NameResolution {'Check DNS and the selected endpoint; preserve verified cache.'}
        NetworkTimeout {'Check endpoint reachability and actual transfer state; phase time alone is not download speed.'}
        IntegrityMismatch {'Reject the artifact and verify its fixed source/hash; do not bypass integrity checks.'}
        default {'Read the first error in this phase and preserve completed account/tool work.'}
    }
}
function Add-CoursePreparationAdvice($State,[string]$Workspace) {
    $class=$null
    $attentionRequired=$State.status -in @('NotStarted','Failed','Interrupted','RestartRequired','Verified','ChildRunning') -or [bool]$State.attention
    $next='Continue available foreground work; check background state after each action and during waits.'
    if($State.status -eq 'Failed'){
        $sample=''
        if($State.taskId -match '^[a-f0-9]{32}$' -and $State.phase -match '^[a-zA-Z][a-zA-Z0-9]*$'){
            foreach($suffix in @('.log','.error.log')){
                $path=Join-Path $Workspace ('.course-setup/'+$State.taskId+'-'+$State.phase+$suffix)
                Assert-CoursePlainPath $path
                if(Test-Path -LiteralPath $path -PathType Leaf){$sample+=((Get-Content -LiteralPath $path -Tail 80 -ErrorAction SilentlyContinue)-join "`n")}
            }
        }
        $class=Get-CourseFailureClass $sample
        $next=Get-CourseFailureAdvice $class
    }elseif($State.status -eq 'Verified'){
        $next='Continue real tools evidence, service registration and summary; tool readiness is not full preparation or user acceptance.'
    }elseif($State.status -eq 'RestartRequired'){
        $next='Preserve progress and let the user choose restart; do not start another installer.'
    }elseif($State.status -in @('Interrupted','ChildRunning')){
        $next='Check the recorded worker/child identity before resuming; do not duplicate a live installer.'
    }elseif($State.status -eq 'NotStarted'){$next='Start tools only within the current preparation scope.'}
    $age=$null;$stale=$false
    if($State.heartbeatAt){
        try{$age=[math]::Round(([datetimeoffset]::UtcNow-(ConvertTo-CourseBackgroundTime $State.heartbeatAt)).TotalSeconds,1);$stale=$age -lt 0 -or $age -gt 45}catch{$stale=$true}
        if($stale -and $State.status -in @('Running','Starting')){
            $attentionRequired=$true
            $next='Heartbeat is stale; inspect the recorded process and phase log. A live process does not prove transfer progress.'
        }
    }
    foreach($pair in @(@('failureClass',$class),@('actionRequired',[bool]$attentionRequired),@('recommendedAction',$next),@('heartbeatAgeSeconds',$age),@('heartbeatStale',$stale))){
        $State|Add-Member -MemberType NoteProperty -Name $pair[0] -Value $pair[1] -Force
    }
    return $State
}
