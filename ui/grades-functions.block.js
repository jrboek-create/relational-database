async function loadGrades(course) {
  state.gradesController?.abort();
  state.gradesController = new AbortController();
  state.grades = [];

  resetGrades();

  if (!course.course_id) {
    showGradesMessage("No Grades available.");
    return;
  }

  showGradesMessage("Loading Grades...");

  const controller = state.gradesController;
  const timer = setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(
      `/api/courses/${encodeURIComponent(course.course_id)}/grades`,
      {
        headers: {
          Accept: "application/json"
        },
        credentials: "same-origin",
        signal: controller.signal
      }
    );

    const payload = await json(response);

    if (!response.ok || payload.ok === false) {
      throw new Error("grades");
    }

    const rows = Array.isArray(payload.data) ? payload.data : [];

    if (rows.length === 0) {
      showGradesMessage("No Grades available.");
      return;
    }

    state.grades = rows;
    populateGradesTerms();

    $("gradesStatus").hidden = true;
    $("gradesContent").hidden = false;

    renderSelectedGradesTerm();
  } catch (error) {
    if (error?.name === "AbortError") {
      showGradesMessage("Grades data could not be loaded.");
      return;
    }

    showGradesMessage("Grades data is temporarily unavailable.");
  } finally {
    clearTimeout(timer);
  }
}

function resetGrades() {
  state.gradesController?.abort();
  state.gradesController = null;
  state.grades = [];

  $("gradesTerm").replaceChildren();
  $("gradesContent").hidden = true;
  $("gradesStatus").hidden = false;
  $("gradesStatus").textContent = "Loading Grades...";

  set("gradesAverage", null);
  set("gradesTotal", null);

  setGradeCount("gradeCountA", 0);
  setGradeCount("gradeCountB", 0);
  setGradeCount("gradeCountC", 0);
  setGradeCount("gradeCountD", 0);
  setGradeCount("gradeCountF", 0);
  setGradeCount("gradeCountW", 0);
}

function showGradesMessage(message) {
  $("gradesContent").hidden = true;
  $("gradesStatus").textContent = message;
  $("gradesStatus").hidden = false;
}

function populateGradesTerms() {
  const selector = $("gradesTerm");
  selector.replaceChildren();

  state.grades.forEach((grade, index) => {
    const option = document.createElement("option");

    option.value = String(index);
    option.textContent =
      grade.term_label ||
      grade.term_code ||
      `Term ${index + 1}`;

    selector.append(option);
  });

  selector.value = "0";
}

function renderSelectedGradesTerm() {
  const index = Number($("gradesTerm").value);
  const grade = state.grades[index];

  if (!grade) {
    showGradesMessage("No Grades available.");
    return;
  }

  $("gradesStatus").hidden = true;
  $("gradesContent").hidden = false;

  set(
    "gradesAverage",
    formatGradeAverage(grade.average_final_score)
  );

  set(
    "gradesTotal",
    formatWholeNumber(grade.grade_count)
  );

  setGradeCount("gradeCountA", grade.grade_a_count);
  setGradeCount("gradeCountB", grade.grade_b_count);
  setGradeCount("gradeCountC", grade.grade_c_count);
  setGradeCount("gradeCountD", grade.grade_d_count);
  setGradeCount("gradeCountF", grade.grade_f_count);
  setGradeCount("gradeCountW", grade.grade_w_count);
}

function setGradeCount(id, value) {
  $(id).textContent = formatWholeNumber(value);
}

function formatWholeNumber(value) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? Math.round(parsed).toLocaleString()
    : "0";
}

function formatGradeAverage(value) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed.toFixed(2)
    : unavailable;
}
