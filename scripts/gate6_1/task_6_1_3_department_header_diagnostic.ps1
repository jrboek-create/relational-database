[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepositoryRoot = "C:\Directus\relational-repository"
$SourcePath = Join-Path $RepositoryRoot "imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
$EvidenceRoot = Join-Path $RepositoryRoot "evidence\gate6\gate6_1"
$ExpectedSha256 = "A0D1F5830672D86B8314495774FA0DD740B4FB826EFF0E8F525248C59E8D4296"
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$EvidenceDirectory = Join-Path $EvidenceRoot ("department_header_diagnostic_" + $RunStamp)

function Release-ComObject {
    param([object]$ComObject)
    if ($null -ne $ComObject) {
        try {
            if ([Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
            }
        } catch { }
    }
}

function Get-ExcelColumnName {
    param([int]$ColumnNumber)
    $name = ""
    $number = $ColumnNumber
    while ($number -gt 0) {
        $number--
        $name = [char](65 + ($number % 26)) + $name
        $number = [math]::Floor($number / 26)
    }
    return $name
}

function ConvertTo-NormalizedHeader {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder
    foreach ($character in $decomposed.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }

    $value = $builder.ToString().ToLowerInvariant()
    $value = $value -replace "&", " and "
    $value = $value -replace "[^a-z0-9]+", " "
    $tokens = @($value.Trim() -split "\s+" | Where-Object { $_ -ne "" })

    $aliases = @{
        "ww"    = "worldwide"
        "univ"  = "university"
        "acad"  = "academic"
        "org"   = "organization"
        "dept"  = "department"
        "descr" = "description"
        "desc"  = "description"
        "nm"    = "name"
        "eff"   = "effective"
        "dt"    = "date"
        "nbr"   = "number"
        "ident" = "identifier"
    }

    $expanded = foreach ($token in $tokens) {
        if ($aliases.ContainsKey($token)) { $aliases[$token] } else { $token }
    }

    return (($expanded -join " ") -replace "\s+", " ").Trim()
}

function Test-StrongConceptMatch {
    param([string]$ConceptKey, [string[]]$Tokens)
    $set = @{}
    foreach ($token in $Tokens) { $set[$token] = $true }

    switch ($ConceptKey) {
        "UniversityCourseID" {
            return ($set.ContainsKey("university") -and
                    $set.ContainsKey("course") -and
                    ($set.ContainsKey("id") -or $set.ContainsKey("identifier")))
        }
        "EffectiveDate" {
            return ($set.ContainsKey("effective") -and $set.ContainsKey("date"))
        }
        "WorldwideAcademicOrganization" {
            return ($set.ContainsKey("worldwide") -and
                    $set.ContainsKey("academic") -and
                    $set.ContainsKey("organization"))
        }
        "WorldwideDepartmentName" {
            return ($set.ContainsKey("worldwide") -and
                    $set.ContainsKey("department") -and
                    ($set.ContainsKey("name") -or $set.ContainsKey("description")))
        }
        default { return $false }
    }
}

function Read-HeadersWithExcelCom {
    param([string]$Path)

    $excel = $null
    $workbooks = $null
    $workbook = $null
    $worksheets = $null
    $worksheet = $null
    $range = $null

    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.EnableEvents = $false
        $excel.AskToUpdateLinks = $false
        $excel.AutomationSecurity = 3

        $workbooks = $excel.Workbooks
        $missing = [Type]::Missing
        $workbook = $workbooks.Open(
            $Path, 0, $true, $missing, $missing, $missing, $true,
            $missing, $missing, $false, $false, $missing, $false, $false, 0
        )

        if (-not [bool]$workbook.ReadOnly) {
            throw "Excel did not open the workbook read-only."
        }

        $worksheets = $workbook.Worksheets
        if ([int]$worksheets.Count -ne 1) {
            throw ("Expected one worksheet; observed " + $worksheets.Count + ".")
        }

        $worksheet = $worksheets.Item(1)
        $sheetName = [string]$worksheet.Name
        if ($sheetName -ne "sheet1") {
            throw ("Expected worksheet sheet1; observed " + $sheetName + ".")
        }

        $range = $worksheet.Range("A2:AZ2")
        $values = $range.Value2
        $headers = New-Object Collections.Generic.List[string]

        for ($column = 1; $column -le 52; $column++) {
            $cellValue = $values.GetValue(1, $column)
            if ($null -eq $cellValue) {
                $headers.Add("")
            } else {
                $headers.Add([Convert]::ToString($cellValue, [Globalization.CultureInfo]::InvariantCulture))
            }
        }

        return [pscustomobject]@{
            Method = "Excel COM read-only"
            Sheet = $sheetName
            Headers = $headers.ToArray()
        }
    }
    finally {
        if ($null -ne $workbook) {
            try { $workbook.Close($false) } catch { }
        }
        Release-ComObject $range
        Release-ComObject $worksheet
        Release-ComObject $worksheets
        Release-ComObject $workbook
        Release-ComObject $workbooks
        if ($null -ne $excel) {
            try { $excel.Quit() } catch { }
        }
        Release-ComObject $excel
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Read-HeadersWithOleDb {
    param([string]$Path)

    $providers = @("Microsoft.ACE.OLEDB.16.0", "Microsoft.ACE.OLEDB.12.0", "Microsoft.Jet.OLEDB.4.0")
    $errors = New-Object Collections.Generic.List[string]

    foreach ($provider in $providers) {
        $connection = $null
        $command = $null
        $reader = $null
        try {
            $connectionString = 'Provider={0};Data Source={1};Mode=Read;Extended Properties="Excel 8.0;HDR=NO;IMEX=1;ReadOnly=True";' -f $provider, $Path
            $connection = New-Object Data.OleDb.OleDbConnection($connectionString)
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = "SELECT * FROM [sheet1`$A2:AZ2]"
            $reader = $command.ExecuteReader()

            if (-not $reader.Read()) { throw "The row-2 range returned no record." }
            if ($reader.FieldCount -ne 52) {
                throw ("Expected 52 columns; observed " + $reader.FieldCount + ".")
            }

            $headers = New-Object Collections.Generic.List[string]
            for ($column = 0; $column -lt 52; $column++) {
                if ($reader.IsDBNull($column)) {
                    $headers.Add("")
                } else {
                    $headers.Add([Convert]::ToString($reader.GetValue($column), [Globalization.CultureInfo]::InvariantCulture))
                }
            }

            return [pscustomobject]@{
                Method = ("OLE DB read-only: " + $provider)
                Sheet = "sheet1"
                Headers = $headers.ToArray()
            }
        }
        catch {
            $errors.Add($provider + ": " + $_.Exception.Message)
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $command) { $command.Dispose() }
            if ($null -ne $connection) {
                try { $connection.Close() } catch { }
                $connection.Dispose()
            }
        }
    }

    throw ("Excel COM was unavailable or failed, and no read-only local OLE DB provider succeeded. " + ($errors -join " | "))
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw ("Source workbook not found: " + $SourcePath)
    }

    $sourceBefore = Get-Item -LiteralPath $SourcePath
    $hashBefore = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($hashBefore -ne $ExpectedSha256) {
        throw ("Pre-open SHA-256 does not match the frozen source fingerprint. Expected=" + $ExpectedSha256 + "; Actual=" + $hashBefore)
    }

    $readResult = $null
    $comFailure = $null
    $excelType = [Type]::GetTypeFromProgID("Excel.Application")

    if ($null -ne $excelType) {
        try {
            $readResult = Read-HeadersWithExcelCom -Path $SourcePath
        }
        catch {
            $comFailure = $_.Exception.Message
        }
    } else {
        $comFailure = "Excel.Application ProgID is not registered."
    }

    if ($null -eq $readResult) {
        $readResult = Read-HeadersWithOleDb -Path $SourcePath
    }

    if ($readResult.Headers.Count -ne 52) {
        throw ("Expected exactly 52 row-2 cells; observed " + $readResult.Headers.Count + ".")
    }

    $hashAfter = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $sourceAfter = Get-Item -LiteralPath $SourcePath
    $sourceModified = ($hashBefore -ne $hashAfter)

    if ($sourceModified) {
        throw ("Source SHA-256 changed during the diagnostic. Before=" + $hashBefore + "; After=" + $hashAfter)
    }

    $headerRecords = New-Object Collections.Generic.List[object]
    for ($column = 1; $column -le 52; $column++) {
        $actual = [string]$readResult.Headers[$column - 1]
        $headerRecords.Add([pscustomobject]@{
            column_number = $column
            column_letter = Get-ExcelColumnName $column
            actual_label = $actual
            normalized_label = ConvertTo-NormalizedHeader $actual
        })
    }

    $concepts = @(
        [pscustomobject]@{ Key="UniversityCourseID"; Name="University Course ID"; Canonical="university course id"; Tokens=@("university","course","id") },
        [pscustomobject]@{ Key="EffectiveDate"; Name="Effective Date"; Canonical="effective date"; Tokens=@("effective","date") },
        [pscustomobject]@{ Key="WorldwideAcademicOrganization"; Name="Worldwide Academic Organization"; Canonical="worldwide academic organization"; Tokens=@("worldwide","academic","organization") },
        [pscustomobject]@{ Key="WorldwideDepartmentName"; Name="Worldwide Department Name"; Canonical="worldwide department name"; Tokens=@("worldwide","department","name") }
    )

    $conceptResults = New-Object Collections.Generic.List[object]
    foreach ($concept in $concepts) {
        $ranked = foreach ($header in $headerRecords) {
            $tokens = @($header.normalized_label -split "\s+" | Where-Object { $_ -ne "" })
            $tokenSet = @{}
            foreach ($token in $tokens) { $tokenSet[$token] = $true }
            $overlap = 0
            foreach ($needed in $concept.Tokens) {
                if ($tokenSet.ContainsKey($needed)) { $overlap++ }
            }
            $exact = ($header.normalized_label -eq $concept.Canonical)
            $strong = Test-StrongConceptMatch -ConceptKey $concept.Key -Tokens $tokens
            $score = ($overlap * 20)
            if ($strong) { $score += 60 }
            if ($exact) { $score += 100 }

            if ($score -gt 0) {
                [pscustomobject]@{
                    column_number = $header.column_number
                    column_letter = $header.column_letter
                    actual_label = $header.actual_label
                    normalized_label = $header.normalized_label
                    exact = $exact
                    strong = $strong
                    score = $score
                }
            }
        }

        $ranked = @($ranked | Sort-Object @{Expression="score";Descending=$true}, column_number | Select-Object -First 5)
        $exactFound = @($ranked | Where-Object { $_.exact }).Count -gt 0
        $strongFound = @($ranked | Where-Object { $_.strong }).Count -gt 0

        if ($exactFound) { $status = "EXACT_LABEL_PRESENT" }
        elseif ($strongFound) { $status = "STRONG_ALTERNATIVE_CANDIDATE_REVIEW_REQUIRED" }
        elseif ($ranked.Count -gt 0) { $status = "PLAUSIBLE_TOKEN_OVERLAP_ONLY" }
        else { $status = "NOT_DETECTED" }

        $conceptResults.Add([pscustomobject]@{
            concept_key = $concept.Key
            concept_name = $concept.Name
            status = $status
            candidates = $ranked
        })
    }

    $acadResult = $conceptResults | Where-Object { $_.concept_key -eq "WorldwideAcademicOrganization" }
    $deptResult = $conceptResults | Where-Object { $_.concept_key -eq "WorldwideDepartmentName" }

    if ($acadResult.status -eq "EXACT_LABEL_PRESENT" -and $deptResult.status -eq "EXACT_LABEL_PRESENT") {
        $ownershipStatus = "EXPECTED_OWNERSHIP_HEADERS_PRESENT"
    }
    elseif ($acadResult.status -match "EXACT|STRONG" -and $deptResult.status -match "EXACT|STRONG") {
        $ownershipStatus = "ALTERNATIVE_OWNERSHIP_HEADER_CANDIDATES_REQUIRE_REVIEW"
    }
    else {
        $ownershipStatus = "OWNERSHIP_HEADERS_NOT_VERIFIED_STOP_RECONCILIATION"
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("PASS|GATE6_1_DEPARTMENT_HEADER_READONLY_INTEGRITY")
    $lines.Add("source=" + $SourcePath)
    $lines.Add("report_query_family=ER_SR_1CAT_UNIV_MASTER_DETAIL")
    $lines.Add("export_instance=ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls")
    $lines.Add("read_method=" + $readResult.Method)
    $lines.Add("sheet=" + $readResult.Sheet)
    $lines.Add("inspected_row=2")
    $lines.Add("inspected_columns=52")
    $lines.Add("sha256_before=" + $hashBefore)
    $lines.Add("sha256_after=" + $hashAfter)
    $lines.Add("source_modified=false")
    $lines.Add("runtime_mutated=false")
    $lines.Add("department_reconciliation_performed=false")
    $lines.Add("department_filtering_enabled=false")
    $lines.Add("ownership_header_status=" + $ownershipStatus)

    foreach ($header in $headerRecords) {
        $actualDisplay = $header.actual_label -replace "\r?\n", " " -replace "\|", "<PIPE>"
        if ([string]::IsNullOrWhiteSpace($actualDisplay)) { $actualDisplay = "<BLANK>" }
        $normalizedDisplay = $header.normalized_label
        if ([string]::IsNullOrWhiteSpace($normalizedDisplay)) { $normalizedDisplay = "<BLANK>" }
        $lines.Add(("HEADER|{0:D2}|{1}|actual={2}|normalized={3}" -f $header.column_number, $header.column_letter, $actualDisplay, $normalizedDisplay))
    }

    foreach ($result in $conceptResults) {
        $lines.Add("CONCEPT|" + $result.concept_name + "|status=" + $result.status)
        foreach ($candidate in $result.candidates) {
            $candidateLabel = $candidate.actual_label -replace "\r?\n", " " -replace "\|", "<PIPE>"
            if ([string]::IsNullOrWhiteSpace($candidateLabel)) { $candidateLabel = "<BLANK>" }
            $lines.Add(("CANDIDATE|{0}|{1}|{2}|score={3}|exact={4}|strong={5}" -f $result.concept_name, $candidate.column_letter, $candidateLabel, $candidate.score, $candidate.exact, $candidate.strong))
        }
    }

    $diagnosticPath = Join-Path $EvidenceDirectory "department-header-diagnostic.txt"
    $headersJsonPath = Join-Path $EvidenceDirectory "row-2-header-labels.json"
    $lineagePath = Join-Path $EvidenceDirectory "source-lineage.json"

    Set-Content -LiteralPath $diagnosticPath -Value $lines -Encoding UTF8
    $headerRecords | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $headersJsonPath -Encoding UTF8

    [pscustomobject]@{
        report_query_family = "ER_SR_1CAT_UNIV_MASTER_DETAIL"
        export_instance = "ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
        source_path = $SourcePath
        source_bytes = [int64]$sourceBefore.Length
        expected_sha256 = $ExpectedSha256
        sha256_before = $hashBefore
        sha256_after = $hashAfter
        source_last_write_utc_before = $sourceBefore.LastWriteTimeUtc.ToString("o")
        source_last_write_utc_after = $sourceAfter.LastWriteTimeUtc.ToString("o")
        read_method = $readResult.Method
        excel_com_failure_before_fallback = $comFailure
        inspected_sheet = $readResult.Sheet
        inspected_row = 2
        inspected_columns = 52
        source_modified = $false
        runtime_mutated = $false
        department_reconciliation_performed = $false
        department_filtering_enabled = $false
        ownership_header_status = $ownershipStatus
        created_utc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $lineagePath -Encoding UTF8

    $sumLines = foreach ($artifact in @($diagnosticPath, $headersJsonPath, $lineagePath)) {
        $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToUpperInvariant()
        $artifactHash + " *" + (Split-Path -Leaf $artifact)
    }
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "SHA256SUMS.txt") -Value $sumLines -Encoding ASCII

    $lines | ForEach-Object { Write-Output $_ }
    Write-Output ("evidence_directory=" + $EvidenceDirectory)
    exit 0
}
catch {
    $afterOnFailure = "<UNAVAILABLE>"
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        try { $afterOnFailure = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant() } catch { }
    }

    $failureLines = @(
        "FAIL|GATE6_1_DEPARTMENT_HEADER_DIAGNOSTIC",
        ("source=" + $SourcePath),
        ("sha256_after_failure=" + $afterOnFailure),
        ("error=" + $_.Exception.Message),
        "runtime_mutated=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "diagnostic-failure.txt") -Value $failureLines -Encoding UTF8
    $failureLines | ForEach-Object { Write-Output $_ }
    exit 1
}
