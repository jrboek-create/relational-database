"use strict";

const fs = require("fs");
const path = require("path");

const root = process.cwd();
const sourcePath = path.join(root, "middleware", "src", "server.js");
const backupPath = path.join(root, "middleware", "src", "server.pre-instructional-design-development-api.backup.js");
const candidatePath = path.join(root, "middleware", "src", "server.instructional-design-development.candidate.js");

if (!fs.existsSync(sourcePath)) throw new Error("STOP: middleware source not found");
if (!fs.existsSync(backupPath)) throw new Error("STOP: protected middleware backup not found");
if (fs.existsSync(candidatePath)) throw new Error("STOP: candidate already exists; do not overwrite it");

const source = fs.readFileSync(sourcePath, "utf8");
const backup = fs.readFileSync(backupPath, "utf8");
if (source !== backup) throw new Error("STOP: source no longer matches protected backup");

const marker = 'app.listen(port, "0.0.0.0", () => {';
const markerCount = source.split(marker).length - 1;
if (markerCount !== 1) throw new Error(`STOP: expected one app.listen marker; found ${markerCount}`);

const block = String.raw`const instructionalDesignDevelopmentFields = [
  "instructional_design_development_summary_id",
  "course_id",
  "university_course_id",
  "course_code",
  "course_title",
  "college_name",
  "department_name",
  "raw_course",
  "extracted_course_code",
  "catalog_match_status",
  "idd_year_month",
  "raw_idd_term",
  "term_id",
  "term_code",
  "term_label",
  "institutional_term_match_status",
  "project_type",
  "source_college",
  "project_status",
  "course_developer",
  "instructional_designer",
  "notes",
  "project_schedule_changes",
  "major_side_project_type",
  "important_project_dates",
  "project_finished_date_raw",
  "developer_completion_date_raw",
  "days_late_after_course_copy",
  "weeks_late_course_copy",
  "days_past_contract_due_date",
  "weeks_past_contract_due_date",
  "course_delayed_reason",
  "kickoff_info_needed",
  "eoc_feedback",
  "contract",
  "supplemental_pay_request",
  "snapgen_notes",
  "snapgen_section_count",
  "snapgen_sections_released",
  "modified_timestamp",
  "modified_by",
  "hide_project",
  "report_refresh_run_id",
  "report_as_of_utc"
];

app.get("/api/courses/:course_id/instructional-design-development", async (req, res) => {
  const started = Date.now();

  const fail = (status, code, message) => {
    console.log(JSON.stringify({
      event: "request",
      request_id: req.requestId,
      method: req.method,
      path: req.path,
      status,
      duration_ms: Date.now() - started
    }));

    return res.status(status).json({
      ok: false,
      request_id: req.requestId,
      error: { code, message }
    });
  };

  try {
    if (Object.keys(req.query).length !== 0) {
      return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");
    }

    const rawCourseId = req.params.course_id;
    const courseId = typeof rawCourseId === "string" ? rawCourseId.trim() : "";
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (!uuidPattern.test(courseId)) {
      return fail(400, "INVALID_QUERY", "course_id must be a valid UUID.");
    }

    const params = new URLSearchParams();
    params.set("fields", instructionalDesignDevelopmentFields.join(","));
    params.set("filter[course_id][_eq]", courseId);
    params.set("sort", "-idd_year_month,project_type,project_status,modified_timestamp");
    params.set("limit", "5000");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);

    let upstream;
    try {
      upstream = await fetch(
        directusUrl + "/items/course_instructional_design_development_summary_api?" + params.toString(),
        {
          headers: {
            Authorization: "Bearer " + directusToken,
            Accept: "application/json",
            "x-request-id": req.requestId
          },
          signal: controller.signal
        }
      );
    } finally {
      clearTimeout(timeout);
    }

    if (!upstream.ok) {
      return fail(
        502,
        "DIRECTUS_UNAVAILABLE",
        "The Instructional design and development data service is unavailable."
      );
    }

    const payload = await upstream.json();
    if (!Array.isArray(payload.data)) {
      return fail(500, "INTERNAL_ERROR", "The request could not be completed.");
    }

    const data = payload.data.map((row) =>
      Object.fromEntries(
        instructionalDesignDevelopmentFields.map((field) => [field, row[field] ?? null])
      )
    );

    console.log(JSON.stringify({
      event: "request",
      request_id: req.requestId,
      method: req.method,
      path: req.path,
      status: 200,
      returned: data.length,
      duration_ms: Date.now() - started
    }));

    return res.status(200).json({
      ok: true,
      request_id: req.requestId,
      data,
      meta: {
        course_id: courseId,
        returned: data.length,
        sort: "-idd_year_month,project_type,project_status,modified_timestamp",
        report_refresh_run_id: data[0]?.report_refresh_run_id ?? null,
        report_as_of_utc: data[0]?.report_as_of_utc ?? null
      }
    });
  } catch (error) {
    const timedOut = error?.name === "AbortError";
    return fail(
      timedOut ? 504 : 500,
      timedOut ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR",
      timedOut
        ? "The Instructional design and development data service timed out."
        : "The request could not be completed."
    );
  }
});

`;

const candidate = source.replace(marker, block + marker);
fs.writeFileSync(candidatePath, candidate, "utf8");
console.log(`CANDIDATE=${candidatePath}`);
