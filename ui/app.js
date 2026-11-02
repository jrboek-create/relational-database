"use strict";

(() => {
  const detailFields = [
    "course_id","university_course_id","course_code","course_title",
    "college_name","department_name","course_description","course_goals",
    "course_learning_outcomes"
  ];

  const state = {
    page: 1, limit: 25, sort: "course_code",
    code: "", title: "", college: "", department: "",
    total: 0, pages: 1, courses: [], filterCourses: [],
    listController: null, detailController: null,

    gradesController: null, grades: [],
    enrollmentController: null, enrollment: [],
    dfwiController: null, dfwi: [],
    facultySurveyController: null, facultySurvey: [],
    studentSurveyController: null, studentSurvey: [],
    studentSurveyQuestionController: null, studentSurveyQuestions: [],
    instructionalDesignDevelopmentController: null, instructionalDesignDevelopment: [],
    aiProductionController: null, integrationsController: null
  };

  const $ = id => document.getElementById(id);
  const unavailable = "Not available";

  document.addEventListener("DOMContentLoaded", async () => {
    $("filterForm").addEventListener("submit", event => {
      event.preventDefault();
      state.page = 1;
      state.code = $("courseCode").value.trim();
      state.title = $("courseTitle").value.trim();
      state.college = $("collegeFilter").value;
      state.department = $("departmentFilter").value;
      state.sort = $("sortOrder").value;
      state.limit = Number($("pageSize").value);
      loadCourses();
    });

    $("resetFilters").addEventListener("click", () => {
      $("filterForm").reset();
      Object.assign(state, {
        page:1, limit:25, sort:"course_code",
        code:"", title:"", college:"", department:""
      });
      populateDepartments();
      loadCourses();
    });

    $("previousPage").addEventListener("click", () => {
      if (state.page > 1) { state.page--; loadCourses(); }
    });
    $("nextPage").addEventListener("click", () => {
      if (state.page < state.pages) { state.page++; loadCourses(); }
    });
    $("closeDetail").addEventListener("click", () => $("courseDetailDialog").close());
    $("chartRange").addEventListener("change", drawCharts);

    $("gradesTerm").addEventListener("change", () => {
      renderSelectedGradesTerm();
    });

    $("enrollmentTerm").addEventListener("change", () => {
      renderSelectedEnrollmentTerm();

      populateSurveyTerms("facultySurveyTerm");

      $("facultySurveyStatus").hidden = true;
      $("facultySurveyContent").hidden = false;

      renderSelectedFacultySurveyTerm();

      populateSurveyTerms("studentSurveyTerm");
      renderSelectedStudentSurveyTerm();
      populateStudentSurveyInstruments();
      renderSelectedStudentSurveyQuestions();
    });

    $("dfwiTerm").addEventListener("change", () => {
      renderSelectedDfwiTerm();
    });

    $("facultySurveyTerm").addEventListener("change", () => {
      renderSelectedFacultySurveyTerm();
    });

    $("studentSurveyTerm").addEventListener("change", () => {
      renderSelectedStudentSurveyTerm();
      populateStudentSurveyInstruments();
      renderSelectedStudentSurveyQuestions();
    });

    $("studentSurveyInstrument").addEventListener("change", () => {
      renderSelectedStudentSurveyQuestions();
    });

    $("iddMonth").addEventListener("change", () => {
      renderSelectedInstructionalDesignDevelopment();
    });

    $("collegeFilter").addEventListener("change", () => {
      populateDepartments();
    });

    try {
      await loadFilterOptions();
    } catch {
      $("collegeFilter").disabled = true;
      $("departmentFilter").disabled = true;
    }

    loadCourses();
  });

  async function loadCourses() {
    state.listController?.abort();
    state.listController = new AbortController();
    const timer = setTimeout(() => state.listController.abort(), 15000);

    $("tableWrap").setAttribute("aria-busy","true");
    $("errorMessage").hidden = true;
    announce("Loading courses.");

    try {
      const params = new URLSearchParams({
        page:String(state.page), limit:String(state.limit), sort:state.sort
      });
      if (state.code) params.set("course_code",state.code);
      if (state.title) params.set("course_title",state.title);
      if (state.college) params.set("college_name",state.college);
      if (state.department) params.set("department_name",state.department);

      const response = await fetch(`/api/courses?${params}`, {
        headers:{"Accept":"application/json"},
        credentials:"same-origin",
        signal:state.listController.signal
      });
      const payload = await json(response);
      if (!response.ok || payload.ok === false) throw new Error("catalog");

      state.courses = Array.isArray(payload.data) ? payload.data : [];
      const meta = payload.meta || payload.pagination || {};
      state.total = number(meta.total ?? payload.total,state.courses.length);
      state.pages = Math.max(1,number(
        meta.total_pages ?? meta.totalPages,
        Math.ceil(state.total / state.limit)
      ));

      renderCourses();
      const asOf = state.courses.find(x => x?.report_as_of_utc)?.report_as_of_utc;
      $("catalogAsOf").textContent = asOf ? formatDate(asOf) : unavailable;
      announce(`${state.total} courses available. Page ${state.page} of ${state.pages}.`);
    } catch (error) {
      state.courses=[]; state.total=0; state.pages=1;
      renderCourses();
      $("catalogAsOf").textContent=unavailable;
      $("errorMessage").textContent =
        "The catalog is temporarily unavailable.";
      $("errorMessage").hidden=false;
    } finally {
      clearTimeout(timer);
      $("tableWrap").setAttribute("aria-busy","false");
    }
  }

  function renderCourses() {
    $("courseRows").replaceChildren();
    $("tableWrap").hidden = state.courses.length === 0;
    $("emptyState").hidden = state.courses.length !== 0;

    state.courses.forEach(course => {
      const row=document.createElement("tr");
      row.append(cell(course.course_code));
      row.append(cell(course.course_title));
      row.append(cell(course.college_name));
      row.append(cell(course.department_name));
      row.append(cell(course.university_course_id));

      const action=document.createElement("td");
      const button=document.createElement("button");
      button.type="button";
      button.textContent="View details";
      button.addEventListener("click",()=>openDetail(course));
      action.append(button);
      row.append(action);
      $("courseRows").append(row);
    });

    const start=state.total ? ((state.page-1)*state.limit)+1 : 0;
    const end=Math.min(state.page*state.limit,state.total);
    $("catalogSummary").textContent=state.total
      ? `Showing ${start}-${end} of ${state.total} courses`
      : "No courses in the current result.";
    $("pageIndicator").textContent=`Page ${state.page} of ${state.pages}`;
    $("previousPage").disabled=state.page<=1;
    $("nextPage").disabled=state.page>=state.pages;
  }

  async function openDetail(course) {
    resetDetail(course);
    $("courseDetailDialog").showModal();
    loadGrades(course);
    loadEnrollment(course);
    loadDfwi(course);
    loadFacultySurvey(course);
    loadStudentSurvey(course);
    loadStudentSurveyQuestions(course);
    loadInstructionalDesignDevelopment(course);
    loadAiProduction(course);
    loadIntegrations(course);
    drawCharts();
    if (!course.course_id) {
      notice("This course has no identifier, so details can't be loaded.");
      return;
    }

    state.detailController?.abort();
    state.detailController=new AbortController();
    const timer=setTimeout(()=>state.detailController.abort(),15000);
    $("detailStatus").textContent="Loading course details...";

    try {
      const response=await fetch(
        `/api/courses/${encodeURIComponent(course.course_id)}`,
        {
          headers:{"Accept":"application/json"},
          credentials:"same-origin",
          signal:state.detailController.signal
        }
      );

      if ([404,501].includes(response.status)) {
        notice("Course details were not found. Basic course information is shown.");
        return;
      }

      const payload=await json(response);
      if (!response.ok || payload.ok===false) throw new Error("detail");
      const raw=Array.isArray(payload.data) ? payload.data[0] : payload.data;
      if (!raw || typeof raw!=="object") throw new Error("empty");

      const detail={};
      detailFields.forEach(field => detail[field]=raw[field] ?? null);

      set("detailCourseCode",detail.course_code || course.course_code);
      set("detailCourseTitle",detail.course_title || course.course_title);
      set("detailUniversityId",
          detail.university_course_id || course.university_course_id);
      set("detailCourseId",detail.course_id || course.course_id);
      set("detailCollege",detail.college_name);
      set("detailDepartment",detail.department_name);
      set("detailDescription",detail.course_description);
      set("detailGoals",detail.course_goals);
      set("detailOutcomes",detail.course_learning_outcomes);
      $("detailTitle").textContent=detail.course_code || course.course_code;
      $("detailSubtitle").textContent=detail.course_title || course.course_title;
      notice("");
    } catch {
      notice("Course details are temporarily unavailable. Basic course information is shown.");
    } finally {
      clearTimeout(timer);
      $("detailStatus").textContent="";
    }
  }

  function resetDetail(course) {
    $("detailTitle").textContent=course.course_code || "Selected course";
    $("detailSubtitle").textContent=course.course_title || "";
    set("detailCourseCode",course.course_code);
    set("detailCourseTitle",course.course_title);
    set("detailUniversityId",course.university_course_id);
    set("detailCourseId",course.course_id);
    set("detailCollege",course.college_name);
    set("detailDepartment",course.department_name);
    ["detailDescription","detailGoals","detailOutcomes"]
      .forEach(id=>set(id,null));
    resetGrades();
    resetInstructionalDesignDevelopment();
    notice("");
  }

  async function loadGrades(course) {
    resetGrades();
    const rows = await loadSectionRows("grades", course);
    if (!rows) return;

    state.grades = rows;
    populateIndexTerms("gradesTerm", rows);
    showSectionContent("grades");
    renderSelectedGradesTerm();
  }

  // ---- Shared section helpers -------------------------------------------
  const termSections = {
    grades: { path: "grades", none: "No Grades available.", loading: "Loading Grades...", aborted: "Grades data could not be loaded.", failed: "Grades data is temporarily unavailable." },
    enrollment: { path: "enrollment", none: "No Enrollment data available.", loading: "Loading Enrollment...", aborted: "Enrollment data could not be loaded.", failed: "Enrollment data is temporarily unavailable." },
    dfwi: { path: "dfwi", none: "No DFWI data available.", loading: "Loading DFWI...", aborted: "DFWI data could not be loaded.", failed: "DFWI data is temporarily unavailable." },
    facultySurvey: { path: "faculty-survey", none: "No Faculty Survey results available.", loading: "Loading Faculty Survey results...", aborted: "Faculty Survey results could not be loaded.", failed: "Faculty Survey results are temporarily unavailable." },
    aiProduction: { path: "ai-production", none: "No AI integration recorded for this course.", loading: "Loading AI in this course...", aborted: "AI data could not be loaded.", failed: "AI data is temporarily unavailable." },
    integrations: { path: "integrations", none: "No integrations recorded for this course.", loading: "Loading Integrations...", aborted: "Integration data could not be loaded.", failed: "Integration data is temporarily unavailable." }
  };

  async function fetchCourseRows(course, path, controller) {
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(`/api/courses/${encodeURIComponent(course.course_id)}/${path}`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: controller.signal
      });
      const payload = await json(response);
      if (!response.ok || payload.ok === false) throw new Error(path);
      return Array.isArray(payload.data) ? payload.data : [];
    } finally {
      clearTimeout(timer);
    }
  }

  // Returns the section's rows, or null after showing the right message.
  async function loadSectionRows(key, course) {
    const section = termSections[key];
    const controller = new AbortController();
    state[`${key}Controller`] = controller;

    if (!course.course_id) {
      showSectionMessage(key, section.none);
      return null;
    }

    showSectionMessage(key, section.loading);
    try {
      const rows = await fetchCourseRows(course, section.path, controller);
      if (rows.length === 0) {
        showSectionMessage(key, section.none);
        return null;
      }
      return rows;
    } catch (error) {
      showSectionMessage(key, error?.name === "AbortError" ? section.aborted : section.failed);
      return null;
    }
  }

  function showSectionMessage(key, message) {
    $(`${key}Content`).hidden = true;
    $(`${key}Status`).textContent = message;
    $(`${key}Status`).hidden = false;
  }

  function showSectionContent(key) {
    $(`${key}Status`).hidden = true;
    $(`${key}Content`).hidden = false;
  }

  function termLabel(row, index) {
    return row.term_label || row.term_code || `Term ${index + 1}`;
  }

  // Grades, Enrollment, DFWI: one option per row, value = row index.
  function populateIndexTerms(selectId, rows) {
    const selector = $(selectId);
    selector.replaceChildren();
    rows.forEach((row, index) => {
      const option = document.createElement("option");
      option.value = String(index);
      option.textContent = termLabel(row, index);
      selector.append(option);
    });
    selector.value = "0";
  }

  // Survey sections list enrollment terms (value = term_id) and keep the
  // current selection when it still exists.
  function populateSurveyTerms(selectId) {
    const selector = $(selectId);
    const previousTermId = selector.value;
    selector.replaceChildren();
    state.enrollment.forEach((row, index) => {
      const option = document.createElement("option");
      option.value = row.term_id || "";
      option.textContent = termLabel(row, index);
      selector.append(option);
    });
    if (selector.options.length === 0) return;
    const stillExists = Array.from(selector.options).some(option => option.value === previousTermId);
    selector.value = stillExists ? previousTermId : selector.options[0].value;
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

  }

  function renderSelectedGradesTerm() {
    drawCharts();
    const index = Number($("gradesTerm").value);
    const grade = state.grades[index];

    if (!grade) {
      showSectionMessage("grades", "No Grades available.");
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

  }

  async function loadEnrollment(course) {
    resetEnrollment();
    const rows = await loadSectionRows("enrollment", course);
    if (!rows) return;

    state.enrollment = rows;
    populateIndexTerms("enrollmentTerm", rows);
    showSectionContent("enrollment");
    renderSelectedEnrollmentTerm();

    // Both survey sections list terms from enrollment, so refresh them now.
    populateSurveyTerms("facultySurveyTerm");
    showSectionContent("facultySurvey");
    renderSelectedFacultySurveyTerm();

    populateSurveyTerms("studentSurveyTerm");
    renderSelectedStudentSurveyTerm();
    populateStudentSurveyInstruments();
    renderSelectedStudentSurveyQuestions();
  }

  function resetEnrollment() {
    state.enrollmentController?.abort();
    state.enrollmentController = null;
    state.enrollment = [];

    $("enrollmentTerm").replaceChildren();
    $("enrollmentContent").hidden = true;
    $("enrollmentStatus").hidden = false;
    $("enrollmentStatus").textContent = "Loading Enrollment...";

    set("enrollmentTotal", null);
    set("enrollmentOfferings", null);
    set("enrollmentMinimum", null);
    set("enrollmentMaximum", null);
  }

  function renderSelectedEnrollmentTerm() {
    drawCharts();
    const index = Number($("enrollmentTerm").value);
    const enrollment = state.enrollment[index];

    if (!enrollment) {
      showSectionMessage("enrollment", "No Enrollment data available.");
      return;
    }

    $("enrollmentStatus").hidden = true;
    $("enrollmentContent").hidden = false;

    set(
      "enrollmentTotal",
      formatWholeNumber(enrollment.enrollment_count)
    );

    set(
      "enrollmentOfferings",
      formatWholeNumber(enrollment.offering_count)
    );

    set(
      "enrollmentMinimum",
      formatWholeNumber(enrollment.minimum_section_enrollment)
    );

    set(
      "enrollmentMaximum",
      formatWholeNumber(enrollment.maximum_section_enrollment)
    );
  }

  async function loadDfwi(course) {
    resetDfwi();
    const rows = await loadSectionRows("dfwi", course);
    if (!rows) return;

    state.dfwi = rows;
    populateIndexTerms("dfwiTerm", rows);
    showSectionContent("dfwi");
    renderSelectedDfwiTerm();
  }

  function resetDfwi() {
    state.dfwiController?.abort();
    state.dfwiController = null;
    state.dfwi = [];

    $("dfwiTerm").replaceChildren();
    $("dfwiContent").hidden = true;
    $("dfwiStatus").hidden = false;
    $("dfwiStatus").textContent = "Loading DFWI...";

    set("dfwiRate", null);
    set("dfwiTotal", null);
    set("dfwiEnrollment", null);
    set("dfwiDF", null);
    set("dfwiWI", null);
  }

  function renderSelectedDfwiTerm() {
    drawCharts();
    const index = Number($("dfwiTerm").value);
    const dfwi = state.dfwi[index];

    if (!dfwi) {
      showSectionMessage("dfwi", "No DFWI data available.");
      return;
    }

    $("dfwiStatus").hidden = true;
    $("dfwiContent").hidden = false;

    set("dfwiRate", formatDfwiRate(dfwi.dfwi_rate_pct));
    set("dfwiTotal", formatWholeNumber(dfwi.dfwi_count));
    set(
      "dfwiEnrollment",
      formatWholeNumber(dfwi.enrollment_count)
    );

    set("dfwiDF", `${formatWholeNumber(dfwi.d_count)} / ${formatWholeNumber(dfwi.f_count)}`);
    set("dfwiWI", `${formatWholeNumber(dfwi.w_count)} / ${formatWholeNumber(dfwi.i_count)}`);
  }

  function formatDfwiRate(value) {
    const parsed = Number(value);

    return Number.isFinite(parsed)
      ? `${parsed.toFixed(2)}%`
      : unavailable;
  }

  async function loadFacultySurvey(course) {
    resetFacultySurvey();
    const rows = await loadSectionRows("facultySurvey", course);
    if (!rows) return;

    state.facultySurvey = rows;
    populateSurveyTerms("facultySurveyTerm");
    showSectionContent("facultySurvey");
    renderSelectedFacultySurveyTerm();
  }

  function resetFacultySurvey() {
    state.facultySurveyController?.abort();
    state.facultySurveyController = null;
    state.facultySurvey = [];

    $("facultySurveyTerm").replaceChildren();
    $("facultySurveyContent").hidden = true;
    $("facultySurveyStatus").hidden = false;
    $("facultySurveyStatus").textContent =
      "Loading Faculty Survey results...";

    set("facultySurveyVersion", null);
    set("facultySurveyResponses", null);
    set("facultyTeachingAverage", null);
    set("facultyQualityAverage", null);
    set("facultyTeachingResponses", null);
    set("facultyQualityResponses", null);
  }

  function renderSelectedFacultySurveyTerm() {
    drawCharts();
    const selectedTermId = $("facultySurveyTerm").value;

    if (!selectedTermId) {
      showSectionMessage("facultySurvey", "No term data available.");
      return;
    }

    const survey = state.facultySurvey.find(
      (row) => row.term_id === selectedTermId
    );

    $("facultySurveyStatus").hidden = true;
    $("facultySurveyContent").hidden = false;

    if (!survey) {
      set("facultySurveyVersion", "No Data");
      set("facultySurveyResponses", "No Data");
      set("facultyTeachingAverage", "No Data");
      set("facultyQualityAverage", "No Data");
      set("facultyTeachingResponses", "No Data");
      set("facultyQualityResponses", "No Data");
      return;
    }

    set(
      "facultySurveyVersion",
      survey.survey_version || "No Data"
    );

    set(
      "facultySurveyResponses",
      formatWholeNumber(survey.faculty_response_count)
    );

    set(
      "facultyTeachingAverage",
      formatFacultyRating(survey.average_teaching_experience)
    );

    set(
      "facultyQualityAverage",
      formatFacultyRating(survey.average_course_quality)
    );

    set(
      "facultyTeachingResponses",
      formatWholeNumber(survey.teaching_response_count)
    );

    set(
      "facultyQualityResponses",
      formatWholeNumber(survey.quality_response_count)
    );
  }

  function formatFacultyRating(value) {
    const parsed = Number(value);

    return Number.isFinite(parsed)
      ? `${parsed.toFixed(2)} / 5`
      : unavailable;
  }

  async function loadStudentSurvey(course) {
    resetStudentSurvey();

    if (!course.course_id) {
      showSectionMessage("studentSurvey", "No Data");
      return;
    }

    state.studentSurveyController?.abort();
    state.studentSurveyController = new AbortController();
    showSectionMessage("studentSurvey", "Loading Student Survey results...");

    try {
      state.studentSurvey = await fetchCourseRows(course, "student-survey", state.studentSurveyController);

      if (state.enrollment.length > 0) {
        populateSurveyTerms("studentSurveyTerm");
        renderSelectedStudentSurveyTerm();
        populateStudentSurveyInstruments();
        renderSelectedStudentSurveyQuestions();
      } else {
        showSectionMessage("studentSurvey", "Loading Student Survey results...");
      }
    } catch (error) {
      showSectionMessage("studentSurvey", error?.name === "AbortError"
        ? "Student Survey results could not be loaded."
        : "Student Survey results are temporarily unavailable.");
    }
  }

  function resetStudentSurvey() {
    state.studentSurveyController?.abort();
    state.studentSurveyController = null;
    state.studentSurvey = [];

    state.studentSurveyQuestionController?.abort();
    state.studentSurveyQuestionController = null;
    state.studentSurveyQuestions = [];

    $("studentSurveyInstrument").value = "NEW";
    $("studentSurveyQuestionStatus").textContent = "No Data";
    $("studentSurveyQuestionStatus").hidden = false;
    $("studentSurveyQuestions").replaceChildren();

    $("studentSurveyTerm").replaceChildren();
    $("studentSurveyContent").hidden = true;
    $("studentSurveyStatus").hidden = false;
    $("studentSurveyStatus").textContent =
      "Loading Student Survey results...";

    setStudentSurveyNoData();
  }

  function renderSelectedStudentSurveyTerm() {
    drawCharts();
    const selectedTermId = $("studentSurveyTerm").value;

    if (!selectedTermId) {
      showSectionMessage("studentSurvey", "No term data available.");
      return;
    }

    const survey = state.studentSurvey.find(
      row => row.term_id === selectedTermId
    );

    $("studentSurveyStatus").hidden = true;
    $("studentSurveyContent").hidden = false;

    if (!survey) {
      setStudentSurveyNoData();
      return;
    }

    set(
      "studentSurveyVersion",
      survey.survey_version || "No Data"
    );

    set(
      "studentSurveyResponses",
      studentSurveyCountOrNoData(
        survey.student_response_count
      )
    );

    set(
      "studentTeachingAverage",
      studentSurveyRatingOrNoData(
        survey.teaching_response_count,
        survey.average_teaching_effectiveness
      )
    );

    set(
      "studentTeachingResponses",
      studentSurveyMetricCountOrNoData(
        survey.teaching_response_count,
        survey.average_teaching_effectiveness
      )
    );

    set(
      "studentCourseQualityAverage",
      studentSurveyRatingOrNoData(
        survey.course_quality_response_count,
        survey.average_course_quality
      )
    );

    set(
      "studentCourseQualityResponses",
      studentSurveyMetricCountOrNoData(
        survey.course_quality_response_count,
        survey.average_course_quality
      )
    );

    set(
      "studentRecommendationAverage",
      studentSurveyRatingOrNoData(
        survey.course_recommendation_response_count,
        survey.average_course_recommendation
      )
    );

    set(
      "studentRecommendationResponses",
      studentSurveyMetricCountOrNoData(
        survey.course_recommendation_response_count,
        survey.average_course_recommendation
      )
    );
  }

  function setStudentSurveyNoData() {
    set("studentSurveyVersion", "No Data");
    set("studentSurveyResponses", "No Data");
    set("studentTeachingAverage", "No Data");
    set("studentTeachingResponses", "No Data");
    set("studentCourseQualityAverage", "No Data");
    set("studentCourseQualityResponses", "No Data");
    set("studentRecommendationAverage", "No Data");
    set("studentRecommendationResponses", "No Data");
  }

  function studentSurveyCountOrNoData(value) {
    const parsed = Number(value);

    return Number.isFinite(parsed) && parsed > 0
      ? Math.round(parsed).toLocaleString()
      : "No Data";
  }

  function studentSurveyRatingOrNoData(count, value) {
    const parsedCount = Number(count);
    const parsedValue = Number(value);

    return Number.isFinite(parsedCount) &&
      parsedCount > 0 &&
      Number.isFinite(parsedValue)
      ? `${parsedValue.toFixed(2)} / 5`
      : "No Data";
  }

  function studentSurveyMetricCountOrNoData(count, value) {
    const parsedCount = Number(count);
    const parsedValue = Number(value);

    return Number.isFinite(parsedCount) &&
      parsedCount > 0 &&
      Number.isFinite(parsedValue)
      ? Math.round(parsedCount).toLocaleString()
      : "No Data";
  }

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
    drawCharts();
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

  function resetInstructionalDesignDevelopment() {
    state.instructionalDesignDevelopmentController?.abort();
    state.instructionalDesignDevelopmentController = null;
    state.instructionalDesignDevelopment = [];
    $("iddMonth").replaceChildren();
    $("iddRecords").replaceChildren();
    $("iddStatus").textContent = "No Data";
    $("iddStatus").hidden = false;
    $("iddRecordStatus").textContent = "No Data";
    $("iddRecordStatus").hidden = true;
    $("iddContent").hidden = true;
  }

  async function loadInstructionalDesignDevelopment(course) {
    resetInstructionalDesignDevelopment();
    if (!course.course_id) return;

    state.instructionalDesignDevelopmentController = new AbortController();
    const controller = state.instructionalDesignDevelopmentController;
    const timer = setTimeout(() => controller.abort(), 15000);
    $("iddStatus").textContent = "Loading Instructional design and development...";

    try {
      const response = await fetch(
        "/api/courses/" + encodeURIComponent(course.course_id) + "/instructional-design-development",
        { headers:{ Accept:"application/json" }, credentials:"same-origin", signal:controller.signal }
      );
      const payload = await json(response);
      if (!response.ok || payload.ok === false) throw new Error("instructional-design-development");
      state.instructionalDesignDevelopment = Array.isArray(payload.data) ? payload.data : [];
      populateInstructionalDesignDevelopmentMonths();
      $("iddStatus").hidden = state.instructionalDesignDevelopment.length > 0;
      $("iddStatus").textContent = state.instructionalDesignDevelopment.length > 0 ? "" : "No Data";
      $("iddContent").hidden = false;
      renderSelectedInstructionalDesignDevelopment();
    } catch (error) {
      if (error?.name !== "AbortError") {
        $("iddStatus").textContent = "Instructional design and development data is temporarily unavailable.";
      }
      $("iddStatus").hidden = false;
      $("iddContent").hidden = true;
    } finally { clearTimeout(timer); }
  }

  function populateInstructionalDesignDevelopmentMonths() {
    const selector = $("iddMonth");
    const previous = selector.value;
    const months = uniqueSorted(
      state.instructionalDesignDevelopment.map(row => row.idd_year_month)
    ).sort((a,b) => b.localeCompare(a));
    selector.replaceChildren();
    months.forEach(month => {
      const option = document.createElement("option");
      option.value = month;
      option.textContent = month;
      selector.append(option);
    });
    selector.value = months.includes(previous) ? previous : (months[0] || "");
  }

  // AI in this course: one block per AI production project (from the AI Production Schedule).
  async function loadAiProduction(course) {
    state.aiProductionController?.abort();
    $("aiProductionList").replaceChildren();
    $("aiProductionSummary").textContent = "";
    const rows = await loadSectionRows("aiProduction", course);
    if (!rows) return;
    $("aiProductionSummary").textContent = `Yes: ${rows.length} AI project${rows.length === 1 ? "" : "s"} recorded.`;
    rows.forEach(row => {
      const item = document.createElement("div");
      item.className = "ai-project";
      const heading = document.createElement("h4");
      heading.textContent = row.project_name || row.raw_course || "AI project";
      const list = document.createElement("dl");
      list.className = "grades-summary";
      [["Implemented", row.implementation_label || row.implementation_month],
       ["AI type", row.ai_type],
       ["Status", row.project_status],
       ["What students do", row.description],
       ["Sections listed with AI", row.ai_section_count > 0 ? row.ai_section_count : null]
      ].forEach(([label, value]) => {
        if (value === null || value === undefined || String(value).trim() === "") return;
        const card = document.createElement("div");
        const dt = document.createElement("dt");
        const dd = document.createElement("dd");
        dt.textContent = label;
        dd.textContent = String(value).trim();
        card.append(dt, dd);
        list.append(card);
      });
      item.append(heading, list);
      $("aiProductionList").append(item);
    });
    showSectionContent("aiProduction");
  }

  // Integrations: one line per integration type, with the month it was last done or started.
  async function loadIntegrations(course) {
    state.integrationsController?.abort();
    $("integrationsList").replaceChildren();
    const rows = await loadSectionRows("integrations", course);
    if (!rows) return;
    rows.forEach(row => {
      const card = document.createElement("div");
      const dt = document.createElement("dt");
      const dd = document.createElement("dd");
      dt.textContent = row.integration_name;
      const when = { last: "last", start: "started" }[row.date_meaning];
      dd.textContent = when ? `${row.integration_month} (${when})` : row.integration_month;
      card.append(dt, dd);
      $("integrationsList").append(card);
    });
    showSectionContent("integrations");
  }

  function renderSelectedInstructionalDesignDevelopment() {
    const container = $("iddRecords");
    const status = $("iddRecordStatus");
    const month = $("iddMonth").value;
    container.replaceChildren();
    const rows = state.instructionalDesignDevelopment.filter(row => row.idd_year_month === month);
    if (!month || rows.length === 0) { status.textContent="No Data"; status.hidden=false; return; }
    status.hidden = true;
    rows.forEach((row,index) => {
      const fields = [
        [rows.length > 1 ? "Project " + (index+1) + " status" : "Project status", row.project_status],
        ["Project type", row.project_type],
        ["Course developer", row.course_developer],
        ["Instructional designer", row.instructional_designer],
        ["Project finished date", formatIddExcelDate(row.project_finished_date_raw)],
        ["Developer completion date", formatIddExcelDate(row.developer_completion_date_raw)],
        ["Important project dates", row.important_project_dates],
        ["Course delayed reason", row.course_delayed_reason]
      ];
      fields.forEach(([label,value]) => {
        const card=document.createElement("div");
        const dt=document.createElement("dt");
        const dd=document.createElement("dd");
        dt.textContent=label;
        const valid=value!==null && value!==undefined && String(value).trim()!=="";
        dd.textContent=valid ? String(value).trim() : "No Data";
        dd.classList.toggle("unavailable",!valid);
        card.append(dt,dd);
        container.append(card);
      });
    });
  }

  function formatIddExcelDate(value) {
    if (value === null || value === undefined || String(value).trim() === "") return null;
    const serial = Number(value);
    if (!Number.isFinite(serial) || serial < 30000 || serial > 60000) return null;
    const date = new Date(Date.UTC(1899,11,30) + serial * 86400000);
    return Number.isNaN(date.getTime()) ? null : new Intl.DateTimeFormat("en-US",{dateStyle:"medium",timeZone:"UTC"}).format(date);
  }

  // ---- Charts --------------------------------------------------------------
  // Plain SVG, no library. Colors are SVG attributes or classes in styles.css,
  // because the Content-Security-Policy blocks inline style attributes.
  const SVG_NS = "http://www.w3.org/2000/svg";
  const chartColors = {
    base: "#147d85", selected: "#17365d", line1: "#17365d", line2: "#c88a12", line3: "#147d85",
    D: "#c88a12", F: "#b42318", W: "#6941c6", I: "#c11574"
  };
  const heatRamp = ["#f0f6fa", "#dcebf3", "#c3dcea", "#a3c8de", "#7fb0cf", "#4f8fb8", "#2b6e9e", "#17365d"];
  const gradeKeys = ["A", "AU", "B", "C", "D", "F", "FX", "I", "IP", "N", "NC", "NS", "NTG", "P", "S", "W", "WF"];

  function svgEl(tag, attrs, parent) {
    const node = document.createElementNS(SVG_NS, tag);
    Object.entries(attrs).forEach(([key, value]) => node.setAttribute(key, value));
    if (parent) parent.append(node);
    return node;
  }

  function svgText(parent, x, y, text, attrs = {}) {
    const node = svgEl("text", { x, y, class: "chart-axis", ...attrs }, parent);
    node.textContent = text;
    return node;
  }

  function addTooltip(node, text) {
    svgEl("title", {}, node).textContent = text;
  }

  function newChart(id, width, height, label) {
    const box = $(id);
    box.closest(".chart-wrap").hidden = false;
    box.replaceChildren();
    return svgEl("svg", { viewBox: `0 0 ${width} ${height}`, role: "img", "aria-label": label }, box);
  }

  function hideChart(id) {
    $(id).replaceChildren();
    $(id).closest(".chart-wrap").hidden = true;
  }

  function chartNumber(value) {
    if (value === null || value === undefined || String(value).trim() === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function shortTerm(row) {
    return String(row.term_label || row.term_code || "").replace(/\s*\(AY [^)]*\)\s*$/, "").trim();
  }

  function trendRows(rows) {
    const ordered = [...rows].sort((a, b) => Number(a.term_code) - Number(b.term_code));
    return $("chartRange").value === "all" ? ordered : ordered.slice(-24);
  }

  function niceMax(value) {
    if (!(value > 0)) return 1;
    const step = 10 ** Math.floor(Math.log10(value));
    return Math.ceil(value / step) * step;
  }

  function drawGrid(svg, area, min, max, ticks, format) {
    ticks.forEach(value => {
      const y = area.bottom - (value - min) / (max - min) * (area.bottom - area.top);
      svgEl("line", { x1: area.left, x2: area.right, y1: y, y2: y, class: "chart-grid" }, svg);
      svgText(svg, area.left - 6, y + 4, format(value), { "text-anchor": "end" });
    });
  }

  function drawTermLabels(svg, area, labels, x) {
    const every = Math.max(1, Math.ceil(labels.length / 6));
    labels.forEach((label, i) => {
      if (i % every === 0) svgText(svg, x(i), area.bottom + 16, label, { "text-anchor": "middle" });
    });
  }

  // items: [{ label, value, color, tip }]
  function barChart(id, title, items, width, height, termAxis) {
    const svg = newChart(id, width, height, title);
    const area = { left: 40, right: width - 8, top: 14, bottom: height - 24 };
    const max = niceMax(Math.max(...items.map(item => item.value)));
    const ticks = [0, max / 2, max];
    drawGrid(svg, area, 0, max, ticks, value => Math.round(value).toLocaleString());
    const step = (area.right - area.left) / items.length;
    const x = i => area.left + (i + 0.5) * step;
    const barWidth = Math.min(32, step * 0.7);
    items.forEach((item, i) => {
      const h = item.value / max * (area.bottom - area.top);
      const bar = svgEl("rect", { x: x(i) - barWidth / 2, y: area.bottom - h, width: barWidth, height: h, rx: 2, fill: item.color }, svg);
      addTooltip(bar, item.tip);
      if (!termAxis) {
        svgText(svg, x(i), area.bottom - h - 4, Math.round(item.value).toLocaleString(), { "text-anchor": "middle", class: "chart-value" });
        svgText(svg, x(i), area.bottom + 16, item.label, { "text-anchor": "middle" });
      }
    });
    if (termAxis) drawTermLabels(svg, area, items.map(item => item.label), x);
  }

  // series: [{ name, values, color, dash }]; values may contain null (gap)
  function lineChart(id, title, labels, series, min, max, ticks, format) {
    const width = 640, height = 220;
    const svg = newChart(id, width, height, title);
    const area = { left: 40, right: width - 8, top: series.length > 1 ? 34 : 14, bottom: height - 24 };
    drawGrid(svg, area, min, max, ticks, format);
    const step = (area.right - area.left) / labels.length;
    const x = i => area.left + (i + 0.5) * step;
    const y = v => area.bottom - (v - min) / (max - min) * (area.bottom - area.top);
    drawTermLabels(svg, area, labels, x);
    series.forEach((s, n) => {
      if (series.length > 1) {
        const lx = area.left + n * 150;
        svgEl("line", { x1: lx, x2: lx + 18, y1: 10, y2: 10, stroke: s.color, "stroke-width": 2, ...(s.dash ? { "stroke-dasharray": s.dash } : {}) }, svg);
        svgText(svg, lx + 24, 14, s.name, { class: "chart-legend" });
      }
      let path = "";
      let penDown = false;
      s.values.forEach((v, i) => {
        if (v === null) { penDown = false; return; }
        path += `${penDown ? "L" : "M"}${x(i).toFixed(1)} ${y(v).toFixed(1)} `;
        penDown = true;
      });
      svgEl("path", { d: path.trim(), fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round", ...(s.dash ? { "stroke-dasharray": s.dash } : {}) }, svg);
      s.values.forEach((v, i) => {
        if (v === null) return;
        const dot = svgEl("circle", { cx: x(i), cy: y(v), r: 3, fill: s.color }, svg);
        addTooltip(dot, `${s.name}, ${labels[i]}: ${format(v)}`);
      });
    });
  }

  // rows: [{ label, tip, values }] with values on a 1-5 scale (null = no data)
  function heatMap(id, title, terms, rows) {
    const width = 960, labelWidth = 260, rowHeight = 24, top = 22;
    const cell = (width - labelWidth - 8) / terms.length;
    const height = top + rows.length * rowHeight + 34;
    const svg = newChart(id, width, height, title);
    const every = cell >= 34 ? 1 : Math.ceil(34 / cell);
    terms.forEach((term, j) => {
      if (j % every === 0) svgText(svg, labelWidth + (j + 0.5) * cell, top - 8, term, { "text-anchor": "middle" });
    });
    rows.forEach((row, i) => {
      const y = top + i * rowHeight;
      const label = svgText(svg, labelWidth - 8, y + 16, row.label, { "text-anchor": "end", class: "chart-legend" });
      addTooltip(label, row.tip);
      row.values.forEach((v, j) => {
        const x = labelWidth + j * cell;
        if (v === null) {
          svgEl("rect", { x: x + 1, y: y + 1, width: cell - 2, height: rowHeight - 2, rx: 2, fill: "none", class: "chart-grid" }, svg);
          return;
        }
        const shade = Math.max(0, Math.min(7, Math.floor((v - 1) / 0.5)));
        const box = svgEl("rect", { x: x + 1, y: y + 1, width: cell - 2, height: rowHeight - 2, rx: 2, fill: heatRamp[shade] }, svg);
        addTooltip(box, `${row.tip} | ${terms[j]}: ${v.toFixed(2)}`);
        if (cell >= 34) svgText(svg, x + cell / 2, y + 16, v.toFixed(2), { "text-anchor": "middle", fill: shade >= 5 ? "#ffffff" : "#17365d", class: "chart-cell" });
      });
    });
    const ly = height - 14;
    svgText(svg, labelWidth, ly + 4, "1", { "text-anchor": "end" });
    heatRamp.forEach((color, k) => svgEl("rect", { x: labelWidth + 6 + k * 22, y: ly - 7, width: 22, height: 12, fill: color }, svg));
    svgText(svg, labelWidth + 12 + heatRamp.length * 22, ly + 4, "5  (average rating)");
  }

  function drawCharts() {
    drawGradesChart();
    drawEnrollmentChart();
    drawDfwiChart();
    drawSurveyChart("facultySurveyChart", "Faculty survey averages by term", state.facultySurvey, [
      ["Teaching experience", "average_teaching_experience"],
      ["Course quality", "average_course_quality"]
    ]);
    drawSurveyChart("studentSurveyChart", "Student survey averages by term", state.studentSurvey, [
      ["Teaching effectiveness", "average_teaching_effectiveness"],
      ["Course quality", "average_course_quality"],
      ["Recommendation", "average_course_recommendation"]
    ]);
    drawStudentSurveyHeatmap();
  }

  function drawGradesChart() {
    const row = state.grades[Number($("gradesTerm").value)];
    const items = row ? gradeKeys
      .map(key => ({ key, value: chartNumber(row[`grade_${key.toLowerCase()}_count`]) }))
      .filter(item => item.value > 0)
      .map(item => ({ label: item.key, value: item.value, color: chartColors[item.key] || chartColors.base, tip: `${item.key}: ${item.value.toLocaleString()}` })) : [];
    if (!items.length) return hideChart("gradesChart");
    barChart("gradesChart", `Grade distribution, ${shortTerm(row)}`, items, 640, 200, false);
  }

  function drawEnrollmentChart() {
    const rows = trendRows(state.enrollment).filter(row => chartNumber(row.enrollment_count) !== null);
    if (!rows.length) return hideChart("enrollmentChart");
    const selected = state.enrollment[Number($("enrollmentTerm").value)];
    barChart("enrollmentChart", "Enrollment by term", rows.map(row => ({
      label: shortTerm(row),
      value: chartNumber(row.enrollment_count),
      color: row === selected ? chartColors.selected : chartColors.base,
      tip: `${shortTerm(row)}: ${chartNumber(row.enrollment_count).toLocaleString()} enrolled`
    })), 640, 220, true);
  }

  function drawDfwiChart() {
    const rows = trendRows(state.dfwi);
    const values = rows.map(row => chartNumber(row.dfwi_rate_pct));
    if (!values.some(v => v !== null)) return hideChart("dfwiChart");
    const max = Math.max(20, Math.ceil(Math.max(...values.filter(v => v !== null)) / 5) * 5);
    lineChart("dfwiChart", "DFWI rate by term", rows.map(shortTerm),
      [{ name: "DFWI rate", values, color: chartColors.F }],
      0, max, [0, max / 2, max], v => `${Math.round(v * 10) / 10}%`);
  }

  function drawSurveyChart(id, title, sourceRows, fields) {
    const rows = trendRows(sourceRows);
    const colors = [chartColors.line1, chartColors.line2, chartColors.line3];
    const dashes = [null, "6 4", "2 3"];
    const series = fields.map(([name, field], n) => ({ name, values: rows.map(row => chartNumber(row[field])), color: colors[n], dash: dashes[n] }));
    if (!series.some(s => s.values.some(v => v !== null))) return hideChart(id);
    lineChart(id, title, rows.map(shortTerm), series, 1, 5, [1, 2, 3, 4, 5], v => v.toFixed(2));
  }

  function drawStudentSurveyHeatmap() {
    const version = $("studentSurveyInstrument").value;
    const rows = state.studentSurveyQuestions.filter(row => row.survey_version === version && chartNumber(row.average_rating) !== null);
    if (!rows.length) return hideChart("studentSurveyHeatmap");
    const termCodes = [...new Set(rows.map(row => row.term_code))].sort((a, b) => Number(a) - Number(b));
    const shown = $("chartRange").value === "all" ? termCodes : termCodes.slice(-24);
    const labelFor = Object.fromEntries(rows.map(row => [row.term_code, shortTerm(row)]));
    const questions = [...new Map(rows.map(row => [Number(row.question_number), row])).values()]
      .sort((a, b) => Number(a.question_number) - Number(b.question_number));
    const lookup = new Map(rows.map(row => [`${row.term_code}|${Number(row.question_number)}`, chartNumber(row.average_rating)]));
    heatMap("studentSurveyHeatmap", `Student survey (${version}) average rating by question and term`,
      shown.map(code => labelFor[code]),
      questions.map(q => {
        const text = String(q.question_title || "").replace(/\s+/g, " ").trim();
        const short = text.length > 40 ? `${text.slice(0, 39)}…` : text;
        return {
          label: `${q.question_code} ${short}`,
          tip: `${q.question_code}: ${text}`,
          values: shown.map(code => lookup.get(`${code}|${Number(q.question_number)}`) ?? null)
        };
      }));
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

  async function loadFilterOptions() {
    const response = await fetch("/api/filter-options", {
      headers:{"Accept":"application/json"},
      credentials:"same-origin"
    });
    const payload = await json(response);

    if (!response.ok || payload.ok === false || !Array.isArray(payload.data)) {
      throw new Error("filters");
    }

    state.filterCourses = payload.data;
    populateSelect("collegeFilter","All colleges",uniqueSorted(payload.data.map(row => row.college_name)));
    populateDepartments();
  }

  function populateDepartments() {
    const college = $("collegeFilter").value;

    const departments = uniqueSorted(
      state.filterCourses
        .filter(row => !college || row.college_name === college)
        .map(row => row.department_name)
    );

    populateSelect(
      "departmentFilter",
      "All departments",
      departments
    );
  }

  function populateSelect(id,defaultLabel,values) {
    const select = $(id);
    const prior = select.value;

    select.replaceChildren();

    const initial = document.createElement("option");
    initial.value = "";
    initial.textContent = defaultLabel;
    select.append(initial);

    values.forEach(value => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      select.append(option);
    });

    select.value = values.includes(prior) ? prior : "";
  }

  function uniqueSorted(values) {
    return [...new Set(
      values.filter(value =>
        value !== null &&
        value !== undefined &&
        String(value).trim() !== ""
      ).map(value => String(value).trim())
    )].sort((a,b) => a.localeCompare(b));
  }

  function set(id,value) {
    const element=$(id);
    const valid=value!==null && value!==undefined && String(value).trim()!=="";
    element.textContent=valid ? String(value).trim() : unavailable;
    element.classList.toggle("unavailable",!valid);
  }

  function cell(value) {
    const td=document.createElement("td");
    td.textContent=value ?? unavailable;
    return td;
  }

  function notice(message) {
    $("detailNotice").textContent=message;
    $("detailNotice").hidden=!message;
  }

  function announce(message) { $("statusMessage").textContent=message; }

  async function json(response) {
    const type=response.headers.get("content-type") || "";
    return type.includes("application/json") ? response.json() : {};
  }

  function number(value,fallback) {
    const n=Number(value);
    return Number.isFinite(n) && n>=0 ? n : fallback;
  }

  function formatDate(value) {
    const date=new Date(value);
    return Number.isNaN(date.getTime()) ? unavailable :
      new Intl.DateTimeFormat("en-US",{
        dateStyle:"medium",timeStyle:"short"
      }).format(date);
  }
})();
