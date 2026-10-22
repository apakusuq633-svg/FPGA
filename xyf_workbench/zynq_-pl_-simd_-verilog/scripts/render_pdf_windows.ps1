param([Parameter(Mandatory=$true)][string]$PdfPath,
      [Parameter(Mandatory=$true)][string]$OutputDirectory,
      [uint32]$Width=3200)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
$null=[Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
$null=[Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
$null=[Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]
$asyncMethod=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
} | Select-Object -First 1
function Await-Result($Operation,$ResultType) {
    $task=$asyncMethod.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    $task.Wait()
    return $task.Result
}
$actionMethod=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and !$_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
} | Select-Object -First 1
$file=Await-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path -LiteralPath $PdfPath).Path)) ([Windows.Storage.StorageFile])
$pdf=Await-Result ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Write-Output "PDF_PAGES=$($pdf.PageCount)"
for ($i=0;$i -lt $pdf.PageCount;$i++) {
    $page=$pdf.GetPage($i)
    $stream=New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $options=New-Object Windows.Data.Pdf.PdfPageRenderOptions
    $options.DestinationWidth=$Width
    $action=$page.RenderToStreamAsync($stream,$options)
    $task=$actionMethod.Invoke($null,@($action));$task.Wait()
    $reader=New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
    $count=Await-Result ($reader.LoadAsync([uint32]$stream.Size)) ([uint32])
    $bytes=New-Object byte[] $count
    $reader.ReadBytes($bytes)
    $target=Join-Path $OutputDirectory ('page{0}.png' -f ($i+1))
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($target),$bytes)
    Write-Output $target
    $reader.Dispose();$stream.Dispose();$page.Dispose()
}
