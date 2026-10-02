# Deployed to the bin directory; the real script lives in text-tools\ beside it.
#
# Do not use $input here: merely referencing it makes a -File host drain
# redirected stdin, which the real script reads itself. Under -File, Line is
# empty, so only genuine in-session pipeline input is collected and forwarded.
begin {
    $target = Join-Path $PSScriptRoot 'text-tools\kana.ps1'
    $piped = $MyInvocation.ExpectingInput -and $MyInvocation.Line
    $items = [Collections.Generic.List[object]]::new()
}
process {
    if ($piped) {
        $items.Add($_)
    }
}
end {
    if ($piped) {
        $items | & $target @args
    } else {
        & $target @args
    }
    exit $LASTEXITCODE
}
