[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepositoryRoot = "C:\Directus\relational-repository"
$SourcePath = Join-Path $RepositoryRoot "imports_hold\ER_SR_1CAT_UNIV_MASTER_DETAIL_618456250.xls"
$ExpectedHash = "A0D1F5830672D86B8314495774FA0DD740B4FB826EFF0E8F525248C59E8D4296"
$EvidenceRoot = Join-Path $RepositoryRoot "evidence\gate6\gate6_1"
$EvidenceDirectory = Join-Path $EvidenceRoot ("department_618456250_schema_validation_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$Connection = $null
$HashBefore = "<NOT_COMPUTED>"

function Safe-Text {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return "" }
    return (([string]$Value -replace "\r?\n"," ") -replace "\|","<PIPE>")
}

function Get-SchemaValue {
    param([Data.DataRow]$Row,[string]$Name)
    if ($Row.Table.Columns.Contains($Name) -and $Row[$Name] -ne [DBNull]::Value) {
        return $Row[$Name]
    }
    return $null
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw ("Required source does not exist: " + $SourcePath)
    }

    $SourceBefore = Get-Item -LiteralPath $SourcePath
    $HashBefore = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($HashBefore -ne $ExpectedHash) {
        throw ("Frozen source fingerprint mismatch. Expected=" + $ExpectedHash + "; Actual=" + $HashBefore)
    }

    $ProviderUsed = $null
    $ProviderErrors = @()

    foreach ($Provider in @("Microsoft.ACE.OLEDB.16.0","Microsoft.ACE.OLEDB.12.0")) {
        $CandidateConnection = $null
        try {
            $ConnectionString = "Provider=$Provider;Data Source=$SourcePath;Mode=Read;Extended Properties=`"Excel 8.0;HDR=NO;IMEX=1;ReadOnly=True`";"
            $CandidateConnection = New-Object System.Data.OleDb.OleDbConnection
            $CandidateConnection.ConnectionString = $ConnectionString
            $CandidateConnection.Open()
            $Connection = $CandidateConnection
            $ProviderUsed = $Provider
            break
        }
        catch {
            $ProviderErrors += ($Provider + ": " + $_.Exception.Message)
            if ($null -ne $CandidateConnection) {
                try { $CandidateConnection.Close() } catch {}
                $CandidateConnection.Dispose()
            }
        }
    }

    if ($null -eq $Connection) {
        throw ("No ACE read-only provider succeeded. " + ($ProviderErrors -join " | "))
    }

    $NoRestrictions = [System.Object[]]$null
    $TablesSchema = $Connection.GetOleDbSchemaTable(
        [System.Data.OleDb.OleDbSchemaGuid]::Tables,
        $NoRestrictions
    )

    if ($null -eq $TablesSchema) {
        throw "ACE returned no TABLES schema metadata."
    }

    $RawTableCount = $TablesSchema.Rows.Count
    $UniqueTableMap = @{}
    $DuplicateSchemaEntries = 0

    foreach ($Row in $TablesSchema.Rows) {
        $TableName = Safe-Text (Get-SchemaValue $Row "TABLE_NAME")
        $TableType = Safe-Text (Get-SchemaValue $Row "TABLE_TYPE")
        $Key = $TableName + "|" + $TableType

        if ($UniqueTableMap.ContainsKey($Key)) {
            $DuplicateSchemaEntries++
        }
        else {
            $UniqueTableMap[$Key] = [pscustomobject]@{
                table_name = $TableName
                table_type = $TableType
                table_catalog = Safe-Text (Get-SchemaValue $Row "TABLE_CATALOG")
                table_schema = Safe-Text (Get-SchemaValue $Row "TABLE_SCHEMA")
                description = Safe-Text (Get-SchemaValue $Row "DESCRIPTION")
            }
        }
    }

    $TableRecords = @()
    $ColumnRecords = @()

    foreach ($Key in @($UniqueTableMap.Keys | Sort-Object)) {
        $TableRecord = $UniqueTableMap[$Key]
        $DisplayName = $TableRecord.table_name.Trim([char]39)
        $IsWorksheet = $DisplayName.EndsWith("$")
        $StructureType = if ($IsWorksheet) { "WORKSHEET" } else { "NAMED_OR_INTERNAL_RANGE" }

        $Restrictions = New-Object System.Object[] 4
        $Restrictions[0] = $null
        $Restrictions[1] = $null
        $Restrictions[2] = $TableRecord.table_name
        $Restrictions[3] = $null

        $ColumnsSchema = $null
        $ColumnError = $null

        try {
            $ColumnsSchema = $Connection.GetOleDbSchemaTable(
                [System.Data.OleDb.OleDbSchemaGuid]::Columns,
                $Restrictions
            )
        }
        catch {
            $ColumnError = $_.Exception.Message
        }

        $EntryColumns = @()

        if ($null -ne $ColumnsSchema) {
            foreach ($ColumnRow in $ColumnsSchema.Rows) {
                $OrdinalRaw = Get-SchemaValue $ColumnRow "ORDINAL_POSITION"
                $Ordinal = if ($null -eq $OrdinalRaw) { 0 } else { [int]$OrdinalRaw }

                $ColumnRecord = [pscustomobject]@{
                    table_name = $TableRecord.table_name
                    structure_type = $StructureType
                    ordinal_position = $Ordinal
                    provider_column_name = Safe-Text (Get-SchemaValue $ColumnRow "COLUMN_NAME")
                    data_type = Safe-Text (Get-SchemaValue $ColumnRow "DATA_TYPE")
                    character_maximum_length = Safe-Text (Get-SchemaValue $ColumnRow "CHARACTER_MAXIMUM_LENGTH")
                    numeric_precision = Safe-Text (Get-SchemaValue $ColumnRow "NUMERIC_PRECISION")
                    numeric_scale = Safe-Text (Get-SchemaValue $ColumnRow "NUMERIC_SCALE")
                    nullable = Safe-Text (Get-SchemaValue $ColumnRow "IS_NULLABLE")
                }

                $EntryColumns += $ColumnRecord
                $ColumnRecords += $ColumnRecord
            }
        }

        $MaximumOrdinal = 0
        if ($EntryColumns.Count -gt 0) {
            $MaximumOrdinal = [int](($EntryColumns | Measure-Object -Property ordinal_position -Maximum).Maximum)
        }

        $TableRecords += [pscustomobject]@{
            table_name = $TableRecord.table_name
            table_type = $TableRecord.table_type
            structure_type = $StructureType
            provider_column_count = $EntryColumns.Count
            maximum_ordinal_position = $MaximumOrdinal
            column_schema_error = $ColumnError
        }
    }

    $MetadataCollections = @()
    try {
        $MetaSchema = $Connection.GetSchema()
        foreach ($MetaRow in $MetaSchema.Rows) {
            $CollectionName = Safe-Text (Get-SchemaValue $MetaRow "CollectionName")
            if (-not [string]::IsNullOrWhiteSpace($CollectionName)) {
                $MetadataCollections += $CollectionName
            }
        }
        $MetadataCollections = @($MetadataCollections | Sort-Object -Unique)
    }
    catch {
        $MetadataCollections = @("GetSchema unavailable: " + $_.Exception.Message)
    }

    $Connection.Close()
    $Connection.Dispose()
    $Connection = $null

    $HashAfter = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $SourceAfter = Get-Item -LiteralPath $SourcePath

    if ($HashAfter -ne $HashBefore) {
        throw ("Source changed during schema validation. Before=" + $HashBefore + "; After=" + $HashAfter)
    }

    $WorksheetRecords = @($TableRecords | Where-Object { $_.structure_type -eq "WORKSHEET" })
    $RangeRecords = @($TableRecords | Where-Object { $_.structure_type -eq "NAMED_OR_INTERNAL_RANGE" })
    $Sheet1Records = @(
        $WorksheetRecords | Where-Object {
            $_.table_name.Trim([char]39).TrimEnd("$") -ieq "sheet1"
        }
    )

    $Sheet1ColumnCount = 0
    $Sheet1MaximumOrdinal = 0

    if ($Sheet1Records.Count -gt 0) {
        $Sheet1ColumnCount = [int](($Sheet1Records | Measure-Object -Property provider_column_count -Maximum).Maximum)
        $Sheet1MaximumOrdinal = [int](($Sheet1Records | Measure-Object -Property maximum_ordinal_position -Maximum).Maximum)
    }

    $MetadataOwnershipCandidates = @(
        $TableRecords | Where-Object {
            $_.table_name -match "(?i)(ww|worldwide|acad|academic|department|dept|ownership)"
        }
    )

    $ProviderStructureStatus = if ($Sheet1MaximumOrdinal -gt 32) {
        "ADDITIONAL_SHEET_COLUMNS_EXPOSED_BEYOND_AF"
    }
    elseif ($RangeRecords.Count -gt 0 -or $MetadataOwnershipCandidates.Count -gt 0) {
        "ADDITIONAL_NAMED_OR_INTERNAL_STRUCTURE_REQUIRES_REVIEW"
    }
    else {
        "ACE_SCHEMA_EXPOSES_NO_ADDITIONAL_STRUCTURE_BEYOND_A_TO_AF"
    }

    $OwnershipStatus = "NOT_VERIFIED_STOP_RECONCILIATION"

    $Output = @(
        "PASS|GATE6_1_618456250_SOURCE_INTEGRITY_READONLY",
        ("source=" + $SourcePath),
        "report_query_family=ER_SR_1CAT_UNIV_MASTER_DETAIL",
        ("provider=" + $ProviderUsed),
        "validation_method=ACE OLE DB TABLES and COLUMNS schema metadata only",
        "business_rows_read=false",
        ("raw_schema_table_entries=" + $RawTableCount),
        ("unique_schema_entries=" + $TableRecords.Count),
        ("duplicate_schema_entries_removed=" + $DuplicateSchemaEntries),
        ("worksheet_entries=" + $WorksheetRecords.Count),
        ("named_or_internal_range_entries=" + $RangeRecords.Count),
        ("sheet1_entries=" + $Sheet1Records.Count),
        ("sheet1_provider_column_count=" + $Sheet1ColumnCount),
        ("sheet1_maximum_ordinal_position=" + $Sheet1MaximumOrdinal),
        ("metadata_ownership_candidates=" + $MetadataOwnershipCandidates.Count),
        ("provider_structure_status=" + $ProviderStructureStatus),
        ("ownership_structure_status=" + $OwnershipStatus),
        ("sha256_before=" + $HashBefore),
        ("sha256_after=" + $HashAfter),
        "source_modified=false",
        "runtime_mutated=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )

    foreach ($Record in $TableRecords) {
        $Output += (
            "STRUCTURE|name={0}|type={1}|classification={2}|provider_columns={3}|maximum_ordinal={4}|schema_error={5}" -f
            (Safe-Text $Record.table_name),
            (Safe-Text $Record.table_type),
            $Record.structure_type,
            $Record.provider_column_count,
            $Record.maximum_ordinal_position,
            (Safe-Text $Record.column_schema_error)
        )
    }

    foreach ($Candidate in $MetadataOwnershipCandidates) {
        $Output += (
            "METADATA_CANDIDATE|name={0}|classification={1}|review_required=true" -f
            (Safe-Text $Candidate.table_name),
            $Candidate.structure_type
        )
    }

    $DiagnosticPath = Join-Path $EvidenceDirectory "schema-validation-summary.txt"
    $TablesPath = Join-Path $EvidenceDirectory "tables-and-ranges-schema.json"
    $ColumnsPath = Join-Path $EvidenceDirectory "columns-schema.json"
    $MetadataPath = Join-Path $EvidenceDirectory "metadata-collections.json"
    $LineagePath = Join-Path $EvidenceDirectory "source-lineage.json"

    Set-Content -LiteralPath $DiagnosticPath -Value $Output -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$TableRecords) -Depth 6 | Set-Content -LiteralPath $TablesPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$ColumnRecords) -Depth 6 | Set-Content -LiteralPath $ColumnsPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$MetadataCollections) -Depth 4 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8

    [pscustomobject]@{
        task = "Gate 6.1 Task 6.1.3"
        report_query_family = "ER_SR_1CAT_UNIV_MASTER_DETAIL"
        source_path = $SourcePath
        source_bytes = [int64]$SourceBefore.Length
        expected_sha256 = $ExpectedHash
        sha256_before = $HashBefore
        sha256_after = $HashAfter
        last_write_utc_before = $SourceBefore.LastWriteTimeUtc.ToString("o")
        last_write_utc_after = $SourceAfter.LastWriteTimeUtc.ToString("o")
        provider = $ProviderUsed
        validation_method = "ACE OLE DB TABLES and COLUMNS schema metadata only"
        raw_schema_table_entries = $RawTableCount
        unique_schema_entries = $TableRecords.Count
        duplicate_schema_entries_removed = $DuplicateSchemaEntries
        worksheet_entries = $WorksheetRecords.Count
        named_or_internal_range_entries = $RangeRecords.Count
        sheet1_provider_column_count = $Sheet1ColumnCount
        sheet1_maximum_ordinal_position = $Sheet1MaximumOrdinal
        provider_structure_status = $ProviderStructureStatus
        ownership_structure_status = $OwnershipStatus
        business_rows_read = $false
        source_modified = $false
        runtime_mutated = $false
        department_reconciliation_performed = $false
        department_filtering_enabled = $false
        prior_v3_evidence = "evidence\gate6\gate6_1\department_header_diagnostic_v3_20261012_073344"
        prior_v3_script_sha256 = "14CA63FE991FFEDE5E6414D5976781A86C8425CBD6A4B1CF527DD217A2F8022C"
        created_utc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LineagePath -Encoding UTF8

    $ChecksumLines = foreach ($Artifact in @(
        $DiagnosticPath,
        $TablesPath,
        $ColumnsPath,
        $MetadataPath,
        $LineagePath
    )) {
        (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToUpperInvariant() +
        " *" +
        (Split-Path -Leaf $Artifact)
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

    $HashAfterFailure = "<UNAVAILABLE>"
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        try {
            $HashAfterFailure = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
        }
        catch {}
    }

    $Failure = @(
        "FAIL|GATE6_1_618456250_SCHEMA_VALIDATION",
        ("source=" + $SourcePath),
        ("sha256_before=" + $HashBefore),
        ("sha256_after_failure=" + $HashAfterFailure),
        ("error=" + $_.Exception.Message),
        ("exception_type=" + $_.Exception.GetType().FullName),
        ("invocation_position=" + (Safe-Text $_.InvocationInfo.PositionMessage)),
        ("script_stack=" + (Safe-Text $_.ScriptStackTrace)),
        "runtime_mutated=false",
        "business_rows_read=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )

    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "schema-validation-failure.txt") -Value $Failure -Encoding UTF8
    $Failure | ForEach-Object { Write-Output $_ }
    exit 1
}
