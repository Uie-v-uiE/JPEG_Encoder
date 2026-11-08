# board_capture.ps1 -- open COM @115200, JTAG-program the KU5P (restarts the
# demo), capture the entropy bytes, compare byte-exact with the golden scan.
$ErrorActionPreference = 'Stop'
$root    = 'D:\Xilinx\Harness\Project\new_prj\k5p-jpeg-encoder'
$bit     = "$root\build\jpeg_board\jpeg_board.runs\impl_1\jpeg_demo_board.bit"
$goldF   = "$root\vectors\gold_flat64_scan.hex"
$vivado  = 'D:\Software\Vivado\2025.2.1\Vivado\bin\vivado.bat'
$progTcl = "$root\scripts\prog_ku5p.tcl"

$gold = Get-Content $goldF | Where-Object { $_.Trim() } | ForEach-Object { [Convert]::ToByte($_, 16) }
Write-Host ("golden bytes: {0}" -f $gold.Count)

$ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
Write-Host ("ports: {0}" -f ($ports -join ', '))
$port = $ports[-1]
Write-Host ("using: {0}" -f $port)

$ser = New-Object System.IO.Ports.SerialPort $port, 115200, None, 8, One
$ser.ReadTimeout = 200
$ser.Open()
$ser.DiscardInBuffer()

# program via JTAG (reconfiguration restarts the demo FSM)
& $vivado -mode batch -source $progTcl 2>&1 | Out-Null
$progOk = $LASTEXITCODE -eq 0
Write-Host ("program exit0: {0}" -f $progOk)

# capture ~5 s
$data = New-Object System.Collections.Generic.List[byte]
$buf  = New-Object byte[] 256
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 5) {
    try {
        $n = $ser.Read($buf, 0, $buf.Length)
        for ($i = 0; $i -lt $n; $i++) { $data.Add($buf[$i]) }
    } catch [TimeoutException] {}
}
$ser.Close()

Write-Host ("captured bytes: {0}" -f $data.Count)
$dataHex = ($data | ForEach-Object { $_.ToString('x2') })
Write-Host ("first 8: {0}" -f (($dataHex | Select-Object -First 8) -join ' '))
Write-Host ("last  8: {0}" -f (($dataHex | Select-Object -Last 8) -join ' '))

if ($data.Count -lt $gold.Count) {
    Write-Host ("RESULT: FAIL (short {0} < {1})" -f $data.Count, $gold.Count)
} elseif ($data.Count -gt $gold.Count) {
    Write-Host ("RESULT: FAIL (extra {0} > {1})" -f $data.Count, $gold.Count)
} else {
    $mis = 0; $first = $null
    for ($i = 0; $i -lt $gold.Count; $i++) {
        if ($data[$i] -ne $gold[$i]) { $mis++; if ($null -eq $first) { $first = $i } }
    }
    if ($mis -eq 0) { Write-Host ("RESULT: PASS -- {0} bytes byte-exact" -f $gold.Count) }
    else { Write-Host ("RESULT: FAIL ({0} mismatches, first at {1})" -f $mis, $first) }
}
