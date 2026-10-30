$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$Production = '.\ui\app.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "Candidate not found: $Candidate" }
$ProductionHash = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash
if ($ProductionHash -ne $ExpectedProductionHash) { throw "Production app.js changed unexpectedly: $ProductionHash" }

$Text = Get-Content -LiteralPath $Candidate -Raw

$OldTermListener = '    $("studentSurveyTerm").addEventListener("change", () => {' + [Environment]::NewLine + '      renderSelectedStudentSurveyTerm();' + [Environment]::NewLine + '    });'
$NewTermListener = '    $("studentSurveyTerm").addEventListener("change", () => {' + [Environment]::NewLine + '      renderSelectedStudentSurveyTerm();' + [Environment]::NewLine + '      populateStudentSurveyInstruments();' + [Environment]::NewLine + '      renderSelectedStudentSurveyQuestions();' + [Environment]::NewLine + '    });' + [Environment]::NewLine + [Environment]::NewLine + '    $("studentSurveyInstrument").addEventListener("change", () => {' + [Environment]::NewLine + '      renderSelectedStudentSurveyQuestions();' + [Environment]::NewLine + '    });'

$OldLoad = '    loadStudentSurvey(course);'
$NewLoad = '    loadStudentSurvey(course);' + [Environment]::NewLine + '    loadStudentSurveyQuestions(course);'

$TermMatches = ([regex]::Matches($Text, [regex]::Escape($OldTermListener))).Count
$LoadMatches = ([regex]::Matches($Text, [regex]::Escape($OldLoad))).Count
if ($TermMatches -ne 1) { throw "Expected one Student Survey term listener block; found $TermMatches" }
if ($LoadMatches -ne 1) { throw "Expected one loadStudentSurvey(course) call; found $LoadMatches" }

$Text = $Text.Replace($OldTermListener, $NewTermListener)
$Text = $Text.Replace($OldLoad, $NewLoad)
Set-Content -LiteralPath $Candidate -Value $Text -Encoding UTF8 -NoNewline

node --check $Candidate
if ($LASTEXITCODE -ne 0) { throw 'Candidate JavaScript syntax validation failed.' }

$Updated = Get-Content -LiteralPath $Candidate -Raw
$TermPattern = [regex]::Escape('studentSurveyTerm").addEventListener("change"')
$InstrumentPattern = [regex]::Escape('studentSurveyInstrument").addEventListener("change"')
$LoadCallPattern = [regex]::Escape('loadStudentSurveyQuestions(course);')
$LoadFunctionPattern = [regex]::Escape('async function loadStudentSurveyQuestions(course)')

$TermCount = ([regex]::Matches($Updated, $TermPattern)).Count
$InstrumentCount = ([regex]::Matches($Updated, $InstrumentPattern)).Count
$LoadCallCount = ([regex]::Matches($Updated, $LoadCallPattern)).Count
$LoadFunctionCount = ([regex]::Matches($Updated, $LoadFunctionPattern)).Count
$CandidateHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash
$ProductionHashAfter = (Get-FileHash -LiteralPath $Production -Algorithm SHA256).Hash

Write-Host 'INTEGRATION_PATCH_APPLIED=True'
Write-Host ('TERM_LISTENER_COUNT=' + $TermCount)
Write-Host ('INSTRUMENT_LISTENER_COUNT=' + $InstrumentCount)
Write-Host ('QUESTION_LOAD_CALL_COUNT=' + $LoadCallCount)
Write-Host ('QUESTION_LOAD_FUNCTION_COUNT=' + $LoadFunctionCount)
Write-Host ('CANDIDATE_SHA256=' + $CandidateHash)
Write-Host ('PRODUCTION_SHA256=' + $ProductionHashAfter)
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
