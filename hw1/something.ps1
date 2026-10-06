$files = "hw1\src\render\pbr.odin", "hw1\resource\shaders\no_light.frag"
foreach ($f in $files) {
    $t = [System.IO.File]::ReadAllText($f)
    $t = $t -replace "`r`n", "`n" -replace "`n", "`r`n"     # 先归一成 LF，再全部转 CRLF
    [System.IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding $false))
}
