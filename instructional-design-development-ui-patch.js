"use strict";

const fs = require("fs");
const path = require("path");
const root = process.cwd();
const htmlSource = path.join(root,"ui","index.html");
const jsSource = path.join(root,"ui","app.js");
const htmlBackup = path.join(root,"ui","index.pre-instructional-design-development-ui.backup.html");
const jsBackup = path.join(root,"ui","app.pre-instructional-design-development-ui.backup.js");
const htmlCandidate = path.join(root,"ui","index.instructional-design-development.candidate.html");
const jsCandidate = path.join(root,"ui","app.instructional-design-development.candidate.js");

for (const p of [htmlSource,jsSource,htmlBackup,jsBackup]) if (!fs.existsSync(p)) throw new Error(`STOP: missing ${p}`);
if (fs.existsSync(htmlCandidate) || fs.existsSync(jsCandidate)) throw new Error("STOP: candidate already exists; do not overwrite it");
if (fs.readFileSync(htmlSource,"utf8") !== fs.readFileSync(htmlBackup,"utf8")) throw new Error("STOP: live HTML no longer matches protected backup");
if (fs.readFileSync(jsSource,"utf8") !== fs.readFileSync(jsBackup,"utf8")) throw new Error("STOP: live JS no longer matches protected backup");

let html = fs.readFileSync(htmlSource,"utf8");
const oldHtml = `    <section>\n      <h3>Instructional design and development</h3>\n      <article><p class="unavailable">Not yet available</p></article>\n    </section>`;
const newHtml = `    <section>\n      <h3>Instructional design and development</h3>\n      <article>\n        <p id="iddStatus" class="unavailable">Loading Instructional design and development...</p>\n        <div id="iddContent" hidden>\n          <label for="iddMonth">Development period</label>\n          <select id="iddMonth" aria-label="Instructional design and development period"></select>\n          <p id="iddRecordStatus" class="unavailable" hidden>No Data</p>\n          <dl id="iddRecords" class="grades-summary" aria-live="polite"></dl>\n        </div>\n      </article>\n    </section>`;
if ((html.split(oldHtml).length-1)!==1) throw new Error("STOP: expected IDD HTML placeholder exactly once");
html = html.replace(oldHtml,newHtml);
fs.writeFileSync(htmlCandidate,html,"utf8");

let js = fs.readFileSync(jsSource,"utf8");
function replaceOnce(oldText,newText,label){ const n=js.split(oldText).length-1; if(n!==1) throw new Error(`STOP: ${label} match count ${n}`); js=js.replace(oldText,newText); }
replaceOnce(
`    studentSurveyController: null, studentSurvey: [],\n    studentSurveyQuestionController: null, studentSurveyQuestions: []`,
`    studentSurveyController: null, studentSurvey: [],\n    studentSurveyQuestionController: null, studentSurveyQuestions: [],\n    instructionalDesignDevelopmentController: null, instructionalDesignDevelopment: []`,"state");
replaceOnce(
`    $("studentSurveyInstrument").addEventListener("change", () => {\n      renderSelectedStudentSurveyQuestions();\n    });`,
`    $("studentSurveyInstrument").addEventListener("change", () => {\n      renderSelectedStudentSurveyQuestions();\n    });\n\n    $("iddMonth").addEventListener("change", () => {\n      renderSelectedInstructionalDesignDevelopment();\n    });`,"listener");
replaceOnce(
`    loadStudentSurvey(course);\n    loadStudentSurveyQuestions(course);`,
`    loadStudentSurvey(course);\n    loadStudentSurveyQuestions(course);\n    loadInstructionalDesignDevelopment(course);`,"openDetail");
replaceOnce(
`    resetGrades();\n    notice("");`,
`    resetGrades();\n    resetInstructionalDesignDevelopment();\n    notice("");`,"resetDetail");

