[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepositoryRoot = "C:\Directus\relational-repository"
$CandidateFileName = "ER_SR_1CAT_UNIV_MASTER_DETAIL_1512061533.xlsx"
$EvidenceRoot = Join-Path $RepositoryRoot "evidence\gate6\gate6_1"
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$EvidenceDirectory = Join-Path $EvidenceRoot ("department_candidate_source_validation_" + $RunStamp)
$Archive = $null
$HashBefore = "<NOT_COMPUTED>"
$SourcePath = "<NOT_LOCATED>"

function Get-ColumnNumber {
    param([string]$Letters)
    $Number = 0
    foreach ($Character in $Letters.ToUpperInvariant().ToCharArray()) {
        $Number = ($Number * 26) + ([int]$Character - [int][char]"A" + 1)
    }
    return $Number
}

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
    $Value = $Value -replace "[^a-z0-9]+", " "
    $Aliases = @{
        "univ"="university"; "eff"="effective"; "ww"="worldwide";
        "acad"="academic"; "org"="organization"; "dept"="department"
    }
    $Expanded = foreach ($Token in @($Value.Trim() -split "\s+" | Where-Object { $_ })) {
        if ($Aliases.ContainsKey($Token)) { $Aliases[$Token] } else { $Token }
    }
    return (($Expanded -join " ") -replace "\s+", " ").Trim()
}

function Load-ZipXml {
    param([object]$Zip,[string]$EntryName)
    $Entry = $Zip.GetEntry($EntryName)
    if ($null -eq $Entry) { return $null }
    $Stream = $null
    try {
        $Stream = $Entry.Open()
        $Document = New-Object Xml.XmlDocument
        $Document.PreserveWhitespace = $false
        $Document.Load($Stream)
        return $Document
    }
    finally {
        if ($null -ne $Stream) { $Stream.Dispose() }
    }
}

function Get-CellText {
    param([Xml.XmlElement]$Cell,[string[]]$SharedStrings,[Xml.XmlNamespaceManager]$NamespaceManager)
    $Type = [string]$Cell.GetAttribute("t")
    if ($Type -eq "s") {
        $ValueNode = $Cell.SelectSingleNode("d:v",$NamespaceManager)
        if ($null -eq $ValueNode) { return "" }
        $Index = 0
        if (-not [int]::TryParse($ValueNode.InnerText,[ref]$Index)) { return "" }
        if ($Index -lt 0 -or $Index -ge $SharedStrings.Count) { return "" }
        return [string]$SharedStrings[$Index]
    }
    if ($Type -eq "inlineStr") {
        return (($Cell.SelectNodes("d:is//d:t",$NamespaceManager) | ForEach-Object { $_.InnerText }) -join "")
    }
    $ValueNode = $Cell.SelectSingleNode("d:v",$NamespaceManager)
    if ($null -eq $ValueNode) { return "" }
    return [string]$ValueNode.InnerText
}

