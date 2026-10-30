$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$Production = '.\ui\app.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'
$NL = [Environment]::NewLine

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "Candidate not found: $Candidate" }
$ProdHash = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash
if ($ProdHash -ne $ExpectedProductionHash) { throw "Production app.js changed unexpectedly: $ProdHash" }

$Text = Get-Content -LiteralPath $Candidate -Raw

# A. enrollmentTerm change listener: summary + question UI sync.
$AOld = '      populateStudentSurveyTerms();' + $NL + '      renderSelectedStudentSurveyTerm();' + $NL + '    });' + $NL + $NL + '    $("dfwiTerm")'
$ANew = '      populateStudentSurveyTerms();' + $NL + '      renderSelectedStudentSurveyTerm();' + $NL + '      populateStudentSurveyInstruments();' + $NL + '      renderSelectedStudentSurveyQuestions();' + $NL + '    });' + $NL + $NL + '    $("dfwiTerm")'
$ACount = ([regex]::Matches($Text,[regex]::Escape($AOld))).Count
if ($ACount -ne 1) { throw "Expected 1 enrollmentTerm Student Survey sync anchor; found $ACount" }
$Text = $Text.Replace($AOld,$ANew)

# B. Student Survey summary load after Enrollment is already available.
$BOld = '        populateStudentSurveyTerms();' + $NL + '        renderSelectedStudentSurveyTerm();' + $NL + '      } else {'
$BNew = '        populateStudentSurveyTerms();' + $NL + '        renderSelectedStudentSurveyTerm();' + $NL + '        populateStudentSurveyInstruments();' + $NL + '        renderSelectedStudentSurveyQuestions();' + $NL + '      } else {'
$BCount = ([regex]::Matches($Text,[regex]::Escape($BOld))).Count
if ($BCount -ne 1) { throw "Expected 1 Student Survey load sync anchor; found $BCount" }
$Text = $Text.Replace($BOld,$BNew)

# C. Initial Enrollment load: Enrollment is authoritative term history, so synchronize Student Survey here too.
$COld = '      renderSelectedFacultySurveyTerm();' + $NL + '    } catch (error) {'
$CNew = '      renderSelectedFacultySurveyTerm();' + $NL + $NL + '      populateStudentSurveyTerms();' + $NL + '      renderSelectedStudentSurveyTerm();' + $NL + '      populateStudentSurveyInstruments();' + $NL + '      renderSelectedStudentSurveyQuestions();' + $NL + '    } catch (error) {'
$CCount = ([regex]::Matches($Text,[regex]::Escape($COld))).Count
if ($CCount -ne 1) { throw "Expected 1 initial Enrollment completion anchor; found $CCount" }
$Text = $Text.Replace($COld,$CNew)

# D. Reset both summary and question-level Student Survey state/UI.
$DOld = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$DNew = '  function resetStudentSurvey() {' + $NL + '    state.studentSurveyController?.abort();' + $NL + '    state.studentSurveyController = null;' + $NL + '    state.studentSurvey = [];' + $NL + $NL + '    state.studentSurveyQuestionController?.abort();' + $NL + '    state.studentSurveyQuestionController = null;' + $NL + '    state.studentSurveyQuestions = [];' + $NL + $NL + '    $("studentSurveyInstrument").value = "NEW";' + $NL + '    $("studentSurveyQuestionStatus").textContent = "No Data";' + $NL + '    $("studentSurveyQuestionStatus").hidden = false;' + $NL + '    $("studentSurveyQuestions").replaceChildren();' + $NL + $NL + '    $("studentSurveyTerm").replaceChildren();'
$DCount = ([regex]::Matches($Text,[regex]::Escape($DOld))).Count
if ($DCount -ne 1) { throw "Expected 1 resetStudentSurvey anchor; found $DCount" }
$Text = $Text.Replace($DOld,$DNew)

Set-Content -LiteralPath $Candidate -Value $Text -Encoding UTF8 -NoNewline
node --check $Candidate
if ($LASTEXITCODE -ne 0) { throw 'Candidate JavaScript syntax validation failed.' }

$Updated = Get-Content -LiteralPath $Candidate -Raw
$CandidateHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
$ProdHashAfter = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash

Write-Host 'FINALIZE_V3_APPLIED=True'
Write-Host ('ENROLLMENT_TERM_SYNC_PATCHED=' + $ACount)
Write-Host ('STUDENT_SURVEY_LOAD_SYNC_PATCHED=' + $BCount)
Write-Host ('INITIAL_ENROLLMENT_SYNC_PATCHED=' + $CCount)
Write-Host ('RESET_PATCHED=' + $DCount)
Write-Host ('INSTRUMENT_LISTENER_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('studentSurveyInstrument").addEventListener("change"'))).Count)
Write-Host ('QUESTION_LOAD_CALL_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('loadStudentSurveyQuestions(course);'))).Count)
Write-Host ('QUESTION_LOAD_FUNCTION_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('async function loadStudentSurveyQuestions(course)'))).Count)
Write-Host ('QUESTION_CONTROLLER_ABORT_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('state.studentSurveyQuestionController?.abort();'))).Count)
Write-Host ('QUESTION_ARRAY_CLEAR_COUNT=' + ([regex]::Matches($Updated,[regex]::Escape('state.studentSurveyQuestions = [];'))).Count)
Write-Host ('CANDIDATE_SHA256=' + $CandidateHash)
Write-Host ('PRODUCTION_SHA256=' + $ProdHashAfter)
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
