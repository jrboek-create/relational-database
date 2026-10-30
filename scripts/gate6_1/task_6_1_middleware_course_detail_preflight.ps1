[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepositoryRoot = "C:\Directus\relational-repository"
$EvidenceRoot = Join-Path $RepositoryRoot "evidence\gate6\gate6_1"
$EvidenceDirectory = Join-Path $EvidenceRoot ("middleware_course_detail_preflight_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

function Get-RelativePath {
    param([string]$FullName)
    $Root = $RepositoryRoot.TrimEnd("\") + "\"
    if ($FullName.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($Root.Length)
    }
    return $FullName
}

function Get-FileRecord {
    param([IO.FileInfo]$File,[string]$Category)
    return [pscustomobject]@{
        category = $Category
        relative_path = Get-RelativePath $File.FullName
        bytes = [int64]$File.Length
        last_write_utc = $File.LastWriteTimeUtc.ToString("o")
        sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

try {
    $AllowedExtensions = @(
        ".js",".mjs",".cjs",".ts",".tsx",".json",".sql",
        ".yml",".yaml",".conf",".ps1",".md"
    )

    $SearchRoots = @(
        "middleware",
        "ui",
        "nginx",
        "database",
        "db",
        "sql",
        "reporting"
    )

    $CodeFiles = @()

    foreach ($RelativeRoot in $SearchRoots) {
        $SearchRoot = Join-Path $RepositoryRoot $RelativeRoot
        if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) { continue }

        $CodeFiles += @(
            Get-ChildItem -LiteralPath $SearchRoot -File -Recurse -ErrorAction Stop |
            Where-Object {
                $AllowedExtensions -contains $_.Extension.ToLowerInvariant() -and
                $_.Length -le 5242880 -and
                $_.FullName -notmatch "[\\/](node_modules|\.git|\.secrets|evidence|dist|build|coverage)[\\/]"
            }
        )
    }

    foreach ($RootFileName in @(
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
        "package.json"
    )) {
        $RootFile = Join-Path $RepositoryRoot $RootFileName
        if (Test-Path -LiteralPath $RootFile -PathType Leaf) {
            $CodeFiles += Get-Item -LiteralPath $RootFile
        }
    }

    $CodeFiles = @($CodeFiles | Sort-Object FullName -Unique)

    if ($CodeFiles.Count -eq 0) {
        throw "No middleware, UI, NGINX, SQL, reporting, or Compose artifacts were found."
    }

    $Patterns = @(
        [pscustomobject]@{ name="FrozenCoursesRoute"; expression="/api/courses" },
        [pscustomobject]@{ name="PurposeBuiltCourseDetailRoute"; expression="/api/(course|catalog)/courses?[/`"][^ `"]*(\:id|\{id\}|course_id)" },
        [pscustomobject]@{ name="CourseCatalogDetailProjection"; expression="course_catalog_detail" },
        [pscustomobject]@{ name="CourseFilterIndexProjection"; expression="course_filter_index" },
        [pscustomobject]@{ name="CurrentCatalogProjection"; expression="course_current_catalog" },
        [pscustomobject]@{ name="FrozenSevenFieldContract"; expression="course_id|university_course_id|course_code|course_title|source_system_code|report_refresh_run_id|report_as_of_utc" },
        [pscustomobject]@{ name="CatalogDetailFields"; expression="course_description|description|course_goals|goals|learning_objectives|learning_outcomes|outcomes" },
        [pscustomobject]@{ name="CollegeFields"; expression="college_code|college_name|college" },
        [pscustomobject]@{ name="DepartmentQuarantineReview"; expression="academic_unit|department_filter|department_name|WW Department|WW Acad Org" },
        [pscustomobject]@{ name="RequestIdControl"; expression="request.?id|correlation.?id|x-request-id" },
        [pscustomobject]@{ name="SafeErrorControl"; expression="safe.?error|downstream|internal server error|error envelope" },
        [pscustomobject]@{ name="AuditControl"; expression="audit|request.?log|logger" },
        [pscustomobject]@{ name="DirectusAccess"; expression="DIRECTUS|/items/|directus" },
        [pscustomobject]@{ name="PaginationControl"; expression="page_size|pageSize|limit|offset|pagination" },
        [pscustomobject]@{ name="FilterAllowlist"; expression="allowlist|allowedFilters|allowed_filters|filterKeys|filter_keys" },
        [pscustomobject]@{ name="SortAllowlist"; expression="allowedSort|allowed_sort|sortKeys|sort_keys" }
    )

    $MatchRecords = @()
    $MatchedFileMap = @{}

    foreach ($File in $CodeFiles) {
        foreach ($Pattern in $Patterns) {
            $Matches = @(
                Select-String `
                    -LiteralPath $File.FullName `
                    -Pattern $Pattern.expression `
                    -AllMatches `
                    -CaseSensitive:$false `
                    -ErrorAction SilentlyContinue
            )

            foreach ($Match in $Matches) {
                $RelativePath = Get-RelativePath $File.FullName
                $MatchedFileMap[$File.FullName] = $true

                $MatchRecords += [pscustomobject]@{
                    pattern = $Pattern.name
                    relative_path = $RelativePath
                    line_number = [int]$Match.LineNumber
                    match_count_on_line = [int]$Match.Matches.Count
                    source_text_included = $false
                }
            }
        }
    }

    $ArtifactRecords = @()

    foreach ($FileName in @($MatchedFileMap.Keys | Sort-Object)) {
        $ArtifactRecords += Get-FileRecord (Get-Item -LiteralPath $FileName) "PATTERN_MATCHED_ARTIFACT"
    }

    $KeyRelativePaths = @(
        "middleware\package.json",
        "middleware\src\server.js",
        "middleware\src\app.js",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
        "nginx\nginx.conf"
    )

    foreach ($RelativePath in $KeyRelativePaths) {
        $FullPath = Join-Path $RepositoryRoot $RelativePath
        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { continue }

        if (@($ArtifactRecords | Where-Object { $_.relative_path -ieq $RelativePath }).Count -eq 0) {
            $ArtifactRecords += Get-FileRecord (Get-Item -LiteralPath $FullPath) "KEY_ARTIFACT"
        }
    }

    $RouteFiles = @(
        $CodeFiles |
        Where-Object {
            $_.FullName -match "[\\/]middleware[\\/].*(route|server|app|controller|service)" -and
            $_.Extension -match "^\.(js|mjs|cjs|ts)$"
        } |
        Sort-Object FullName
    )

    $RouteRecords = @()
    foreach ($RouteFile in $RouteFiles) {
        $RouteRecords += Get-FileRecord $RouteFile "MIDDLEWARE_ROUTE_OR_SERVICE"
    }

    $PackageRecords = @()
    $PackageFiles = @($CodeFiles | Where-Object { $_.Name -eq "package.json" })

    foreach ($PackageFile in $PackageFiles) {
        try {
            $Package = Get-Content -LiteralPath $PackageFile.FullName -Raw | ConvertFrom-Json

            $Scripts = @()
            if ($null -ne $Package.scripts) {
                $Scripts = @($Package.scripts.PSObject.Properties.Name | Sort-Object)
            }

            $Dependencies = @()
            if ($null -ne $Package.dependencies) {
                $Dependencies = @($Package.dependencies.PSObject.Properties.Name | Sort-Object)
            }

            $DevelopmentDependencies = @()
            if ($null -ne $Package.devDependencies) {
                $DevelopmentDependencies = @($Package.devDependencies.PSObject.Properties.Name | Sort-Object)
            }

            $PackageRecords += [pscustomobject]@{
                relative_path = Get-RelativePath $PackageFile.FullName
                package_name = [string]$Package.name
                package_version = [string]$Package.version
                scripts = $Scripts
                dependencies = $Dependencies
                development_dependencies = $DevelopmentDependencies
                manifest_parse_status = "PASS"
            }
        }
        catch {
            $PackageRecords += [pscustomobject]@{
                relative_path = Get-RelativePath $PackageFile.FullName
                package_name = $null
                package_version = $null
                scripts = @()
                dependencies = @()
                development_dependencies = @()
                manifest_parse_status = "FAIL: " + $_.Exception.Message
            }
        }
    }

    $NodeSyntaxRecords = @()
    $NodeCommand = Get-Command node -ErrorAction SilentlyContinue

    if ($null -ne $NodeCommand) {
        foreach ($RouteFile in @($RouteFiles | Where-Object { $_.Extension -match "^\.(js|mjs|cjs)$" })) {
            $SyntaxOutput = @(& $NodeCommand.Source --check $RouteFile.FullName 2>&1)
            $SyntaxExitCode = $LASTEXITCODE

            $NodeSyntaxRecords += [pscustomobject]@{
                relative_path = Get-RelativePath $RouteFile.FullName
                node_check_exit_code = $SyntaxExitCode
                syntax_status = if ($SyntaxExitCode -eq 0) { "PASS" } else { "FAIL" }
                diagnostic = if ($SyntaxExitCode -eq 0) { $null } else { ($SyntaxOutput -join " ") }
            }
        }
    }

    $GitStatusLines = @()
    $GitBranch = "<GIT_UNAVAILABLE>"
    $GitHead = "<GIT_UNAVAILABLE>"
    $GitCommand = Get-Command git -ErrorAction SilentlyContinue

    if ($null -ne $GitCommand -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot ".git") -PathType Container)) {
        $GitBranch = (@(& $GitCommand.Source -C $RepositoryRoot branch --show-current 2>$null) -join "").Trim()
        $GitHead = (@(& $GitCommand.Source -C $RepositoryRoot rev-parse HEAD 2>$null) -join "").Trim()
        $GitStatusLines = @(& $GitCommand.Source -C $RepositoryRoot status --porcelain=v1 --untracked-files=all 2>$null)
    }

    $ComposeServices = @()
    $ComposeRunningServices = @()
    $DockerCommand = Get-Command docker -ErrorAction SilentlyContinue

    if ($null -ne $DockerCommand) {
        try {
            $ComposeServices = @(& $DockerCommand.Source compose --project-directory $RepositoryRoot config --services 2>$null)
            $ComposeRunningServices = @(& $DockerCommand.Source compose --project-directory $RepositoryRoot ps --status running --services 2>$null)
        }
        catch {
            $ComposeServices = @("COMPOSE_DISCOVERY_FAILED")
            $ComposeRunningServices = @()
        }
    }

    $FrozenRouteMatches = @($MatchRecords | Where-Object { $_.pattern -eq "FrozenCoursesRoute" })
    $DetailRouteMatches = @($MatchRecords | Where-Object { $_.pattern -eq "PurposeBuiltCourseDetailRoute" })
    $DetailProjectionMatches = @($MatchRecords | Where-Object { $_.pattern -eq "CourseCatalogDetailProjection" })
    $FilterProjectionMatches = @($MatchRecords | Where-Object { $_.pattern -eq "CourseFilterIndexProjection" })
    $DepartmentMatches = @($MatchRecords | Where-Object { $_.pattern -eq "DepartmentQuarantineReview" })

    $Summary = @(
        "PASS|GATE6_1_MIDDLEWARE_COURSE_DETAIL_PREFLIGHT",
        ("repository=" + $RepositoryRoot),
        "inspection_mode=read-only application artifact inspection",
        ("code_files_scanned=" + $CodeFiles.Count),
        ("middleware_route_or_service_files=" + $RouteRecords.Count),
        ("pattern_locations=" + $MatchRecords.Count),
        ("matched_artifacts_fingerprinted=" + $ArtifactRecords.Count),
        ("package_manifests=" + $PackageRecords.Count),
        ("node_syntax_checks=" + $NodeSyntaxRecords.Count),
        ("frozen_api_courses_locations=" + $FrozenRouteMatches.Count),
        ("existing_purpose_built_detail_route_locations=" + $DetailRouteMatches.Count),
        ("course_catalog_detail_projection_locations=" + $DetailProjectionMatches.Count),
        ("course_filter_index_projection_locations=" + $FilterProjectionMatches.Count),
        ("department_related_code_locations_quarantined_for_review=" + $DepartmentMatches.Count),
        ("git_branch=" + $GitBranch),
        ("git_head=" + $GitHead),
        ("git_status_entries=" + $GitStatusLines.Count),
        ("compose_services_discovered=" + $ComposeServices.Count),
        ("compose_running_services=" + $ComposeRunningServices.Count),
        "source_text_printed=false",
        "secrets_scanned=false",
        "secrets_printed=false",
        "business_rows_read=false",
        "database_queried=false",
        "runtime_mutated=false",
        "existing_api_courses_modified=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false",
        "next_decision_basis=current repository artifacts only"
    )

    $SummaryPath = Join-Path $EvidenceDirectory "preflight-summary.txt"
    $ArtifactsPath = Join-Path $EvidenceDirectory "artifact-inventory.json"
    $RoutesPath = Join-Path $EvidenceDirectory "middleware-route-files.json"
    $PatternsPath = Join-Path $EvidenceDirectory "pattern-locations.json"
    $PackagesPath = Join-Path $EvidenceDirectory "package-manifests.json"
    $NodePath = Join-Path $EvidenceDirectory "node-syntax-checks.json"
    $GitPath = Join-Path $EvidenceDirectory "git-status-porcelain.txt"
    $ComposePath = Join-Path $EvidenceDirectory "compose-services.txt"
    $LineagePath = Join-Path $EvidenceDirectory "preflight-lineage.json"

    Set-Content -LiteralPath $SummaryPath -Value $Summary -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$ArtifactRecords) -Depth 6 | Set-Content -LiteralPath $ArtifactsPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$RouteRecords) -Depth 6 | Set-Content -LiteralPath $RoutesPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$MatchRecords) -Depth 6 | Set-Content -LiteralPath $PatternsPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$PackageRecords) -Depth 8 | Set-Content -LiteralPath $PackagesPath -Encoding UTF8
    ConvertTo-Json -InputObject ([object[]]$NodeSyntaxRecords) -Depth 6 | Set-Content -LiteralPath $NodePath -Encoding UTF8
    Set-Content -LiteralPath $GitPath -Value $GitStatusLines -Encoding UTF8

    @(
        "ALL_SERVICES",
        ($ComposeServices -join ","),
        "RUNNING_SERVICES",
        ($ComposeRunningServices -join ",")
    ) | Set-Content -LiteralPath $ComposePath -Encoding UTF8

    [pscustomobject]@{
        task = "Gate 6.1 reusable course-information middleware preflight"
        repository = $RepositoryRoot
        preserves_frozen_api_courses_contract = $true
        intended_next_capability = "purpose-built course lookup/detail endpoint over approved reporting structures"
        department_status = "QUARANTINED_UNRESOLVED"
        department_filtering_enabled = $false
        department_reconciliation_performed = $false
        database_queried = $false
        business_rows_read = $false
        runtime_mutated = $false
        secrets_scanned = $false
        source_text_included = $false
        created_utc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LineagePath -Encoding UTF8

    $EvidenceArtifacts = @(
        $SummaryPath,
        $ArtifactsPath,
        $RoutesPath,
        $PatternsPath,
        $PackagesPath,
        $NodePath,
        $GitPath,
        $ComposePath,
        $LineagePath
    )

    $ChecksumLines = foreach ($Artifact in $EvidenceArtifacts) {
        (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToUpperInvariant() +
        " *" +
        (Split-Path -Leaf $Artifact)
    }

    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "SHA256SUMS.txt") -Value $ChecksumLines -Encoding ASCII

    $Summary | ForEach-Object { Write-Output $_ }

    foreach ($Record in @($MatchRecords | Sort-Object pattern,relative_path,line_number)) {
        Write-Output (
            "LOCATION|pattern={0}|file={1}|line={2}|source_text_included=false" -f
            $Record.pattern,
            $Record.relative_path,
            $Record.line_number
        )
    }

    foreach ($Record in $NodeSyntaxRecords) {
        Write-Output (
            "NODE_CHECK|file={0}|status={1}|exit_code={2}" -f
            $Record.relative_path,
            $Record.syntax_status,
            $Record.node_check_exit_code
        )
    }

    Write-Output ("evidence_directory=" + $EvidenceDirectory)
    exit 0
}
catch {
    $Failure = @(
        "FAIL|GATE6_1_MIDDLEWARE_COURSE_DETAIL_PREFLIGHT",
        ("error=" + $_.Exception.Message),
        ("exception_type=" + $_.Exception.GetType().FullName),
        ("invocation_position=" + ($_.InvocationInfo.PositionMessage -replace "\r?\n"," ")),
        ("script_stack=" + ($_.ScriptStackTrace -replace "\r?\n"," ")),
        "runtime_mutated=false",
        "database_queried=false",
        "department_reconciliation_performed=false",
        "department_filtering_enabled=false"
    )

    Set-Content -LiteralPath (Join-Path $EvidenceDirectory "preflight-failure.txt") -Value $Failure -Encoding UTF8
    $Failure | ForEach-Object { Write-Output $_ }
    exit 1
}
