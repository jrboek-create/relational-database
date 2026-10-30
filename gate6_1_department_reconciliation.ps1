        "|controlled_test_exceptions=2" +
        "|unmapped=0" +
        "|duplicate=0" +
        "|conflicting=0" +
        "|distinct_acad_org=$($distinctOrgs.Count)" +
        "|distinct_departments=$($distinctDepts.Count)" +
        "|source_mode=$sourceMode" +
        "|sources=$($sources.Count)" +
        "|department_filter_enabled=false" +
        "|runtime_mutated=false" +
        "|sha256sums=$sumHash"
    )
}
catch {

    if (
        $created `
        -and `
        (Test-Path -LiteralPath $dir)
    ) {
        Remove-Item `
            -LiteralPath $dir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Output (
        "FAIL|GATE6_1_TASK_6_1_3" +
        "|partial_package_removed=$created" +
        "|department_filter_enabled=false" +
        "|runtime_mutated=false" +
        "|reason=$($_.Exception.Message)"
    )
}
finally {

    if ($null -ne $workbook) {

        try {
            $workbook.Close($false)
        }
        catch {
        }

        try {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject(
                $workbook
            )
        }
        catch {
        }
    }

    if ($null -ne $excel) {

        try {
            $excel.Quit()
        }
        catch {
        }

        try {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject(
                $excel
            )
        }
        catch {
        }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}