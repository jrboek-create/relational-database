$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$Production = '.\ui\app.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "Candidate not found: $Candidate"
}

$ProductionHash = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash
if ($ProductionHash -ne $ExpectedProductionHash) {
    throw "Production app.js changed unexpectedly: $ProductionHash"
}

$Lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $Candidate)

# Find the initial Enrollment completion path by locating its unique state assignment.
$EnrollmentStateIndex = $Lines.IndexOf('      state.enrollment = rows;')
if ($EnrollmentStateIndex -lt 0) {
    throw 'Initial Enrollment completion anchor not found.'
}

# Find the Faculty Survey render following that assignment, but only within a small bounded window.
$FacultyRenderIndex = -1
$SearchEnd = [Math]::Min($Lines.Count - 1, $EnrollmentStateIndex + 25)
for ($i = $EnrollmentStateIndex; $i -le $SearchEnd; $i++) {
    if ($Lines[$i] -eq '      renderSelectedFacultySurveyTerm();') {
        $FacultyRenderIndex = $i
        break
    }
}

if ($FacultyRenderIndex -lt 0) {
    throw 'Faculty Survey completion anchor not found after Enrollment assignment.'
}

# Refuse to duplicate the initial-load synchronization if already present.
$AlreadyPatched = $false
$CheckEnd = [Math]::Min($Lines.Count - 1, $FacultyRenderIndex + 8)
for ($i = $FacultyRenderIndex + 1; $i -le $CheckEnd; $i++) {
    if ($Lines[$i] -eq '      populateStudentSurveyTerms();') {
        $AlreadyPatched = $true
        break
    }
}

if ($AlreadyPatched) {
    throw 'Initial Enrollment Student Survey synchronization is already present; no changes made.'
}

$Insert = [string[]]@(
    '',
    '      populateStudentSurveyTerms();',
    '      renderSelectedStudentSurveyTerm();',
    '      populateStudentSurveyInstruments();',
    '      renderSelectedStudentSurveyQuestions();'
)

$Lines.InsertRange($FacultyRenderIndex + 1, $Insert)
Set-Content -LiteralPath $Candidate -Value $Lines -Encoding UTF8

node --check $Candidate
if ($LASTEXITCODE -ne 0) {
    throw 'Candidate JavaScript syntax validation failed.'
}

$Updated = Get-Content -LiteralPath $Candidate -Raw
$CandidateHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
$ProductionHashAfter = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash

$InitialSyncCount = 0
$UpdatedLines = Get-Content -LiteralPath $Candidate
$UpdatedEnrollmentIndex = $UpdatedLines.IndexOf('      state.enrollment = rows;')
$UpdatedEnd = [Math]::Min($UpdatedLines.Count - 1, $UpdatedEnrollmentIndex + 35)
for ($i = $UpdatedEnrollmentIndex; $i -le $UpdatedEnd; $i++) {
    if ($UpdatedLines[$i] -eq '      renderSelectedStudentSurveyQuestions();') {
        $InitialSyncCount++
    }
}

Write-Host 'INITIAL_ENROLLMENT_SYNC_APPLIED=True'
Write-Host ('INITIAL_ENROLLMENT_QUESTION_RENDER_COUNT=' + $InitialSyncCount)
Write-Host ('CANDIDATE_SHA256=' + $CandidateHash)
Write-Host ('PRODUCTION_SHA256=' + $ProductionHashAfter)
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
