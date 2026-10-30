Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath 'C:\Directus\relational-repository'

$Source = 'C:\Directus\relational-repository\imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls'
$ExpectedBytes = [int64]7435264
$ExpectedHash = '91FEA403B0BCCA8CC746EC28723C576A4D05204E1F1C9D8D7D16D451DB2A7D09'

$Excel = $null
$Book = $null
$Sheet = $null
$Range = $null

function ConvertTo-CsvField {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $Text = ([string]$Value).Replace('"','""')
    return '"' + $Text + '"'
}

try {
    Write-Host ''
    Write-Host '=== DEPARTMENT STAGING ROLLBACK REHEARSAL ==='

    $File = Get-Item -LiteralPath $Source -ErrorAction Stop
    $Hash = (
        Get-FileHash -LiteralPath $Source -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($File.Length -ne $ExpectedBytes) {
        throw 'SOURCE_BYTE_COUNT_MISMATCH'
    }

    if ($Hash -ne $ExpectedHash) {
        throw 'SOURCE_SHA256_MISMATCH'
    }

    Write-Host "SOURCE_BYTES=$($File.Length)"
    Write-Host "SOURCE_SHA256=$Hash"

    $Excel = New-Object -ComObject Excel.Application
    $Excel.Visible = $false
    $Excel.DisplayAlerts = $false
    $Excel.AskToUpdateLinks = $false
    $Excel.AutomationSecurity = 3

    $Book = $Excel.Workbooks.Open($Source, 0, $true)
    $Sheet = $Book.Worksheets.Item(1)
    $Range = $Sheet.UsedRange
    $Values = $Range.Value2

    if (
        ([string]$Values.GetValue(2,1)).Trim() -ne 'Univ Course ID' -or
        ([string]$Values.GetValue(2,2)).Trim() -ne 'Eff Date' -or
        ([string]$Values.GetValue(2,50)).Trim() -ne 'WW Owner(s)' -or
        ([string]$Values.GetValue(2,51)).Trim() -ne 'WW College(s)'
    ) {
        throw 'SOURCE_HEADER_MISMATCH'
    }

    $Sql = New-Object System.Text.StringBuilder

    [void]$Sql.AppendLine('\set ON_ERROR_STOP on')
    [void]$Sql.AppendLine('\pset pager off')
    [void]$Sql.AppendLine('BEGIN;')

    [void]$Sql.AppendLine(@'
CREATE TEMP TABLE department_rehearsal (
    university_course_id text,
    effective_date date,
    department_name text,
    college_name text
) ON COMMIT DROP;

COPY department_rehearsal (
    university_course_id,
    effective_date,
    department_name,
    college_name
)
FROM STDIN
WITH (
    FORMAT csv
);
'@)

    $SourceRows = 0

    for ($Row = 3; $Row -le [int]$Range.Rows.Count; $Row++) {

        $RawId = $Values.GetValue($Row,1)

        if ($null -eq $RawId) {
            continue
        }

        if ($RawId -is [double]) {
            $Id = ([int64]$RawId).ToString()
        }
        else {
            $Id = ([string]$RawId).Trim()
        }

        if ($Id.Length -eq 0) {
            continue
        }

        $RawDate = $Values.GetValue($Row,2)

        if ($RawDate -is [double]) {
            $EffectiveDate = (
                [datetime]::FromOADate([double]$RawDate)
            ).ToString('yyyy-MM-dd')
        }
        else {
            $ParsedDate = [datetime]::MinValue

            if (-not [datetime]::TryParse(
                ([string]$RawDate),
                [ref]$ParsedDate
            )) {
                throw "INVALID_EFFECTIVE_DATE_AT_SOURCE_ROW=$Row"
            }

            $EffectiveDate = $ParsedDate.ToString('yyyy-MM-dd')
        }

        $Department = ''

        if ($null -ne $Values.GetValue($Row,50)) {
            $Department = (
                [string]$Values.GetValue($Row,50)
            ).Trim()
        }

        $College = ''

        if ($null -ne $Values.GetValue($Row,51)) {
            $College = (
                [string]$Values.GetValue($Row,51)
            ).Trim()
        }

        $CsvLine = (
            (ConvertTo-CsvField $Id) + ',' +
            (ConvertTo-CsvField $EffectiveDate) + ',' +
            (ConvertTo-CsvField $Department) + ',' +
            (ConvertTo-CsvField $College)
        )

        [void]$Sql.AppendLine($CsvLine)

        $SourceRows++
    }

    [void]$Sql.AppendLine('\.')

    [void]$Sql.AppendLine(@'

SELECT
    'REHEARSAL_ROWS' AS metric,
    COUNT(*)::text AS value
FROM department_rehearsal;

SELECT
    'REHEARSAL_DISTINCT_IDS' AS metric,
    COUNT(DISTINCT university_course_id)::text AS value
FROM department_rehearsal;

SELECT
    'REHEARSAL_DUPLICATE_ID_GROUPS' AS metric,
    COUNT(*)::text AS value
FROM (
    SELECT university_course_id
    FROM department_rehearsal
    GROUP BY university_course_id
    HAVING COUNT(*) > 1
) AS duplicate_ids;

WITH latest_date AS (
    SELECT
        university_course_id,
        MAX(effective_date) AS effective_date
    FROM department_rehearsal
    GROUP BY university_course_id
),
latest AS (
    SELECT
        source.university_course_id,
        source.department_name,
        source.college_name
    FROM department_rehearsal AS source
    INNER JOIN latest_date
        ON latest_date.university_course_id =
           source.university_course_id
       AND latest_date.effective_date =
           source.effective_date
),
rollup AS (
    SELECT
        university_course_id,
        MIN(NULLIF(BTRIM(department_name),'')) AS department_name,
        MIN(NULLIF(BTRIM(college_name),'')) AS college_name,
        COUNT(
            DISTINCT ROW(
                NULLIF(BTRIM(department_name),''),
                NULLIF(BTRIM(college_name),'')
            )
        ) AS mapping_count
    FROM latest
    GROUP BY university_course_id
),
proof AS (
    SELECT
        catalog.course_id,
        catalog.university_course_id,
        rollup.department_name,
        rollup.college_name,
        rollup.mapping_count
    FROM reporting.course_current_catalog AS catalog
    LEFT JOIN rollup
        ON rollup.university_course_id =
           BTRIM(catalog.university_course_id)
)
SELECT CONCAT_WS(
    '|',
    'catalog_rows=' || COUNT(*),
    'department_matched=' ||
        COUNT(*) FILTER (
            WHERE mapping_count = 1
              AND department_name IS NOT NULL
        ),
    'department_unmatched=' ||
        COUNT(*) FILTER (
            WHERE department_name IS NULL
        ),
    'college_matched=' ||
        COUNT(*) FILTER (
            WHERE mapping_count = 1
              AND college_name IS NOT NULL
        ),
    'college_unmatched=' ||
        COUNT(*) FILTER (
            WHERE college_name IS NULL
        ),
    'combined_matched=' ||
        COUNT(*) FILTER (
            WHERE mapping_count = 1
              AND department_name IS NOT NULL
              AND college_name IS NOT NULL
        ),
    'ambiguous=' ||
        COUNT(*) FILTER (
            WHERE mapping_count > 1
        )
)
FROM proof;

ROLLBACK;

SELECT
    'ROLLBACK_COMPLETE' AS metric,
    'TRUE' AS value;
'@)

    Write-Host "SOURCE_ROWS_PREPARED=$SourceRows"
    Write-Host ''
    Write-Host '=== POSTGRESQL ROLLBACK REHEARSAL ==='

    $OldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $Output = @(
            $Sql.ToString() |
                docker compose exec -T database `
                    psql `
                    -X `
                    -v ON_ERROR_STOP=1 `
                    -P pager=off `
                    -A `
                    -t `
                    -F '|' `
                    -U directus_repository `
                    -d directus_repository 2>&1
        )

        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }

    if ($ExitCode -ne 0) {
        throw (
            "ROLLBACK_REHEARSAL_FAILED: " +
            ($Output -join [Environment]::NewLine)
        )
    }

    $Output |
        Where-Object {
            $_ -and $_.Trim().Length -gt 0
        } |
        ForEach-Object {
            Write-Host $_
        }

    Write-Host ''
    Write-Host 'PASS|DEPARTMENT_STAGING_ROLLBACK_REHEARSAL'
    Write-Host 'PERSISTENT_DATABASE_MUTATED=FALSE'
    Write-Host 'WORKBOOK_MODIFIED=FALSE'
    Write-Host 'DIRECTUS_MUTATED=FALSE'
    Write-Host 'MIDDLEWARE_MUTATED=FALSE'
    Write-Host 'UI_MUTATED=FALSE'
}
finally {

    if ($null -ne $Book) {
        try {
            $Book.Close($false)
        }
        catch {
        }
    }

    if ($null -ne $Excel) {
        try {
            $Excel.Quit()
        }
        catch {
        }
    }

    foreach ($Object in @(
        $Range,
        $Sheet,
        $Book,
        $Excel
    )) {
        if (
            $null -ne $Object -and
            [Runtime.InteropServices.Marshal]::IsComObject($Object)
        ) {
            try {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                    $Object
                )
            }
            catch {
            }
        }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}