const marker = `\n\n  function setGradeCount(id, value) {`;
if ((js.split(marker).length-1)!==1) throw new Error("STOP: setGradeCount marker mismatch");
const block = `\n\n  function resetInstructionalDesignDevelopment() {\n    state.instructionalDesignDevelopmentController?.abort();\n    state.instructionalDesignDevelopmentController = null;\n    state.instructionalDesignDevelopment = [];\n    $("iddMonth").replaceChildren();\n    $("iddRecords").replaceChildren();\n    $("iddStatus").textContent = "No Data";\n    $("iddStatus").hidden = false;\n    $("iddRecordStatus").textContent = "No Data";\n    $("iddRecordStatus").hidden = true;\n    $("iddContent").hidden = true;\n  }\n\n  async function loadInstructionalDesignDevelopment(course) {\n    resetInstructionalDesignDevelopment();\n    if (!course.course_id) return;\n\n    state.instructionalDesignDevelopmentController = new AbortController();\n    const controller = state.instructionalDesignDevelopmentController;\n    const timer = setTimeout(() => controller.abort(), 15000);\n    $("iddStatus").textContent = "Loading Instructional design and development...";\n\n    try {\n      const response = await fetch(\n        "/api/courses/" + encodeURIComponent(course.course_id) + "/instructional-design-development",\n        { headers:{ Accept:"application/json" }, credentials:"same-origin", signal:controller.signal }\n      );\n      const payload = await json(response);\n      if (!response.ok || payload.ok === false) throw new Error("instructional-design-development");\n      state.instructionalDesignDevelopment = Array.isArray(payload.data) ? payload.data : [];\n      populateInstructionalDesignDevelopmentMonths();\n      $("iddStatus").hidden = state.instructionalDesignDevelopment.length > 0;\n      $("iddStatus").textContent = state.instructionalDesignDevelopment.length > 0 ? "" : "No Data";\n      $("iddContent").hidden = false;\n      renderSelectedInstructionalDesignDevelopment();\n    } catch (error) {\n      if (error?.name !== "AbortError") {\n        $("iddStatus").textContent = "Instructional design and development data is temporarily unavailable.";\n      }\n      $("iddStatus").hidden = false;\n      $("iddContent").hidden = true;\n    } finally { clearTimeout(timer); }\n  }\n\n  function populateInstructionalDesignDevelopmentMonths() {\n    const selector = $("iddMonth");\n    const previous = selector.value;\n    const months = uniqueSorted(\n      state.instructionalDesignDevelopment.map(row => row.idd_year_month)\n    ).sort((a,b) => b.localeCompare(a));\n    selector.replaceChildren();\n    months.forEach(month => {\n      const option = document.createElement("option");\n      option.value = month;\n      option.textContent = month;\n      selector.append(option);\n    });\n    selector.value = months.includes(previous) ? previous : (months[0] || "");\n  }\n\n  function renderSelectedInstructionalDesignDevelopment() {\n    const container = $("iddRecords");\n    const status = $("iddRecordStatus");\n    const month = $("iddMonth").value;\n    container.replaceChildren();\n    const rows = state.instructionalDesignDevelopment.filter(row => row.idd_year_month === month);\n    if (!month || rows.length === 0) { status.textContent="No Data"; status.hidden=false; return; }\n    status.hidden = true;\n    rows.forEach((row,index) => {\n      const fields = [\n        [rows.length > 1 ? "Project " + (index+1) + " status" : "Project status", row.project_status],\n        ["Project type", row.project_type],\n        ["Course developer", row.course_developer],\n        ["Instructional designer", row.instructional_designer],\n        ["Project finished date", formatIddExcelDate(row.project_finished_date_raw)],\n        ["Developer completion date", formatIddExcelDate(row.developer_completion_date_raw)],\n        ["Important project dates", row.important_project_dates],\n        ["Course delayed reason", row.course_delayed_reason]\n      ];\n      fields.forEach(([label,value]) => {\n        const card=document.createElement("div");\n        const dt=document.createElement("dt");\n        const dd=document.createElement("dd");\n        dt.textContent=label;\n        const valid=value!==null && value!==undefined && String(value).trim()!=="";\n        dd.textContent=valid ? String(value).trim() : "No Data";\n        dd.classList.toggle("unavailable",!valid);\n        card.append(dt,dd);\n        container.append(card);\n      });\n    });\n  }\n\n  function formatIddExcelDate(value) {\n    if (value === null || value === undefined || String(value).trim() === "") return null;\n    const serial = Number(value);\n    if (!Number.isFinite(serial) || serial < 30000 || serial > 60000) return null;\n    const date = new Date(Date.UTC(1899,11,30) + serial * 86400000);\n    return Number.isNaN(date.getTime()) ? null : new Intl.DateTimeFormat("en-US",{dateStyle:"medium",timeZone:"UTC"}).format(date);\n  }`;
js=js.replace(marker,block+marker);
fs.writeFileSync(jsCandidate,js,"utf8");
console.log(`HTML_CANDIDATE=${htmlCandidate}`);
console.log(`JS_CANDIDATE=${jsCandidate}`);
