# Convert one completed DISPLAYD /RECEIVERS /RAW transcript without device I/O.
# Bad EDID checksums are evidence and remain byte-identical in the export.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TranscriptPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputFile = Get-Item -LiteralPath $TranscriptPath
if ($inputFile.Length -gt 8MB) { throw 'Receiver transcript exceeds the bounded capture size' }
$transcriptBytes = [IO.File]::ReadAllBytes($inputFile.FullName)
if ($transcriptBytes.Length -gt 8MB) { throw 'Receiver transcript grew beyond the bounded capture size' }
$text = [Text.Encoding]::UTF8.GetString($transcriptBytes).TrimStart([char]0xfeff)
$records = [Collections.Generic.List[object]]::new()
$catalog = $null
$info = $null
$capture = $null
$complete = $false
$seen = 0
foreach ($line in ($text -split '\r?\n')) {
    if ($line -match '^DISPLAYD receivers: revision=(\d+) count=(\d+)$') {
        if ($null -ne $catalog -or [uint64]$Matches[2] -gt 64) { throw 'Multiple or oversized catalogs' }
        $catalog = [ordered]@{ revision = [uint64]$Matches[1]; count = [uint32]$Matches[2] }
    } elseif ($line -match '^  adapter=(\d+) port=(\d+) device-generation=(\d+) receiver-generation=(\d+) kind=(\S+) flags=(\d+) source=(\S+) modes=\d+ edid-bytes=(\d+)$') {
        if ($null -eq $catalog -or $complete -or $null -ne $capture -or
            ($null -ne $info -and $info.bytes -ne 0)) { throw 'Missing EDID export or catalog header' }
        $info = [ordered]@{ adapter = [uint32]$Matches[1]; port = [uint32]$Matches[2]; device = [uint64]$Matches[3]
            receiver = [uint64]$Matches[4]; kind = $Matches[5]; flags = [uint32]$Matches[6]
            source = $Matches[7]; bytes = [uint32]$Matches[8] }
        $seen++
        if ($seen -gt $catalog.count -or $info.bytes -gt 4096 -or $info.bytes % 128 -ne 0) { throw 'Invalid catalog extent' }
    } elseif ($line -match '^DISPLAYD EDID begin adapter=(\d+) port=(\d+) device=(\d+) receiver=(\d+) revision=(\d+) bytes=(\d+) flags=(\d+)$') {
        if ($null -eq $info -or $null -ne $capture -or $complete -or $info.bytes -eq 0 -or
            [uint32]$Matches[1] -ne $info.adapter -or [uint32]$Matches[2] -ne $info.port -or
            [uint64]$Matches[3] -ne $info.device -or [uint64]$Matches[4] -ne $info.receiver -or
            [uint64]$Matches[5] -ne $catalog.revision -or [uint32]$Matches[6] -ne $info.bytes -or
            [uint32]$Matches[7] -ne $info.flags) { throw 'Mismatched EDID identity or generation' }
        $capture = [ordered]@{ info = $info; data = [Collections.Generic.List[byte]]::new()
            blocks = [Collections.Generic.List[object]]::new() }
    } elseif ($line -match '^DISPLAYD EDID block=(\d+) checksum=([0-9a-f]{2}) tag=([0-9a-f]{2})$') {
        if ($null -eq $capture -or [uint32]$Matches[1] -ne $capture.blocks.Count -or
            $capture.data.Count -ne 128 * $capture.blocks.Count -or $capture.data.Count -ge $info.bytes) { throw 'Missing or repeated EDID block' }
        $capture.blocks.Add([ordered]@{ index = [uint32]$Matches[1]
            checksum = [Convert]::ToByte($Matches[2], 16); tag = [Convert]::ToByte($Matches[3], 16) })
    } elseif ($line -match '^DISPLAYD EDID data=([0-9a-f]{4}):([0-9a-f]{64})$') {
        if ($null -eq $capture -or [Convert]::ToUInt32($Matches[1], 16) -ne $capture.data.Count -or
            $capture.data.Count + 32 -gt $info.bytes -or $capture.blocks.Count -ne 1 + [Math]::Floor($capture.data.Count / 128)) {
            throw 'Truncated, reordered or unbounded EDID data'
        }
        $capture.data.AddRange([Convert]::FromHexString($Matches[2]))
    } elseif ($line -match '^DISPLAYD EDID end bytes=(\d+) sha256=([0-9a-f]{64})$') {
        if ($null -eq $capture -or [uint32]$Matches[1] -ne $info.bytes -or $capture.data.Count -ne $info.bytes) { throw 'Incomplete EDID' }
        $bytes = $capture.data.ToArray()
        $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($sha -cne $Matches[2]) { throw 'EDID transcript SHA-256 mismatch' }
        foreach ($block in $capture.blocks) {
            $offset = 128 * $block.index
            $sum = 0
            for ($i = 0; $i -lt 128; $i++) { $sum = ($sum + $bytes[$offset + $i]) -band 255 }
            if ($sum -ne $block.checksum -or $bytes[$offset] -ne $block.tag) { throw 'EDID block metadata mismatch' }
        }
        $name = 'adapter-{0}-port-{1}-device-{2}-receiver-{3}.bin' -f $info.adapter, $info.port, $info.device, $info.receiver
        if (@($records | Where-Object { $_.metadata.file -ceq $name }).Count) { throw 'Duplicate receiver identity' }
        $metadata = [ordered]@{ file = $name; adapter = $info.adapter; port = $info.port; device_generation = $info.device
            receiver_generation = $info.receiver; kind = $info.kind; source = $info.source; flags = $info.flags
            bytes = $bytes.Length; sha256 = $sha; declared_blocks = 1 + [int]$bytes[126]
            captured_blocks = $capture.blocks.Count; blocks = @($capture.blocks.ToArray()) }
        $records.Add(@{ metadata = $metadata; bytes = $bytes })
        $capture = $null
        $info = $null
    } elseif ($line -ceq 'DISPLAYD receivers: complete hardware-writes=none') {
        if ($null -eq $catalog -or $complete -or $null -ne $capture -or $seen -ne $catalog.count -or
            ($null -ne $info -and $info.bytes -ne 0)) { throw 'Incomplete catalog capture' }
        $complete = $true
    } elseif ($line.StartsWith('DISPLAYD EDID ', [StringComparison]::Ordinal) -or
        $line.StartsWith('DISPLAYD receivers:', [StringComparison]::Ordinal)) {
        throw 'Failed, changed or malformed receiver capture'
    }
}
if (!$complete -or $null -ne $capture) { throw 'Missing final coherent catalog marker; discard partial bytes' }
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $destination) { throw 'Choose a new output directory to preserve existing evidence' }
$null = [IO.Directory]::CreateDirectory($destination)
function Write-NewFile([string]$Name, [byte[]]$Bytes) {
    $stream = [IO.File]::Open((Join-Path $destination $Name), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}
foreach ($record in $records) { Write-NewFile $record.metadata.file $record.bytes }
Write-NewFile 'transcript.txt' $transcriptBytes
$result = [ordered]@{ schema = 1; catalog_revision = $catalog.revision; catalog_count = $catalog.count
    exported_receivers = $records.Count; scope = 'Unchanged shared-catalog bytes; freshness of physical bus acquisition is not inferred'
    transcript_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($transcriptBytes)).ToLowerInvariant()
    receivers = @($records | ForEach-Object { $_.metadata }) }
Write-NewFile 'capture.json' ([Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Depth 8) + "`n"))
Write-Output ('Receiver capture exported: revision={0} receivers={1} path={2}' -f $catalog.revision, $records.Count, $destination)
