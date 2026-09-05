param([Parameter(ValueFromRemainingArguments=$true)][string[]]$BuildArguments=@())
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
    $settings=@{}
    foreach($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'Settings.R4S'))){
        if($line.StartsWith('#') -or !$line.Contains('=')){continue}
        $key,$value=$line.Split('=',2);$settings[$key.Trim()]=$value.Trim()
    }
    function Resolve-Setting([string]$Key,[string]$Base=$PSScriptRoot){
        if(!$settings.ContainsKey($Key) -or !$settings[$Key]){throw "Missing setting: $Key"}
        if([IO.Path]::IsPathRooted($settings[$Key])){return [IO.Path]::GetFullPath($settings[$Key])}
        return [IO.Path]::GetFullPath((Join-Path $Base $settings[$Key]))
    }
    $sdk=Resolve-Setting 'SDK_ROOT';$contract=Resolve-Setting 'CONTRACT_ROOT'
    $devkit=Resolve-Setting 'DEVKIT_ROOT';$output=Resolve-Setting 'ARTIFACTS_ROOT'
    $zig=Join-Path (Resolve-Setting 'ZIG_ROOT' $devkit) $(if($IsWindows){'zig.exe'}else{'zig'})
    foreach($path in @($zig,(Join-Path $sdk 'build.zig.zon'),(Join-Path $contract 'build.zig.zon'))){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing build input: $path"}
    }
    Push-Location $PSScriptRoot
    try{& $zig build --prefix $output "--fork=$sdk" "--fork=$contract" @BuildArguments;exit $LASTEXITCODE}
    finally{Pop-Location}
}catch{Write-Error $_ -ErrorAction Continue;exit 1}
