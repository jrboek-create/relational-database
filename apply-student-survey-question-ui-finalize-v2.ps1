$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$Production = '.\ui\app.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'
$NL = [Environment]::NewLine

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "Candidate not found: $Candidate" }
$ProdHash = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash
if ($ProdHash -ne $ExpectedProductionHash) { throw "Production app.js changed unexpectedly: $ProdHash" }

$Text = Get-Content -LiteralPath $Candidate -Raw

# Enrollment-term listener synchronization block uses six spaces.
$EnrollmentOld = '      populateStudentSurveyTerms();' + $NL + '      renderSelectedStudentSurveyTerm();'
$EnrollmentNew = $EnrollmentOld + $NL + '      populateStudentSurveyInstruments();' + $NL + '      renderSelectedStudentSurveyQuestions();'
$EnrollmentCount = ([regex]::Matches($Text, [regex]::Escape($EnrollmentOld))).Count
if ($EnrollmentCount -ne 1) { throw "Expected exactly 1 Enrollment synchronization block; found $EnrollmentCount" }
$Text = $Text.Replace($EnrollmentOld, $EnrollmentNew)

# Initial Student Survey load synchronization block uses eight spaces.
$LoadOld = '        populateStudentSurveyTerms();' + $NL + '        renderSelectedStudentSurveyTerm();'
$LoadNew = $LoadOld + $NL + '        populateStudentSurveyInstruments();' + $NL + '        renderSelectedStudentSurveyQuestions();'
$LoadCount = ([regex]::Matches($Text, [regex]::Escape($LoadOld))).Count
if ($LoadCount -ne 1) { throw "Expected exactly 1 Student Survey load synchronization block; found $LoadCount" }
$Text = $Text.Replace($LoadOld, $LoadNew)

$ResetOld = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$ResetNew = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    state.studentSurveyQuestionController?.abort();' + $NL + '    state.studentSurveyQuestionController = null;' + $NL + '    state.studentSurveyQuestions = [];' + $NL + $NL + '    $("studentSurveyInstrument").value = "NEW";' + $NL + '    $("studentSurveyQuestionStatus").textContent = "No Data";' + $NL + '    $("studentSurveyQuestionStatus").hidden = false;' + $NL + '    $("studentSurveyQuestions").replaceChildren();' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$ResetCount = ([regex]::Matches($Text, [regex]::Escape($ResetOld))).Count
if ($ResetCount -ne 1) { throw "Expected exactly 1 resetStudentSurvey block; found $ResetCount" }
$Text = $Text.Replace($ResetOld, $ResetNew)

Set-Content -LiteralPath $Candidate -Value $Text -Encoding UTF8 -NoNewline
node --check $Candidate
if ($LASTEXITCODE -ne 0) { throw 'Candidate JavaScript syntax validation failed.' }

$Updated = Get-Content -LiteralPath $Candidate -Raw
$CandidateHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
$ProdHashAfter = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash

Write-Host 'FINALIZE_V2_APPLIED=True'
Write-Host ('ENROLLMENT_SYNC_BLOCKS_PATCHED=' + $EnrollmentCount)
Write-Host ('LOAD_SYNC_BLOCKS_PATCHED=' + $LoadCount)
Write-Host ('RESET_BLOCKS_PATCHED=' + $ResetCount)
Write-Host ('QUESTION_CONTROLLER_RESET_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('state.studentSurveyQuestionController?.abort();'))).Count)
Write-Host ('QUESTION_ARRAY_RESET_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('state.studentSurveyQuestions = [];'))).Count)
Write-Host ('INSTRUMENT_LISTENER_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('studentSurveyInstrument").addEventListener("change"'))).Count)
Write-Host ('QUESTION_LOAD_CALL_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('loadStudentSurveyQuestions(course);'))).Count)
Write-Host ('CANDIDATE_SHA256=' + $CandidateHash)
Write-Host ('PRODUCTION_SHA256=' + $ProdHashAfter)
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
