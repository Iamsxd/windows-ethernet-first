$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('ef-persistence-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'baseline.json'
try {
    Write-AtomicJson $path @{version='original'}
    [IO.File]::WriteAllText(($path+'.tmp'),'{}')
    # Allow writing the replacement but deny renaming it. A failed replacement
    # must never delete the sole original before discovering this OS failure.
    $hold=[IO.File]::Open(($path+'.tmp'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $failed=$false
        try { Write-AtomicJson $path @{version='new'} } catch { $failed=$true }
        if (-not $failed) { throw 'Fixture did not block the replacement rename' }
        if (-not (Test-Path -LiteralPath $path)) { throw 'Failed atomic replacement destroyed the original recovery baseline' }
        if ((Get-Content $path -Raw | ConvertFrom-Json).version -ne 'original') { throw 'Failed replacement changed the original baseline' }
    } finally { $hold.Dispose() }
    Write-AtomicJson $path @{version='new'}
    if ((Get-Content $path -Raw | ConvertFrom-Json).version -ne 'new') { throw 'Successful replacement did not publish valid JSON' }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class BaselineReader : IDisposable {
    readonly CancellationTokenSource stop=new CancellationTokenSource();
    readonly Task job;
    public int Missing;
    public BaselineReader(string path) {
        job=Task.Run(() => {
            while(!stop.IsCancellationRequested) {
                try { using(var file=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) { file.ReadByte(); } }
                catch(FileNotFoundException) { Interlocked.Increment(ref Missing); }
                // Replacement can briefly deny new opens; retry those. The
                // pathname itself must never disappear between delete and move.
                catch(UnauthorizedAccessException) { }
                catch(IOException) { }
            }
        });
    }
    public void Dispose() { stop.Cancel(); job.GetAwaiter().GetResult(); stop.Dispose(); }
}
'@
    $reader=[BaselineReader]::new($path)
    try {
        for ($i=0; $i -lt 150; $i++) { Write-AtomicJson $path @{version=$i} }
    } finally { $reader.Dispose() }
    if ($reader.Missing -ne 0) { throw 'Concurrent readers observed the recovery baseline disappearing during overwrite' }
    Write-Output 'PASS: 5 persistence assertions. No network settings changed.'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
