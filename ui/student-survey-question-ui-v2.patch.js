/* Student Survey question-level UI additive patch artifact.
   Intended to be inserted before setGradeCount() in app.js after the
   separately validated state/listener/load call changes are applied. */

async function loadStudentSurveyQuestions(course) {
  state.studentSurveyQuestionController?.abort();
  state.studentSurveyQuestionController = null;
  state.studentSurveyQuestions = [];

  if (!course.course_id) {
    renderSelectedStudentSurveyQuestions();
    return;
  }

  state.studentSurveyQuestionController = new AbortController();
  const controller = state.studentSurveyQuestionController;
  const timer = setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(
      `/api/courses/${encodeURIComponent(course.course_id)}/student-survey/questions`,
      {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: controller.signal
      }
    );

    const payload = await json(response);

    if (!response.ok || payload.ok === false) {
      throw new Error("student-survey-questions");
    }

    state.studentSurveyQuestions = Array.isArray(payload.data)
      ? payload.data
      : [];

    populateStudentSurveyInstruments();
    renderSelectedStudentSurveyQuestions();
  } catch (error) {
    if (error?.name !== "AbortError") {
      $("studentSurveyQuestionStatus").textContent =
        "Student Survey question results are temporarily unavailable.";
      $("studentSurveyQuestionStatus").hidden = false;
    }
    $("studentSurveyQuestions").replaceChildren();
  } finally {
    clearTimeout(timer);
  }
}

function populateStudentSurveyInstruments() {
  const selector = $("studentSurveyInstrument");
  const previous = selector.value;

  const available = new Set(
    state.studentSurveyQuestions
      .map(row => row.survey_version)
      .filter(version => version === "NEW" || version === "OLD")
  );

  selector.replaceChildren();

  ["NEW", "OLD"].forEach(version => {
    const option = document.createElement("option");
    option.value = version;
    option.textContent = version;
    option.disabled = !available.has(version);
    selector.append(option);
  });

  const enabled = Array.from(selector.options).filter(option => !option.disabled);
  const previousEnabled = enabled.some(option => option.value === previous);

  if (previousEnabled) {
    selector.value = previous;
  } else if (enabled.length > 0) {
    selector.value = enabled[0].value;
  } else {
    selector.value = "";
  }
}

function renderSelectedStudentSurveyQuestions() {
  const container = $("studentSurveyQuestions");
  const status = $("studentSurveyQuestionStatus");
  const termId = $("studentSurveyTerm").value;
  const version = $("studentSurveyInstrument").value;

  container.replaceChildren();

  if (!termId || !version) {
    status.textContent = "No Data";
    status.hidden = false;
    return;
  }

  const rows = state.studentSurveyQuestions
    .filter(row => row.term_id === termId && row.survey_version === version)
    .sort((a, b) => Number(a.question_number) - Number(b.question_number));

  if (rows.length === 0) {
    status.textContent = "No Data";
    status.hidden = false;
    return;
  }

  status.hidden = true;

  rows.forEach(row => {
    const card = document.createElement("div");
    const title = document.createElement("dt");
    const value = document.createElement("dd");

    title.textContent = `${row.question_code}: ${row.question_title}`;

    const count = Number(row.valid_response_count);
    const rating = Number(row.average_rating);

    value.textContent =
      Number.isFinite(count) && count > 0 && Number.isFinite(rating)
        ? `${rating.toFixed(2)} / 5 (${Math.round(count).toLocaleString()} responses)`
        : "No Data";

    card.append(title, value);
    container.append(card);
  });
}
