"use strict";

(() => {
  const detailFields = [
    "course_id","university_course_id","course_code","course_title",
    "college_name","course_description","course_goals",
    "course_learning_outcomes"
  ];

  const state = {
    page: 1, limit: 25, sort: "course_id",
    code: "", title: "", total: 0, pages: 1, courses: [],
    listController: null, detailController: null
  };

  const $ = id => document.getElementById(id);
  const unavailable = "Not yet available";

  document.addEventListener("DOMContentLoaded", () => {
    $("filterForm").addEventListener("submit", event => {
      event.preventDefault();
      state.page = 1;
      state.code = $("courseCode").value.trim();
      state.title = $("courseTitle").value.trim();
      state.sort = $("sortOrder").value;
      state.limit = Number($("pageSize").value);
      loadCourses();
    });

    $("resetFilters").addEventListener("click", () => {
      $("filterForm").reset();
      Object.assign(state, {
        page:1, limit:25, sort:"course_id", code:"", title:""
      });
      loadCourses();
    });

    $("previousPage").addEventListener("click", () => {
      if (state.page > 1) { state.page--; loadCourses(); }
    });
    $("nextPage").addEventListener("click", () => {
      if (state.page < state.pages) { state.page++; loadCourses(); }
    });
    $("closeDetail").addEventListener("click", () => $("courseDetailDialog").close());
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
    ["detailCollege","detailDescription","detailGoals","detailOutcomes"]
      .forEach(id=>set(id,null));
    notice("");
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