Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Source = 'C:\Directus\relational-repository\imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls'
$ExpectedBytes = 7435264
$ExpectedHash = '91FEA403B0BCCA8CC746EC28723C576A4D05204E1F1C9D8D7D16D451DB2A7D09'

$Excel = $null
$Book = $null
$Sheet = $null
$Range = $null

try {
    Write-Host "`n=== COLLEGE/DEPARTMENT RECONCILIATION - READ ONLY ==="

    $File = Get-Item -LiteralPath $Source -ErrorAction Stop
    $Hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash

    if ($File.Length -ne $ExpectedBytes) { throw 'SOURCE_BYTE_COUNT_MISMATCH' }
    if ($Hash -ne $ExpectedHash) { throw 'SOURCE_SHA256_MISMATCH' }

    $Excel = New-Object -ComObject Excel.Application
    $Excel.Visible = $false
    $Excel.DisplayAlerts = $false
    $Excel.AskToUpdateLinks = $false
    $Excel.AutomationSecurity = 3

    $Book = $Excel.Workbooks.Open($Source, 0, $true)
    $Sheet = $Book.Worksheets.Item(1)
    $Range = $Sheet.UsedRange
    $Values = $Range.Value2

    $Headers = @(
        ([string]$Values.GetValue(2,1)).Trim()
        ([string]$Values.GetValue(2,2)).Trim()
        ([string]$Values.GetValue(2,50)).Trim()
        ([string]$Values.GetValue(2,51)).Trim()
    )

    if ($Headers[0] -ne 'Univ Course ID' -or
        $Headers[1] -ne 'Eff Date' -or
        $Headers[2] -ne 'WW Owner(s)' -or
        $Headers[3] -ne 'WW College(s)') {
        throw "SOURCE_HEADER_MISMATCH: $($Headers -join ' | ')"
    }

    $Latest = @{}
    $RowsById = @{}
    $InvalidDates = 0

    for ($Row = 3; $Row -le [int]$Range.Rows.Count; $Row++) {
        $RawId = $Values.GetValue($Row,1)
        if ($null -eq $RawId) { continue }

        if ($RawId -is [double]) {
            $Id = ([int64]$RawId).ToString()
        } else {
            $Id = ([string]$RawId).Trim()
        }

        if ($Id.Length -eq 0) { continue }

        $RawDate = $Values.GetValue($Row,2)
        $Ticks = [int64]0

        if ($RawDate -is [double]) {
            $Ticks = [datetime]::FromOADate([double]$RawDate).Ticks
        } else {
            $ParsedDate = [datetime]::MinValue
            if ([datetime]::TryParse([string]$RawDate, [ref]$ParsedDate)) {
                $Ticks = $ParsedDate.Ticks
            } else {
                $InvalidDates++
            }
        }

        $Department = ([string]$Values.GetValue($Row,50)).Trim()
        $College = ([string]$Values.GetValue($Row,51)).Trim()
        $Pair = $Department + [char]31 + $College

        if (-not $RowsById.ContainsKey($Id)) { $RowsById[$Id] = 0 }
        $RowsById[$Id]++

        if (-not $Latest.ContainsKey($Id) -or $Ticks -gt $Latest[$Id].Ticks) {
            $Latest[$Id] = [pscustomobject]@{
                Ticks = $Ticks
                Pairs = @{ $Pair = $true }
            }
        } elseif ($Ticks -eq $Latest[$Id].Ticks) {
            $Latest[$Id].Pairs[$Pair] = $true
        }
    }

    $Sql = @'
BEGIN TRANSACTION READ ONLY;

WITH college AS (
    SELECT
        course_id,
        MIN(NULLIF(BTRIM(college_name),'')) AS college_name,
        COUNT(DISTINCT NULLIF(BTRIM(college_name),'')) AS college_count
    FROM reporting.course_catalog_detail
    GROUP BY course_id
)
SELECT
    catalog.course_id::text,
    BTRIM(catalog.university_course_id),
    REPLACE(COALESCE(college.college_name,''),'|','/'),
    COALESCE(college.college_count,0)::text
FROM reporting.course_current_catalog AS catalog
LEFT JOIN college ON college.course_id = catalog.course_id
WHERE NULLIF(BTRIM(catalog.university_course_id),'') IS NOT NULL
ORDER BY catalog.course_id;

ROLLBACK;
'@

    $OldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $RawDb = @()
    $ExitCode = -1

    try {
        $RawDb = @(
            $Sql | docker compose exec -T database psql `
                -X -q -v ON_ERROR_STOP=1 -P pager=off `
                -A -t -F '|' `
                -U directus_repository -d directus_repository 2>&1
        )
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }

    if ($ExitCode -ne 0) {
        throw "READ_ONLY_DATABASE_QUERY_FAILED: $($RawDb -join [Environment]::NewLine)"
    }

    $Catalog = @()
    $CatalogIds = @{}

    foreach ($Line in $RawDb) {
        $Parts = ([string]$Line).Trim() -split '\|', 4
        if ($Parts.Count -ne 4) { continue }

        $Catalog += [pscustomobject]@{
            CourseId        = $Parts[0]
            Id              = $Parts[1]
            ReportingCollege = $Parts[2]
            CollegeCount    = [int]$Parts[3]
        }

        $CatalogIds[$Parts[1]] = $true
    }

    if ($Catalog.Count -eq 0) {
        throw 'NO_CURRENT_CATALOG_ROWS_RETURNED'
    }

    $DepartmentMatched = 0
    $DepartmentUnmatched = 0
    $CollegeMatched = 0
    $CollegeUnmatched = 0
    $CombinedMatched = 0
    $AmbiguousRows = 0
    $CollegeComparable = 0
    $CollegeAgreement = 0
    $CollegeDisagreement = 0

    foreach ($Course in $Catalog) {
        if (-not $Latest.ContainsKey($Course.Id)) {
            $DepartmentUnmatched++
            $CollegeUnmatched++
            continue
        }

        $Entry = $Latest[$Course.Id]

        if ($Entry.Pairs.Count -gt 1) {
            $AmbiguousRows++
            continue
        }

        $Pair = [string]($Entry.Pairs.Keys | Select-Object -First 1)
        $Fields = $Pair -split [regex]::Escape([string][char]31), 2
        $Department = $Fields[0]
        $WorkbookCollege = $Fields[1]

        if ($Department.Length -gt 0) {
            $DepartmentMatched++
        } else {
            $DepartmentUnmatched++
        }

        if ($WorkbookCollege.Length -gt 0) {
            $CollegeMatched++
        } else {
            $CollegeUnmatched++
        }

        if ($Department.Length -gt 0 -and $WorkbookCollege.Length -gt 0) {
            $CombinedMatched++
        }

        if ($WorkbookCollege.Length -gt 0 -and
            $Course.ReportingCollege.Length -gt 0 -and
            $Course.CollegeCount -eq 1) {

            $CollegeComparable++

            if ($WorkbookCollege -eq $Course.ReportingCollege) {
                $CollegeAgreement++
            } else {
                $CollegeDisagreement++
            }
        }
    }

    $MatchedIds = @(
        $CatalogIds.Keys |
            Where-Object { $Latest.ContainsKey($_) }
    ).Count

    $ReportingOnlyIds = @(
        $CatalogIds.Keys |
            Where-Object { -not $Latest.ContainsKey($_) }
    ).Count

    $WorkbookOnlyIds = @(
        $Latest.Keys |
            Where-Object { -not $CatalogIds.ContainsKey($_) }
    ).Count

    $DuplicateIds = @(
        $RowsById.GetEnumerator() |
            Where-Object { $_.Value -gt 1 }
    ).Count

    $AmbiguousIds = @(
        $Latest.GetEnumerator() |
            Where-Object { $_.Value.Pairs.Count -gt 1 }
    ).Count

    Write-Host "CURRENT_CATALOG_ROWS=$($Catalog.Count)"
    Write-Host "CURRENT_CATALOG_DISTINCT_IDS=$($CatalogIds.Count)"
    Write-Host "WORKBOOK_DISTINCT_IDS=$($Latest.Count)"
    Write-Host "MATCHED_DISTINCT_IDS=$MatchedIds"
    Write-Host "REPORTING_ONLY_DISTINCT_IDS=$ReportingOnlyIds"
    Write-Host "WORKBOOK_ONLY_DISTINCT_IDS=$WorkbookOnlyIds"
    Write-Host "WORKBOOK_DUPLICATE_ID_GROUPS=$DuplicateIds"
    Write-Host "INVALID_EFFECTIVE_DATE_ROWS=$InvalidDates"
    Write-Host "LATEST_EFFECTIVE_AMBIGUOUS_IDS=$AmbiguousIds"
    Write-Host "AMBIGUOUS_CURRENT_CATALOG_ROWS=$AmbiguousRows"
    Write-Host "DEPARTMENT_MATCHED=$DepartmentMatched"
    Write-Host "DEPARTMENT_UNMATCHED=$DepartmentUnmatched"
    Write-Host "COLLEGE_MATCHED=$CollegeMatched"
    Write-Host "COLLEGE_UNMATCHED=$CollegeUnmatched"
    Write-Host "COMBINED_COLLEGE_DEPARTMENT_MATCHED=$CombinedMatched"
    Write-Host "COLLEGE_COMPARABLE=$CollegeComparable"
    Write-Host "COLLEGE_AGREEMENT=$CollegeAgreement"
    Write-Host "COLLEGE_DISAGREEMENT=$CollegeDisagreement"

    Write-Host "`nPASS|COLLEGE_DEPARTMENT_RECONCILIATION_READ_ONLY"
    Write-Host "WORKBOOK_MODIFIED=FALSE"
    Write-Host "DATABASE_MUTATED=FALSE"
    Write-Host "DIRECTUS_MUTATED=FALSE"
    Write-Host "MIDDLEWARE_MUTATED=FALSE"
    Write-Host "UI_MUTATED=FALSE"
}
finally {
    if ($null -ne $Book) {
        try { $Book.Close($false) } catch {}
    }

    if ($null -ne $Excel) {
        try { $Excel.Quit() } catch {}
    }

    foreach ($Object in @($Range,$Sheet,$Book,$Excel)) {
        if ($null -ne $Object -and
            [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
            try {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
            } catch {}
        }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}