function Safe-Text {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return (($Text -replace "\r?\n"," ") -replace "\|","<PIPE>")
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    $Matches = @(
        Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse -Filter $CandidateFileName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ceq $CandidateFileName }
    )

    if ($Matches.Count -eq 0) {
        $ControlledTarget = Join-Path $RepositoryRoot ("imports_hold\" + $CandidateFileName)
        $StopLines = @(
            "STOP|GATE6_1_CANDIDATE_SOURCE_NOT_LOCAL",
            ("candidate_filename=" + $CandidateFileName),
            "report_query_family=ER_SR_1CAT_UNIV_MASTER_DETAIL",
            "enterprise_provenance=Attached to Re: One Catalog received 15 January 2026; described as latest export after request for current official Catalog",
            ("controlled_staging_target=" + $ControlledTarget),
            "source_opened=false",
            "header_inspected=false",
            "runtime_mutated=false",
            "department_reconciliation_performed=false",
            "department_filtering_enabled=false"
        )
        $StopPath = Join-Path $EvidenceDirectory "candidate-source-not-local.txt"
        Set-Content -LiteralPath $StopPath -Value $StopLines -Encoding UTF8
        $StopHash = (Get-FileHash -LiteralPath $StopPath -Algorithm SHA256).Hash.ToUpperInvariant()
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory "SHA256SUMS.txt") -Value ($StopHash + " *candidate-source-not-local.txt") -Encoding ASCII
        $StopLines | ForEach-Object { Write-Output $_ }
        Write-Output ("evidence_directory=" + $EvidenceDirectory)
        exit 2
    }

    if ($Matches.Count -ne 1) {
        throw ("Expected one exact local candidate; observed " + $Matches.Count + ". Resolve duplicate copies before validation.")
    }

    $SourcePath = $Matches[0].FullName
    $SourceBefore = Get-Item -LiteralPath $SourcePath
    $HashBefore = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [IO.Compression.ZipFile]::OpenRead($SourcePath)

    $WorkbookXml = Load-ZipXml $Archive "xl/workbook.xml"
    $RelationshipsXml = Load-ZipXml $Archive "xl/_rels/workbook.xml.rels"
    if ($null -eq $WorkbookXml -or $null -eq $RelationshipsXml) {
        throw "Required Open XML workbook metadata was not found."
    }

    $WorkbookNs = New-Object Xml.XmlNamespaceManager($WorkbookXml.NameTable)
    $WorkbookNs.AddNamespace("d","http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    $WorkbookNs.AddNamespace("r","http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    $Sheets = @($WorkbookXml.SelectNodes("/d:workbook/d:sheets/d:sheet",$WorkbookNs))
    if ($Sheets.Count -eq 0) { throw "The workbook contains no worksheets." }

    $SelectedSheet = @($Sheets | Where-Object { $_.GetAttribute("name") -eq "sheet1" } | Select-Object -First 1)
    if ($SelectedSheet.Count -eq 0) { $SelectedSheet = @($Sheets[0]) }
    $SheetName = [string]$SelectedSheet[0].GetAttribute("name")
    $RelationshipId = [string]$SelectedSheet[0].GetAttribute("id","http://schemas.openxmlformats.org/officeDocument/2006/relationships")

    $RelationshipNs = New-Object Xml.XmlNamespaceManager($RelationshipsXml.NameTable)
    $RelationshipNs.AddNamespace("p","http://schemas.openxmlformats.org/package/2006/relationships")
    $Relationship = $RelationshipsXml.SelectSingleNode("/p:Relationships/p:Relationship[@Id=""" + $RelationshipId + """]",$RelationshipNs)
    if ($null -eq $Relationship) { throw "Worksheet relationship could not be resolved." }

    $Target = [string]$Relationship.GetAttribute("Target")
    $WorksheetEntry = if ($Target.StartsWith("/")) { $Target.TrimStart("/") } else { "xl/" + $Target.TrimStart("/") }
    $WorksheetEntry = $WorksheetEntry.Replace("\","/")
    $WorksheetXml = Load-ZipXml $Archive $WorksheetEntry
    if ($null -eq $WorksheetXml) { throw ("Worksheet XML was not found: " + $WorksheetEntry) }

    $SharedStrings = @()
    $SharedXml = Load-ZipXml $Archive "xl/sharedStrings.xml"
    if ($null -ne $SharedXml) {
        $SharedNs = New-Object Xml.XmlNamespaceManager($SharedXml.NameTable)
        $SharedNs.AddNamespace("d","http://schemas.openxmlformats.org/spreadsheetml/2006/main")
        foreach ($Item in $SharedXml.SelectNodes("/d:sst/d:si",$SharedNs)) {
            $SharedStrings += (($Item.SelectNodes(".//d:t",$SharedNs) | ForEach-Object { $_.InnerText }) -join "")
        }
    }

    $WorksheetNs = New-Object Xml.XmlNamespaceManager($WorksheetXml.NameTable)
    $WorksheetNs.AddNamespace("d","http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    $HeaderRow = $WorksheetXml.SelectSingleNode("/d:worksheet/d:sheetData/d:row[@r=""1""]",$WorksheetNs)
    if ($null -eq $HeaderRow) { throw "Header row 1 was not found. No alternate/business row was inspected." }

    $RawHeaders = @{}
    $MaximumColumn = 0
    foreach ($Cell in $HeaderRow.SelectNodes("d:c",$WorksheetNs)) {
        $Reference = [string]$Cell.GetAttribute("r")
        if ($Reference -notmatch "^([A-Z]+)1$") { continue }
        $ColumnNumber = Get-ColumnNumber $Matches[1]
        $RawHeaders[$ColumnNumber] = Get-CellText $Cell $SharedStrings $WorksheetNs
        if ($ColumnNumber -gt $MaximumColumn) { $MaximumColumn = $ColumnNumber }
    }
    if ($MaximumColumn -eq 0) { throw "Row 1 exposed no header cells." }

    $Headers = @()
    for ($Column = 1; $Column -le $MaximumColumn; $Column++) {
        $Actual = if ($RawHeaders.ContainsKey($Column)) { [string]$RawHeaders[$Column] } else { "" }
        $Headers += [pscustomobject]@{
            column_number = $Column
            column_letter = Get-ColumnName $Column
            cell_address = (Get-ColumnName $Column) + "1"
            actual_label = $Actual
            normalized_label = Normalize-Header $Actual
            read_status = if ($RawHeaders.ContainsKey($Column)) { "CELL_PRESENT" } else { "POSITION_BLANK" }
        }
    }

    $Archive.Dispose()
    $Archive = $null

    $HashAfter = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
    $SourceAfter = Get-Item -LiteralPath $SourcePath
    if ($HashBefore -ne $HashAfter) { throw ("Source changed. Before=" + $HashBefore + "; After=" + $HashAfter) }

    $Required = @(
        [pscustomobject]@{ name="Univ Course ID"; normalized="university course id" },
        [pscustomobject]@{ name="Eff Date"; normalized="effective date" },
        [pscustomobject]@{ name="WW Acad Org"; normalized="worldwide academic organization" },
        [pscustomobject]@{ name="WW Department Name"; normalized="worldwide department name" }
    )

    $RequiredResults = @()
    foreach ($Field in $Required) {
        $FieldMatches = @($Headers | Where-Object { $_.normalized_label -eq $Field.normalized })
        $Status = if ($FieldMatches.Count -eq 1) { "VERIFIED_UNIQUE" } elseif ($FieldMatches.Count -gt 1) { "DUPLICATE_HEADER" } else { "NOT_FOUND" }
        $RequiredResults += [pscustomobject]@{
            required_field = $Field.name
            normalized_field = $Field.normalized
            status = $Status
            match_count = $FieldMatches.Count
            columns = @($FieldMatches | ForEach-Object { $_.column_letter })
        }
    }

    $SignaturePass = (@($RequiredResults | Where-Object { $_.status -ne "VERIFIED_UNIQUE" }).Count -eq 0)
    $SignatureStatus = if ($SignaturePass) { "PASS|OWNERSHIP_SIGNATURE_VERIFIED" } else { "FAIL|OWNERSHIP_SIGNATURE_NOT_VERIFIED" }

    $Output = @(
        "PASS|CANDIDATE_SOURCE_INTEGRITY_READONLY",
        $SignatureStatus,
        ("source=" + $SourcePath),
        "report_query_family=ER_SR_1CAT_UNIV_MASTER_DETAIL",
        "enterprise_provenance=Attached to Re: One Catalog received 15 January 2026; described as latest export after request for current official Catalog",
        "read_method=Open XML ZIP package read-only",
        ("worksheet_count=" + $Sheets.Count),
        ("inspected_sheet=" + $SheetName),
        "inspected_row=1",
        ("header_structural_width=" + $MaximumColumn),
        ("sha256_before=" + $HashBefore),
        ("sha256_after=" + $HashAfter),
        "source_modified=false",
        "runtime_mutated=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )

    foreach ($Header in $Headers) {
        $Actual = Safe-Text $Header.actual_label
        $Normalized = Safe-Text $Header.normalized_label
        if ([string]::IsNullOrWhiteSpace($Actual)) { $Actual = "<BLANK>" }
        if ([string]::IsNullOrWhiteSpace($Normalized)) { $Normalized = "<BLANK>" }
        $Output += ("HEADER|{0:D2}|{1}|cell={2}|actual={3}|normalized={4}|status={5}" -f $Header.column_number,$Header.column_letter,$Header.cell_address,$Actual,$Normalized,$Header.read_status)
    }

    foreach ($Result in $RequiredResults) {
        $Output += ("REQUIRED_FIELD|{0}|status={1}|match_count={2}|columns={3}" -f $Result.required_field,$Result.status,$Result.match_count,($Result.columns -join ","))
    }

    $DiagnosticPath = Join-Path $EvidenceDirectory "candidate-source-header-validation.txt"
    $HeadersPath = Join-Path $EvidenceDirectory "candidate-row-1-headers.json"
    $SignaturePath = Join-Path $EvidenceDirectory "ownership-signature.json"
    $LineagePath = Join-Path $EvidenceDirectory "source-lineage.json"

    Set-Content -LiteralPath $DiagnosticPath -Value $Output -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$Headers) -Depth 6 | Set-Content -LiteralPath $HeadersPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$RequiredResults) -Depth 6 | Set-Content -LiteralPath $SignaturePath -Encoding UTF8

    [pscustomobject]@{
        report_query_family = "ER_SR_1CAT_UNIV_MASTER_DETAIL"
        candidate_filename = $CandidateFileName
        source_path = $SourcePath
        source_bytes = [int64]$SourceBefore.Length
        sha256_before = $HashBefore
        sha256_after = $HashAfter
        last_write_utc_before = $SourceBefore.LastWriteTimeUtc.ToString("o")
        last_write_utc_after = $SourceAfter.LastWriteTimeUtc.ToString("o")
        enterprise_email_subject = "Re: One Catalog"
        enterprise_email_received = "15 January 2026 10:05 PM"
        enterprise_context = "Latest export following request for current version of official Catalog"
        read_method = "Open XML ZIP package read-only"
        worksheet_count = $Sheets.Count
        inspected_sheet = $SheetName
        inspected_row = 1
        header_structural_width = $MaximumColumn
        ownership_signature_pass = $SignaturePass
        source_modified = $false
        runtime_mutated = $false
        department_reconciliation_performed = $false
        department_filtering_enabled = $false
        created_utc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LineagePath -Encoding UTF8

    $ChecksumLines = foreach ($Artifact in @($DiagnosticPath,$HeadersPath,$SignaturePath,$LineagePath)) {
        (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToUpperInvariant() + " *" + (Split-Path -Leaf $Artifact)
    }
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "SHA256SUMS.txt") -Value $ChecksumLines -Encoding ASCII

    $Output | ForEach-Object { Write-Output $_ }
    Write-Output ("evidence_directory=" + $EvidenceDirectory)
    exit 0
}
catch {
    if ($null -ne $Archive) { try { $Archive.Dispose() } catch {} }
    $FailureHash = "<UNAVAILABLE>"
    if ($SourcePath -ne "<NOT_LOCATED>" -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        try { $FailureHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant() } catch {}
    }
    $Failure = @(
        "FAIL|GATE6_1_CANDIDATE_SOURCE_VALIDATION",
        ("source=" + $SourcePath),
        ("sha256_before=" + $HashBefore),
        ("sha256_after_failure=" + $FailureHash),
        ("error=" + $_.Exception.Message),
        ("invocation_position=" + (Safe-Text $_.InvocationInfo.PositionMessage)),
        "runtime_mutated=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "candidate-validation-failure.txt") -Value $Failure -Encoding UTF8
    $Failure | ForEach-Object { Write-Output $_ }
    exit 1
}
