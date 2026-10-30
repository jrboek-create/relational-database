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
    facultySurveyController: null, facultySurvey: []
  };

  const $ = id => document.getElementById(id);
  const unavailable = "Not yet available";

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

    $("gradesTerm").addEventListener("change", () => {
      renderSelectedGradesTerm();
    });

    $("enrollmentTerm").addEventListener("change", () => {
      renderSelectedEnrollmentTerm();
    });

    $("dfwiTerm").addEventListener("change", () => {
      renderSelectedDfwiTerm();
    });

    $("facultySurveyTerm").addEventListener("change", () => {
      renderSelectedFacultySurveyTerm();
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
        "The catalog is temporarily unavailable. No credentials or system details were exposed.";
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
    if (!course.course_id) {
      notice("No governed course identifier was returned.");
      return;
    }

    state.detailController?.abort();
    state.detailController=new AbortController();
    const timer=setTimeout(()=>state.detailController.abort(),15000);
    $("detailStatus").textContent="Loading approved course detail...";

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
        notice("The governed course-detail middleware route is not yet available. Catalog identity is shown; other sections remain unavailable.");
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
      notice("Approved course detail is temporarily unavailable. Catalog identity remains available.");
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
    notice("");
  }

  async function loadGrades(course) {
    resetGrades();

    state.gradesController = new AbortController();
    const controller = state.gradesController;

    if (!course.course_id) {
      showGradesMessage("No Grades available.");
      return;
    }

    showGradesMessage("Loading Grades...");

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

  async function loadEnrollment(course) {
    resetEnrollment();

    state.enrollmentController = new AbortController();
    const controller = state.enrollmentController;

    if (!course.course_id) {
      showEnrollmentMessage("No Enrollment data available.");
      return;
    }

    showEnrollmentMessage("Loading Enrollment...");

    const timer = setTimeout(() => controller.abort(), 15000);

    try {
      const response = await fetch(
        `/api/courses/${encodeURIComponent(course.course_id)}/enrollment`,
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
        throw new Error("enrollment");
      }

      const rows = Array.isArray(payload.data) ? payload.data : [];

      if (rows.length === 0) {
        showEnrollmentMessage("No Enrollment data available.");
        return;
      }

      state.enrollment = rows;
      populateEnrollmentTerms();

      $("enrollmentStatus").hidden = true;
      $("enrollmentContent").hidden = false;

      renderSelectedEnrollmentTerm();
    } catch (error) {
      if (error?.name === "AbortError") {
        showEnrollmentMessage("Enrollment data could not be loaded.");
        return;
      }

      showEnrollmentMessage(
        "Enrollment data is temporarily unavailable."
      );
    } finally {
      clearTimeout(timer);
    }
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

  function showEnrollmentMessage(message) {
    $("enrollmentContent").hidden = true;
    $("enrollmentStatus").textContent = message;
    $("enrollmentStatus").hidden = false;
  }

  function populateEnrollmentTerms() {
    const selector = $("enrollmentTerm");
    selector.replaceChildren();

    state.enrollment.forEach((enrollment, index) => {
      const option = document.createElement("option");

      option.value = String(index);
      option.textContent =
        enrollment.term_label ||
        enrollment.term_code ||
        `Term ${index + 1}`;

      selector.append(option);
    });

    selector.value = "0";
  }

  function renderSelectedEnrollmentTerm() {
    const index = Number($("enrollmentTerm").value);
    const enrollment = state.enrollment[index];

    if (!enrollment) {
      showEnrollmentMessage("No Enrollment data available.");
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

    state.dfwiController = new AbortController();
    const controller = state.dfwiController;

    if (!course.course_id) {
      showDfwiMessage("No DFWI data available.");
      return;
    }

    showDfwiMessage("Loading DFWI...");

    const timer = setTimeout(() => controller.abort(), 15000);

    try {
      const response = await fetch(
        `/api/courses/${encodeURIComponent(course.course_id)}/dfwi`,
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
        throw new Error("dfwi");
      }

      const rows = Array.isArray(payload.data) ? payload.data : [];

      if (rows.length === 0) {
        showDfwiMessage("No DFWI data available.");
        return;
      }

      state.dfwi = rows;
      populateDfwiTerms();

      $("dfwiStatus").hidden = true;
      $("dfwiContent").hidden = false;

      renderSelectedDfwiTerm();
    } catch (error) {
      if (error?.name === "AbortError") {
        showDfwiMessage("DFWI data could not be loaded.");
        return;
      }

      showDfwiMessage("DFWI data is temporarily unavailable.");
    } finally {
      clearTimeout(timer);
    }
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
    setGradeCount("dfwiCountD", 0);
    setGradeCount("dfwiCountF", 0);
    setGradeCount("dfwiCountW", 0);
    setGradeCount("dfwiCountI", 0);
  }

  function showDfwiMessage(message) {
    $("dfwiContent").hidden = true;
    $("dfwiStatus").textContent = message;
    $("dfwiStatus").hidden = false;
  }

  function populateDfwiTerms() {
    const selector = $("dfwiTerm");
    selector.replaceChildren();

    state.dfwi.forEach((dfwi, index) => {
      const option = document.createElement("option");

      option.value = String(index);
      option.textContent =
        dfwi.term_label ||
        dfwi.term_code ||
        `Term ${index + 1}`;

      selector.append(option);
    });

    selector.value = "0";
  }

  function renderSelectedDfwiTerm() {
    const index = Number($("dfwiTerm").value);
    const dfwi = state.dfwi[index];

    if (!dfwi) {
      showDfwiMessage("No DFWI data available.");
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

    setGradeCount("dfwiCountD", dfwi.d_count);
    setGradeCount("dfwiCountF", dfwi.f_count);
    setGradeCount("dfwiCountW", dfwi.w_count);
    setGradeCount("dfwiCountI", dfwi.i_count);
  }

  function formatDfwiRate(value) {
    const parsed = Number(value);

    return Number.isFinite(parsed)
      ? `${parsed.toFixed(2)}%`
      : unavailable;
  }


  async function loadFacultySurvey(course) {
    resetFacultySurvey();

    state.facultySurveyController = new AbortController();
    const controller = state.facultySurveyController;

    if (!course.course_id) {
      showFacultySurveyMessage("No Faculty Survey results available.");
      return;
    }

    showFacultySurveyMessage("Loading Faculty Survey results...");

    const timer = setTimeout(() => controller.abort(), 15000);

    try {
      const response = await fetch(
        `/api/courses/${encodeURIComponent(course.course_id)}/faculty-survey`,
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
        throw new Error("faculty-survey");
      }

      const rows = Array.isArray(payload.data)
        ? payload.data
        : [];

      if (rows.length === 0) {
        showFacultySurveyMessage("No Faculty Survey results available.");
        return;
      }

      state.facultySurvey = rows;
      populateFacultySurveyTerms();

      $("facultySurveyStatus").hidden = true;
      $("facultySurveyContent").hidden = false;

      renderSelectedFacultySurveyTerm();

    } catch (error) {

      if (error?.name === "AbortError") {
        showFacultySurveyMessage("Faculty Survey results could not be loaded.");
        return;
      }

      showFacultySurveyMessage(
        "Faculty Survey results are temporarily unavailable."
      );

    } finally {
      clearTimeout(timer);
    }
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

  function showFacultySurveyMessage(message) {
    $("facultySurveyContent").hidden = true;
    $("facultySurveyStatus").textContent = message;
    $("facultySurveyStatus").hidden = false;
  }

  function populateFacultySurveyTerms() {
    const selector = $("facultySurveyTerm");
    selector.replaceChildren();

    state.facultySurvey.forEach((survey, index) => {
      const option = document.createElement("option");

      option.value = String(index);
      option.textContent =
        survey.term_label ||
        survey.term_code ||
        `Term ${index + 1}`;

      selector.append(option);
    });

    selector.value = "0";
  }

  function renderSelectedFacultySurveyTerm() {
    const index = Number($("facultySurveyTerm").value);
    const survey = state.facultySurvey[index];

    if (!survey) {
      showFacultySurveyMessage("No Faculty Survey results available.");
      return;
    }

    $("facultySurveyStatus").hidden = true;
    $("facultySurveyContent").hidden = false;

    set(
      "facultySurveyVersion",
      survey.survey_version || unavailable
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

  async function loadFilterOptions() {
    const rows = [];
    let page = 1;
    let pages = 1;

    do {
      const params = new URLSearchParams({
        page:String(page),
        limit:"100",
        sort:"course_code"
      });

      const response = await fetch(`/api/courses?${params}`, {
        headers:{"Accept":"application/json"},
        credentials:"same-origin"
      });

      const payload = await json(response);

      if (!response.ok || payload.ok === false) {
        throw new Error("filters");
      }

      const batch = Array.isArray(payload.data) ? payload.data : [];
      rows.push(...batch);

      const total = number(
        payload?.meta?.total,
        rows.length
      );

      pages = Math.max(1,Math.ceil(total / 100));
      page++;
    } while (page <= pages);

    state.filterCourses = rows;

    const colleges = uniqueSorted(
      rows.map(row => row.college_name)
    );

    populateSelect(
      "collegeFilter",
      "All colleges",
      colleges
    );

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










