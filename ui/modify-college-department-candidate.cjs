const fs = require("node:fs");

const file = "./ui/app.college-department.candidate.js";
let text = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");

function replaceOnce(oldText, newText, label) {
  const count = text.split(oldText).length - 1;

  if (count !== 1) {
    throw new Error(
      `${label}_ANCHOR_COUNT=${count}`
    );
  }

  text = text.replace(oldText, newText);
}

replaceOnce(
`    "college_name","course_description","course_goals",
    "course_learning_outcomes"`,
`    "college_name","department_name","course_description","course_goals",
    "course_learning_outcomes"`,
"DETAIL_FIELDS"
);

replaceOnce(
`    code: "", title: "", total: 0, pages: 1, courses: [],
    listController: null, detailController: null`,
`    code: "", title: "", college: "", department: "",
    total: 0, pages: 1, courses: [], filterCourses: [],
    listController: null, detailController: null`,
"STATE"
);

replaceOnce(
`  document.addEventListener("DOMContentLoaded", () => {`,
`  document.addEventListener("DOMContentLoaded", async () => {`,
"DOM_READY"
);

replaceOnce(
`      state.title = $("courseTitle").value.trim();
      state.sort = $("sortOrder").value;`,
`      state.title = $("courseTitle").value.trim();
      state.college = $("collegeFilter").value;
      state.department = $("departmentFilter").value;
      state.sort = $("sortOrder").value;`,
"SUBMIT_FILTERS"
);

replaceOnce(
`        page:1, limit:25, sort:"course_id", code:"", title:""
      });
      loadCourses();`,
`        page:1, limit:25, sort:"course_id",
        code:"", title:"", college:"", department:""
      });
      populateDepartments();
      loadCourses();`,
"RESET_FILTERS"
);

replaceOnce(
`    $("closeDetail").addEventListener("click", () => $("courseDetailDialog").close());
    loadCourses();`,
`    $("closeDetail").addEventListener("click", () => $("courseDetailDialog").close());

    $("collegeFilter").addEventListener("change", () => {
      populateDepartments();
    });

    try {
      await loadFilterOptions();
    } catch {
      $("collegeFilter").disabled = true;
      $("departmentFilter").disabled = true;
    }

    loadCourses();`,
"INITIAL_LOAD"
);

replaceOnce(
`      if (state.code) params.set("course_code",state.code);
      if (state.title) params.set("course_title",state.title);`,
`      if (state.code) params.set("course_code",state.code);
      if (state.title) params.set("course_title",state.title);
      if (state.college) params.set("college_name",state.college);
      if (state.department) params.set("department_name",state.department);`,
"API_FILTERS"
);

replaceOnce(
`      row.append(cell(course.course_title));
      row.append(cell(course.university_course_id));`,
`      row.append(cell(course.course_title));
      row.append(cell(course.college_name));
      row.append(cell(course.department_name));
      row.append(cell(course.university_course_id));`,
"TABLE_FIELDS"
);

replaceOnce(
`      set("detailCollege",detail.college_name);
      set("detailDescription",detail.course_description);`,
`      set("detailCollege",detail.college_name);
      set("detailDepartment",detail.department_name);
      set("detailDescription",detail.course_description);`,
"DETAIL_DISPLAY"
);

replaceOnce(
`    ["detailCollege","detailDescription","detailGoals","detailOutcomes"]
      .forEach(id=>set(id,null));`,
`    set("detailCollege",course.college_name);
    set("detailDepartment",course.department_name);
    ["detailDescription","detailGoals","detailOutcomes"]
      .forEach(id=>set(id,null));`,
"DETAIL_RESET"
);

replaceOnce(
`  function set(id,value) {`,
`  async function loadFilterOptions() {
    const rows = [];
    let page = 1;
    let pages = 1;

    do {
      const params = new URLSearchParams({
        page:String(page),
        limit:"100",
        sort:"course_id"
      });

      const response = await fetch(\`/api/courses?\${params}\`, {
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

  function set(id,value) {`,
"FILTER_FUNCTIONS"
);

fs.writeFileSync(file, text, "utf8");