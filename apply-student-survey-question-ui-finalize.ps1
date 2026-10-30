$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$Production = '.\ui\app.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "Candidate not found: $Candidate" }
$ProdHash = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash
if ($ProdHash -ne $ExpectedProductionHash) { throw "Production app.js changed unexpectedly: $ProdHash" }

$Text = Get-Content -LiteralPath $Candidate -Raw
$NL = [Environment]::NewLine

$OldSync = '      populateStudentSurveyTerms();' + $NL + '      renderSelectedStudentSurveyTerm();'
$NewSync = $OldSync + $NL + '      populateStudentSurveyInstruments();' + $NL + '      renderSelectedStudentSurveyQuestions();'
$SyncCount = ([regex]::Matches($Text, [regex]::Escape($OldSync))).Count
if ($SyncCount -ne 2) { throw "Expected exactly 2 Student Survey synchronization blocks; found $SyncCount" }
$Text = $Text.Replace($OldSync, $NewSync)

$OldReset = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$NewReset = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    state.studentSurveyQuestionController?.abort();' + $NL + '    state.studentSurveyQuestionController = null;' + $NL + '    state.studentSurveyQuestions = [];' + $NL + $NL + '    $("studentSurveyInstrument").value = "NEW";' + $NL + '    $("studentSurveyQuestionStatus").textContent = "No Data";' + $NL + '    $("studentSurveyQuestionStatus").hidden = false;' + $NL + '    $("studentSurveyQuestions").replaceChildren();' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$ResetCount = ([regex]::Matches($Text, [regex]::Escape($OldReset))).Count
if ($ResetCount -ne 1) { throw "Expected exactly 1 resetStudentSurvey block; found $ResetCount" }
$Text = $Text.Replace($OldReset, $NewReset)

Set-Content -LiteralPath $Candidate -Value $Text -Encoding UTF8 -NoNewline

node --check $Candidate
if ($LASTEXITCODE -ne 0) { throw 'Candidate JavaScript syntax validation failed.' }

$Updated = Get-Content -LiteralPath $Candidate -Raw
$QuestionControllerCount = ([regex]::Matches($Updated, [regex]::Escape('studentSurveyQuestionController: null'))).Count
$QuestionStateCount = ([regex]::Matches($Updated, [regex]::Escape('studentSurveyQuestions: []'))).Count
$ResetFunctionCount = ([regex]::Matches($Updated, [regex]::Escape('function resetStudentSurvey()'))).Count
$SyncRenderCount = ([regex]::Matches($Updated, [regex]::Escape('renderSelectedStudentSurveyQuestions();'))).Count
$CandidateHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
$ProdHashAfter = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash

Write-Host 'FINALIZE_PATCH_APPLIED=True'
Write-Host ('SYNC_BLOCKS_PATCHED=' + $SyncCount)
Write-Host ('RESET_BLOCKS_PATCHED=' + $ResetCount)
Write-Host ('QUESTION_CONTROLLER_STATE_COUNT=' + $QuestionControllerCount)
Write-Host ('QUESTION_ARRAY_STATE_COUNT=' + $QuestionStateCount)
Write-Host ('RESET_FUNCTION_COUNT=' + $ResetFunctionCount)
Write-Host ('QUESTION_RENDER_CALL_COUNT=' + $SyncRenderCount)
Write-Host ('CANDIDATE_SHA256=' + $CandidateHash)
Write-Host ('PRODUCTION_SHA256=' + $ProdHashAfter)
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
