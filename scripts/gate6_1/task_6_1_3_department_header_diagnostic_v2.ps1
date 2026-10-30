[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepositoryRoot = "C:\Directus\relational-repository"
$Source = Join-Path $RepositoryRoot "imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
$ExpectedHash = "A0D1F5830672D86B8314495774FA0DD740B4FB826EFF0E8F525248C59E8D4296"
$EvidenceRoot = Join-Path $RepositoryRoot "evidence\gate6\gate6_1"
$EvidenceDirectory = Join-Path $EvidenceRoot ("department_header_diagnostic_v2_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$Connection = $null
$HashBefore = "<NOT_COMPUTED>"

function Get-ColumnName {
    param([int]$Number)
    $Name = ""
    while ($Number -gt 0) {
        $Number--
        $Name = ([char](65 + ($Number % 26))) + $Name
        $Number = [math]::Floor($Number / 26)
    }
    return $Name
}

function Normalize-Header {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $Value = $Text.Normalize([Text.NormalizationForm]::FormD)
    $Builder = New-Object Text.StringBuilder
    foreach ($Character in $Value.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$Builder.Append($Character)
        }
    }
    $Value = $Builder.ToString().ToLowerInvariant()
    $Value = $Value -replace "&", " and "
    $Value = $Value -replace "[^a-z0-9]+", " "
    $Aliases = @{
        "ww"="worldwide"; "univ"="university"; "crse"="course";
        "acad"="academic"; "org"="organization"; "dept"="department";
        "nm"="name"; "descr"="description"; "desc"="description";
        "eff"="effective"; "dt"="date"; "nbr"="number";
        "num"="number"; "ident"="identifier"
    }
    $Expanded = foreach ($Token in @($Value.Trim() -split "\s+" | Where-Object { $_ })) {
        if ($Aliases.ContainsKey($Token)) { $Aliases[$Token] } else { $Token }
    }
    return (($Expanded -join " ") -replace "\s+", " ").Trim()
}

function Test-StrongMatch {
    param([string]$Key,[string]$Normalized)
    $Set = @{}
    foreach ($Token in @($Normalized -split "\s+" | Where-Object { $_ })) { $Set[$Token] = $true }
    switch ($Key) {
        "UniversityCourseID" {
            return ($Set.ContainsKey("university") -and $Set.ContainsKey("course") -and ($Set.ContainsKey("id") -or $Set.ContainsKey("identifier") -or $Set.ContainsKey("number")))
        }
        "EffectiveDate" {
            return ($Set.ContainsKey("effective") -and $Set.ContainsKey("date"))
        }
        "WorldwideAcademicOrganization" {
            return ($Set.ContainsKey("worldwide") -and $Set.ContainsKey("academic") -and $Set.ContainsKey("organization"))
        }
        "WorldwideDepartmentName" {
            return ($Set.ContainsKey("worldwide") -and $Set.ContainsKey("department") -and ($Set.ContainsKey("name") -or $Set.ContainsKey("description")))
        }
    }
    return $false
}

function Safe-Text {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return (($Text -replace "\r?\n"," ") -replace "\|","<PIPE>")
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw ("Source workbook not found: " + $Source)
    }

    $SourceBefore = Get-Item -LiteralPath $Source
    $HashBefore = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($HashBefore -ne $ExpectedHash) {
        throw ("Frozen source hash mismatch. Expected=" + $ExpectedHash + "; Actual=" + $HashBefore)
    }

    $ProviderErrors = New-Object Collections.Generic.List[string]
    $ProviderUsed = $null

    foreach ($Provider in @("Microsoft.ACE.OLEDB.16.0","Microsoft.ACE.OLEDB.12.0")) {
        $CandidateConnection = $null
        try {
            $ConnectionString = "Provider=$Provider;Data Source=$Source;Mode=Read;Extended Properties=`"Excel 8.0;HDR=NO;IMEX=1;ReadOnly=True`";"
            $CandidateConnection = New-Object System.Data.OleDb.OleDbConnection -ArgumentList $ConnectionString
            $CandidateConnection.Open()
            $Connection = $CandidateConnection
            $ProviderUsed = $Provider
            break
        }
        catch {
            $ProviderErrors.Add($Provider + ": " + $_.Exception.Message)
            if ($null -ne $CandidateConnection) {
                try { $CandidateConnection.Close() } catch {}
                $CandidateConnection.Dispose()
            }
        }
    }

    if ($null -eq $Connection) {
        throw ("No ACE read-only provider succeeded. " + ($ProviderErrors -join " | "))
    }

    $BroadFieldCount = 0
    $BroadRowReturned = $false
    $Command = $null
    $Reader = $null

    try {
        $Command = $Connection.CreateCommand()
        $Command.CommandText = "SELECT * FROM [sheet1`$A2:AZ2]"
        $Reader = $Command.ExecuteReader()
        $BroadFieldCount = [int]$Reader.FieldCount
        $BroadRowReturned = [bool]$Reader.Read()
    }
    finally {
        if ($null -ne $Reader) { $Reader.Close(); $Reader.Dispose() }
        if ($null -ne $Command) { $Command.Dispose() }
    }

    $Headers = New-Object Collections.Generic.List[object]
    $CellErrors = New-Object Collections.Generic.List[string]

    for ($ColumnNumber = 1; $ColumnNumber -le 52; $ColumnNumber++) {
        $ColumnLetter = Get-ColumnName $ColumnNumber
        $Cell = $ColumnLetter + "2"
        $Range = "[sheet1`$" + $Cell + ":" + $Cell + "]"
        $Actual = ""
        $ReadStatus = "NOT_READ"
        $FieldCount = 0
        $CellError = $null
        $Command = $null
        $Reader = $null

        try {
            $Command = $Connection.CreateCommand()
            $Command.CommandText = "SELECT * FROM " + $Range
            $Reader = $Command.ExecuteReader()
            $FieldCount = [int]$Reader.FieldCount

            if ($FieldCount -gt 1) {
                throw ("Fixed-cell query exposed more than one field for " + $Cell)
            }
            elseif ($FieldCount -eq 1 -and $Reader.Read()) {
                if ($Reader.IsDBNull(0)) {
                    $ReadStatus = "EXPOSED_NULL"
                }
                else {
                    $Actual = [Convert]::ToString($Reader.GetValue(0),[Globalization.CultureInfo]::InvariantCulture)
                    $ReadStatus = "VALUE_READ"
                }
            }
            elseif ($FieldCount -eq 1) {
                $ReadStatus = "EXPOSED_NO_ROW"
            }
            else {
                $ReadStatus = "NOT_EXPOSED_BY_PROVIDER"
            }
        }
        catch {
            $CellError = $_.Exception.Message
            $ReadStatus = "QUERY_ERROR_NOT_EXPOSED"
            $CellErrors.Add($Cell + ": " + $CellError)
        }
        finally {
            if ($null -ne $Reader) { $Reader.Close(); $Reader.Dispose() }
            if ($null -ne $Command) { $Command.Dispose() }
        }

        $Headers.Add([pscustomobject]@{
            column_number = $ColumnNumber
            column_letter = $ColumnLetter
            cell_address = $Cell
            actual_label = $Actual
            normalized_label = Normalize-Header $Actual
            read_status = $ReadStatus
            provider_field_count = $FieldCount
            provider_error = $CellError
        })
    }

    $Connection.Close()
    $Connection.Dispose()
    $Connection = $null

    $HashAfter = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToUpperInvariant()
    $SourceAfter = Get-Item -LiteralPath $Source
    if ($HashAfter -ne $HashBefore) {
        throw ("Source workbook changed. Before=" + $HashBefore + "; After=" + $HashAfter)
    }

    $Concepts = @(
        [pscustomobject]@{ key="UniversityCourseID"; name="University Course ID"; normalized="university course id"; tokens=@("university","course","id") },
        [pscustomobject]@{ key="EffectiveDate"; name="Effective Date"; normalized="effective date"; tokens=@("effective","date") },
        [pscustomobject]@{ key="WorldwideAcademicOrganization"; name="Worldwide Academic Organization"; normalized="worldwide academic organization"; tokens=@("worldwide","academic","organization") },
        [pscustomobject]@{ key="WorldwideDepartmentName"; name="Worldwide Department Name"; normalized="worldwide department name"; tokens=@("worldwide","department","name") }
    )

    $ConceptResults = New-Object Collections.Generic.List[object]

    foreach ($Concept in $Concepts) {
        $Candidates = New-Object Collections.Generic.List[object]

        foreach ($Header in $Headers) {
            if ([string]::IsNullOrWhiteSpace($Header.normalized_label)) { continue }
            $HeaderTokens = @($Header.normalized_label -split "\s+" | Where-Object { $_ })
            $TokenSet = @{}
            foreach ($Token in $HeaderTokens) { $TokenSet[$Token] = $true }
            $Overlap = 0
            foreach ($RequiredToken in $Concept.tokens) {
                if ($TokenSet.ContainsKey($RequiredToken)) { $Overlap++ }
            }
            $Exact = ($Header.normalized_label -eq $Concept.normalized)
            $Strong = Test-StrongMatch $Concept.key $Header.normalized_label
            $Score = ($Overlap * 20)
            if ($Strong) { $Score += 60 }
            if ($Exact) { $Score += 100 }

            if ($Score -gt 0) {
                $Candidates.Add([pscustomobject]@{
                    column_number = $Header.column_number
                    column_letter = $Header.column_letter
                    actual_label = $Header.actual_label
                    normalized_label = $Header.normalized_label
                    exact = $Exact
                    strong = $Strong
                    score = $Score
                })
            }
        }

        $Ranked = @($Candidates | Sort-Object @{Expression="score";Descending=$true},column_number | Select-Object -First 5)
        if (@($Ranked | Where-Object { $_.exact }).Count -gt 0) {
            $Status = "VERIFIED"
        }
        elseif (@($Ranked | Where-Object { $_.strong }).Count -gt 0) {
            $Status = "CANDIDATE_FOR_REVIEW"
        }
        else {
            $Status = "NOT_VERIFIED"
        }

        $ConceptResults.Add([pscustomobject]@{
            concept_key = $Concept.key
            concept_name = $Concept.name
            status = $Status
            candidates = $Ranked
        })
    }

    $AcademicResult = $ConceptResults | Where-Object { $_.concept_key -eq "WorldwideAcademicOrganization" }
    $DepartmentResult = $ConceptResults | Where-Object { $_.concept_key -eq "WorldwideDepartmentName" }

    if ($AcademicResult.status -eq "VERIFIED" -and $DepartmentResult.status -eq "VERIFIED") {
        $OwnershipStatus = "VERIFIED_DIAGNOSTIC_ONLY"
    }
    elseif ($AcademicResult.status -ne "NOT_VERIFIED" -and $DepartmentResult.status -ne "NOT_VERIFIED") {
        $OwnershipStatus = "CANDIDATE_FOR_HUMAN_REVIEW"
    }
    else {
        $OwnershipStatus = "NOT_VERIFIED_STOP_RECONCILIATION"
    }

    $Output = New-Object Collections.Generic.List[string]
    $Output.Add("PASS|GATE6_1_DEPARTMENT_HEADER_V2_READONLY_INTEGRITY")
    $Output.Add("source=" + $Source)
    $Output.Add("report_query_family=ER_SR_1CAT_UNIV_MASTER_DETAIL")
    $Output.Add("provider=" + $ProviderUsed)
    $Output.Add("read_method=ACE OLE DB fixed-cell read-only queries")
    $Output.Add("inspected_sheet=sheet1")
    $Output.Add("inspected_row=2")
    $Output.Add("expected_structural_width=52")
    $Output.Add("broad_range_provider_field_count=" + $BroadFieldCount)
    $Output.Add("broad_range_row_returned=" + $BroadRowReturned)
    $Output.Add("fixed_cell_queries=52")
    $Output.Add("fixed_cell_query_errors=" + $CellErrors.Count)
    $Output.Add("sha256_before=" + $HashBefore)
    $Output.Add("sha256_after=" + $HashAfter)
    $Output.Add("source_modified=false")
    $Output.Add("runtime_mutated=false")
    $Output.Add("department_reconciliation_performed=false")
    $Output.Add("department_filtering_enabled=false")
    $Output.Add("ownership_header_status=" + $OwnershipStatus)

    foreach ($Header in $Headers) {
        $ActualDisplay = Safe-Text $Header.actual_label
        $NormalizedDisplay = Safe-Text $Header.normalized_label
        if ([string]::IsNullOrWhiteSpace($ActualDisplay)) { $ActualDisplay = "<BLANK_OR_NOT_EXPOSED>" }
        if ([string]::IsNullOrWhiteSpace($NormalizedDisplay)) { $NormalizedDisplay = "<BLANK>" }
        $Output.Add(("HEADER|{0:D2}|{1}|cell={2}|actual={3}|normalized={4}|read_status={5}|provider_fields={6}" -f $Header.column_number,$Header.column_letter,$Header.cell_address,$ActualDisplay,$NormalizedDisplay,$Header.read_status,$Header.provider_field_count))
    }

    foreach ($Result in $ConceptResults) {
        $Output.Add("CONCEPT|" + $Result.concept_name + "|status=" + $Result.status)
        foreach ($Candidate in $Result.candidates) {
            $Output.Add(("CANDIDATE|{0}|column={1}|label={2}|normalized={3}|score={4}|exact={5}|strong={6}" -f $Result.concept_name,$Candidate.column_letter,(Safe-Text $Candidate.actual_label),(Safe-Text $Candidate.normalized_label),$Candidate.score,$Candidate.exact,$Candidate.strong))
        }
    }

    $DiagnosticPath = Join-Path $EvidenceDirectory "department-header-diagnostic-v2.txt"
    $HeadersPath = Join-Path $EvidenceDirectory "row-2-header-labels.json"
    $ConceptsPath = Join-Path $EvidenceDirectory "ownership-header-concepts.json"
    $LineagePath = Join-Path $EvidenceDirectory "source-lineage.json"

    Set-Content -LiteralPath $DiagnosticPath -Value $Output -Encoding UTF8
    @($Headers) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $HeadersPath -Encoding UTF8
    @($ConceptResults) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConceptsPath -Encoding UTF8

    [pscustomobject]@{
        report_query_family = "ER_SR_1CAT_UNIV_MASTER_DETAIL"
        export_instance = "ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
        source_path = $Source
        source_bytes = [int64]$SourceBefore.Length
        expected_sha256 = $ExpectedHash
        sha256_before = $HashBefore
        sha256_after = $HashAfter
        source_last_write_utc_before = $SourceBefore.LastWriteTimeUtc.ToString("o")
        source_last_write_utc_after = $SourceAfter.LastWriteTimeUtc.ToString("o")
        provider = $ProviderUsed
        read_method = "ACE OLE DB fixed-cell read-only queries"
        inspected_sheet = "sheet1"
        inspected_row = 2
        structural_positions = 52
        broad_range_provider_field_count = $BroadFieldCount
        fixed_cell_query_errors = $CellErrors.Count
        ownership_header_status = $OwnershipStatus
        source_modified = $false
        runtime_mutated = $false
        department_reconciliation_performed = $false
        department_filtering_enabled = $false
        created_utc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LineagePath -Encoding UTF8

    $ChecksumLines = foreach ($Artifact in @($DiagnosticPath,$HeadersPath,$ConceptsPath,$LineagePath)) {
        $ArtifactHash = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToUpperInvariant()
        $ArtifactHash + " *" + (Split-Path -Leaf $Artifact)
    }
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "SHA256SUMS.txt") -Value $ChecksumLines -Encoding ASCII

    $Output | ForEach-Object { Write-Output $_ }
    Write-Output ("evidence_directory=" + $EvidenceDirectory)
    exit 0
}
catch {
    if ($null -ne $Connection) {
        try { $Connection.Close() } catch {}
        try { $Connection.Dispose() } catch {}
    }
    $FailureHash = "<UNAVAILABLE>"
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        try { $FailureHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToUpperInvariant() } catch {}
    }
    $Failure = @(
        "FAIL|GATE6_1_DEPARTMENT_HEADER_DIAGNOSTIC_V2",
        ("source=" + $Source),
        ("sha256_before=" + $HashBefore),
        ("sha256_after_failure=" + $FailureHash),
        ("error=" + $_.Exception.Message),
        "runtime_mutated=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "diagnostic-failure-v2.txt") -Value $Failure -Encoding UTF8
    $Failure | ForEach-Object { Write-Output $_ }
    exit 1
}
