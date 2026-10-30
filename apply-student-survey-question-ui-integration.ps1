$ErrorActionPreference = 'Stop'

$Candidate = '.\ui\app.student-survey-question.candidate.js'
$ExpectedProductionHash = '69D28E51BD956FF943987984B70562118473E667790F2D644A355AF75883359A'

if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "Candidate not found: $Candidate"
}

$ProductionHash = (Get-FileHash -LiteralPath '.\ui\app.js' -Algorithm SHA256).Hash
if ($ProductionHash -ne $ExpectedProductionHash) {
    throw "Production app.js changed unexpectedly: $ProductionHash"
}

$Text = Get-Content -LiteralPath $Candidate -Raw

$OldTermListener = @'
    $("studentSurveyTerm").addEventListener("change", () => {
      renderSelectedStudentSurveyTerm();
    });
'@

$NewTermAndInstrumentListeners = @'
    $("studentSurveyTerm").addEventListener("change", () => {
      renderSelectedStudentSurveyTerm();
      populateStudentSurveyInstruments();
      renderSelectedStudentSurveyQuestions();
    });

    $("studentSurveyInstrument").addEventListener("change", () => {
      renderSelectedStudentSurveyQuestions();
    });
'@

$OldLoadCall = @'
    loadStudentSurvey(course);
'@

$NewLoadCalls = @'
    loadStudentSurvey(course);
    loadStudentSurveyQuestions(course);
'@

$TermListenerCount = ([regex]::Matches($Text, [regex]::Escape($OldTermListener))).Count
$LoadCallCount = ([regex]::Matches($Text, [regex]::Escape($OldLoadCall))).Count

if ($TermListenerCount -ne 1) {
    throw "Expected one Student Survey term listener block; found $TermListenerCount"
}

if ($LoadCallCount -ne 1) {
    throw "Expected one loadStudentSurvey(course) call; found $LoadCallCount"
}

$Text = $Text.Replace($OldTermListener, $NewTermAndInstrumentListeners)
$Text = $Text.Replace($OldLoadCall, $NewLoadCalls)

Set-Content -LiteralPath $Candidate -Value $Text -Encoding UTF8 -NoNewline

node --check $Candidate
if ($LASTEXITCODE -ne 0) {
    throw "Candidate JavaScript syntax validation failed."
}

$Updated = Get-Content -LiteralPath $Candidate -Raw

Write-Host 'INTEGRATION_PATCH_APPLIED=True'
Write-Host "TERM_LISTENER_COUNT=$(([regex]::Matches($Updated, [regex]::Escape('$("studentSurveyTerm").addEventListener("change"'))).Count)"
Write-Host "INSTRUMENT_LISTENER_COUNT=$(([regex]::Matches($Updated, [regex]::Escape('$("studentSurveyInstrument").addEventListener("change"'))).Count)"
Write-Host "QUESTION_LOAD_CALL_COUNT=$(([regex]::Matches($Updated, [regex]::Escape('loadStudentSurveyQuestions(course);'))).Count)"
Write-Host "QUESTION_LOAD_FUNCTION_COUNT=$(([regex]::Matches($Updated, [regex]::Escape('async function loadStudentSurveyQuestions(course)'))).Count)"
Write-Host "CANDIDATE_SHA256=$((Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash)"
Write-Host "PRODUCTION_SHA256=$((Get-FileHash -LiteralPath '.\ui\app.js' -Algorithm SHA256).Hash)"
Write-Host 'CANDIDATE_SYNTAX_VALID=True'
