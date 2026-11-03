import express from "express";
import compression from "compression";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import crypto from "node:crypto";

const app = express();
const port = Number(process.env.PORT || 3000);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const tokenPath = path.resolve(__dirname, "../../.secrets/wwairml_directus_static_token.txt");
const directusUrl = (process.env.DIRECTUS_URL || "http://127.0.0.1:8066").replace(/\/+$/, "");
const directusToken = readFileSync(tokenPath, "utf8").trim();
const exportDir = path.resolve(process.env.EXPORT_DIR || "/exports");
const approvedFields = ["course_id","university_course_id","course_code","course_title","college_name","department_name","source_system_code","report_refresh_run_id","report_as_of_utc"];
const detailFields = ["course_id","university_course_id","course_code","course_title","college_name","department_name","course_description","course_goals","course_learning_outcomes"];
const allowedParams = new Set(["page","limit","course_code","course_title","college_name","department_name","sort"]);
const allowedSorts = new Set(["course_code","-course_code"]);

app.disable("x-powered-by");
app.use(compression());  // gzip responses for clients that accept it (large JSON)
app.use(express.json({ limit: "100kb" }));

app.use((req, res, next) => {
  const supplied = req.get("x-request-id");
  req.requestId = supplied && /^[A-Za-z0-9._:-]{1,128}$/.test(supplied) ? supplied : crypto.randomUUID();
  res.set("x-request-id", req.requestId);
  next();
});

app.get("/health", (_req, res) => {
  res.status(200).json({
    status: "ok",
    service: "air-course-development-middleware"
  });
});

app.get("/api/courses", async (req, res) => {
  const started = Date.now();
  const fail = (status, code, message) => {
    console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, duration_ms: Date.now() - started }));
    return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  };

  try {
    const unsupported = Object.keys(req.query).filter((key) => !allowedParams.has(key));
    if (unsupported.length) return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");

    const pageRaw = req.query.page ?? "1";
    const limitRaw = req.query.limit ?? "25";
    const sort = req.query.sort ?? "course_code";
    if (!/^[1-9]\d*$/.test(String(pageRaw))) return fail(400, "INVALID_QUERY", "page must be a positive integer.");
    if (!/^[1-9]\d*$/.test(String(limitRaw))) return fail(400, "INVALID_QUERY", "limit must be a positive integer.");

    const page = Number(pageRaw);
    const limit = Number(limitRaw);
    if (!Number.isSafeInteger(page)) return fail(400, "INVALID_QUERY", "page is outside the supported range.");
    if (!Number.isSafeInteger(limit) || limit > 100) return fail(400, "INVALID_QUERY", "limit must be between 1 and 100.");
    if (!allowedSorts.has(String(sort))) return fail(400, "INVALID_QUERY", "sort must be course_code or -course_code.");

    for (const key of ["course_code","course_title","college_name","department_name"]) {
      if (req.query[key] !== undefined && (typeof req.query[key] !== "string" || req.query[key].length > 200)) {
        return fail(400, "INVALID_QUERY", `${key} must be a string of 200 characters or fewer.`);
      }
    }

    const params = new URLSearchParams();
    params.set("fields", approvedFields.join(","));
    params.set("page", String(page));
    params.set("limit", String(limit));
    params.set("sort", String(sort));
    params.set("meta", "filter_count");
    if (req.query.course_code) params.set("filter[course_code][_icontains]", req.query.course_code);
    if (req.query.course_title) params.set("filter[course_title][_icontains]", req.query.course_title);
    if (req.query.college_name) params.set("filter[college_name][_eq]", req.query.college_name);
    if (req.query.department_name) params.set("filter[department_name][_eq]", req.query.department_name);

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    let upstream;
    try {
      upstream = await fetch(`${directusUrl}/items/course_current_catalog_api?${params.toString()}`, {
        headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": req.requestId },
        signal: controller.signal
      });
    } finally {
      clearTimeout(timeout);
    }

    if (!upstream.ok) {
      if (upstream.status === 401) return fail(502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");
      if (upstream.status === 403) return fail(502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");
      return fail(502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");
    }

    const payload = await upstream.json();
    const rows = Array.isArray(payload.data) ? payload.data : [];
    const data = rows.map((row) => Object.fromEntries(approvedFields.map((field) => [field, row[field] ?? null])));
    const first = data[0] ?? {};
    const total = Number(payload?.meta?.filter_count ?? data.length);

    console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status: 200, returned: data.length, duration_ms: Date.now() - started }));
    return res.status(200).json({
      ok: true,
      request_id: req.requestId,
      data,
      meta: {
        page,
        limit,
        returned: data.length,
        total,
        sort: String(sort),
        report_refresh_run_id: first.report_refresh_run_id ?? null,
        report_as_of_utc: first.report_as_of_utc ?? null
      }
    });
  } catch (error) {
    const code = error?.name === "AbortError" ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR";
    const message = error?.name === "AbortError" ? "The course data service timed out." : "The request could not be completed.";
    return fail(error?.name === "AbortError" ? 504 : 500, code, message);
  }
});

app.get("/api/courses/:course_id", async (req, res) => {
  const started = Date.now();
  const fail = (status, code, message) => {
    console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, duration_ms: Date.now() - started }));
    return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  };

  try {
    if (Object.keys(req.query).length !== 0) return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");

    const rawCourseId = req.params.course_id;
    const courseId = typeof rawCourseId === "string" ? rawCourseId.trim() : "";
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuidPattern.test(courseId)) return fail(400, "INVALID_QUERY", "course_id must be a valid UUID.");

    const params = new URLSearchParams();
    params.set("fields", detailFields.join(","));
    params.set("filter[course_id][_eq]", courseId);
    params.set("limit", "1");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    let upstream;
    try {
      upstream = await fetch(`${directusUrl}/items/course_catalog_detail_api?${params.toString()}`, {
        headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": req.requestId },
        signal: controller.signal
      });
    } finally {
      clearTimeout(timeout);
    }

    if (!upstream.ok) return fail(502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");

    const payload = await upstream.json();
    if (!Array.isArray(payload.data)) return fail(500, "INTERNAL_ERROR", "The request could not be completed.");
    const rows = payload.data;
    if (rows.length === 0) return fail(404, "NOT_FOUND", "The requested course was not found.");
    if (rows.length > 1) return fail(500, "INTERNAL_ERROR", "The request could not be completed.");

    const data = Object.fromEntries(detailFields.map((field) => [field, rows[0][field] ?? null]));
    console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status: 200, duration_ms: Date.now() - started }));
    return res.status(200).json({ ok: true, request_id: req.requestId, data });
  } catch (error) {
    const code = error?.name === "AbortError" ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR";
    const message = error?.name === "AbortError" ? "The course data service timed out." : "The request could not be completed.";
    return fail(error?.name === "AbortError" ? 504 : 500, code, message);
  }
});

// Distinct college/department pairs for the catalog filter dropdowns.
app.get("/api/filter-options", async (req, res) => {
  const started = Date.now();
  const log = (status, extra = {}) => console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, ...extra, duration_ms: Date.now() - started }));
  const fail = (status, code, message) => {
    log(status);
    return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  };

  try {
    if (Object.keys(req.query).length !== 0) return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");

    const params = new URLSearchParams();
    params.append("groupBy[]", "college_name");
    params.append("groupBy[]", "department_name");
    params.set("aggregate[count]", "course_id");
    params.set("limit", "1000");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    let upstream;
    try {
      upstream = await fetch(`${directusUrl}/items/course_current_catalog_api?${params.toString()}`, {
        headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": req.requestId },
        signal: controller.signal
      });
    } finally {
      clearTimeout(timeout);
    }

    if (!upstream.ok) return fail(502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");

    const payload = await upstream.json();
    if (!Array.isArray(payload.data)) return fail(500, "INTERNAL_ERROR", "The request could not be completed.");

    const data = payload.data.map((row) => ({ college_name: row.college_name ?? null, department_name: row.department_name ?? null }));
    log(200, { returned: data.length });
    return res.status(200).json({ ok: true, request_id: req.requestId, data, meta: { returned: data.length } });
  } catch (error) {
    const timedOut = error?.name === "AbortError";
    return fail(
      timedOut ? 504 : 500,
      timedOut ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR",
      timedOut ? "The course data service timed out." : "The request could not be completed."
    );
  }
});

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Per-course sections. Each one becomes GET /api/courses/:course_id/<path>
// and reads the matching reporting collection in Directus.
const courseSections = [
  {
    path: "grades",
    label: "Grades",
    collection: "course_grade_summary_api",
    sort: "-term_code",
    limit: 100,
    fields: ["grade_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "grade_count", "scored_count", "average_final_score", "grade_a_count", "grade_au_count", "grade_b_count", "grade_c_count", "grade_d_count", "grade_f_count", "grade_fx_count", "grade_i_count", "grade_ip_count", "grade_n_count", "grade_nc_count", "grade_ns_count", "grade_ntg_count", "grade_p_count", "grade_s_count", "grade_w_count", "grade_wf_count", "other_grade_count", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "enrollment",
    label: "Enrollment",
    collection: "course_enrollment_summary_api",
    sort: "-term_code",
    limit: 100,
    fields: ["enrollment_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "offering_count", "enrollment_count", "minimum_section_enrollment", "maximum_section_enrollment", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "dfwi",
    label: "DFWI",
    collection: "course_dfwi_summary_api",
    sort: "-term_code",
    limit: 100,
    meta: { formula: "(D + F + W + I) / enrollment * 100" },
    fields: ["dfwi_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "enrollment_count", "d_count", "f_count", "w_count", "i_count", "dfwi_count", "dfwi_rate_pct", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "faculty-survey",
    label: "Faculty Survey",
    collection: "course_faculty_survey_summary_api",
    sort: "-term_code",
    limit: 100,
    meta: { scale: "1-5" },
    fields: ["faculty_survey_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "survey_version", "faculty_response_count", "old_response_count", "new_response_count", "teaching_response_count", "average_teaching_experience", "quality_response_count", "average_course_quality", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "student-survey",
    label: "Student Survey",
    collection: "course_student_survey_summary_api",
    sort: "-term_code",
    limit: 100,
    meta: { scale: "1-5" },
    fields: ["student_survey_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "survey_version", "student_response_count", "old_response_count", "new_response_count", "teaching_response_count", "average_teaching_effectiveness", "course_quality_response_count", "average_course_quality", "course_recommendation_response_count", "average_course_recommendation", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "student-survey/questions",
    label: "Student Survey question",
    collection: "course_student_survey_question_summary_api",
    sort: "-term_code,survey_version,question_number",
    limit: 5000,
    meta: { scale: "1-5" },
    fields: ["student_survey_question_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "survey_version", "question_number", "question_code", "question_title", "valid_response_count", "average_rating", "minimum_rating", "maximum_rating", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "instructional-design-development",
    label: "Instructional design and development",
    collection: "course_instructional_design_development_summary_api",
    sort: "-idd_year_month,project_type,project_status,modified_timestamp",
    limit: 5000,
    fields: ["instructional_design_development_summary_id", "course_id", "university_course_id", "course_code", "course_title", "college_name", "department_name", "raw_course", "extracted_course_code", "catalog_match_status", "idd_year_month", "raw_idd_term", "term_id", "term_code", "term_label", "institutional_term_match_status", "project_type", "source_college", "project_status", "course_developer", "instructional_designer", "notes", "project_schedule_changes", "major_side_project_type", "important_project_dates", "project_finished_date_raw", "developer_completion_date_raw", "days_late_after_course_copy", "weeks_late_course_copy", "days_past_contract_due_date", "weeks_past_contract_due_date", "course_delayed_reason", "kickoff_info_needed", "eoc_feedback", "contract", "supplemental_pay_request", "snapgen_notes", "snapgen_section_count", "snapgen_sections_released", "modified_timestamp", "modified_by", "hide_project", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "ai-production",
    label: "AI production",
    collection: "course_ai_production_summary_api",
    sort: "-implementation_month,project_name",
    limit: 500,
    fields: ["ai_production_summary_id", "course_id", "university_course_id", "course_code", "course_title", "college_name", "department_name", "raw_course", "catalog_match_status", "implementation_month", "implementation_label", "project_name", "ai_type", "project_status", "description", "template_link", "source_college", "ai_section_count", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "integrations",
    label: "Integrations",
    collection: "course_integration_summary_api",
    sort: "integration_order,-integration_month",
    limit: 500,
    fields: ["integration_summary_id", "course_id", "university_course_id", "course_code", "course_title", "college_name", "department_name", "raw_course", "catalog_match_status", "integration_name", "integration_order", "date_meaning", "integration_month", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "redeveloped",
    label: "Redeveloped course feedback",
    collection: "course_redeveloped_summary_api",
    sort: "-term_code,section_identifier",
    limit: 500,
    fields: ["redeveloped_summary_id", "course_id", "university_course_id", "course_code", "course_title", "college_name", "department_name", "raw_course", "catalog_match_status", "sis_source_id", "term_id", "term_code", "term_label", "section_identifier", "responded", "response_date", "helpfulness_rating", "significant_changes", "changes_detail", "would_have_liked_to_know", "report_refresh_run_id", "report_as_of_utc"]
  },
  {
    path: "observations",
    label: "Faculty observations",
    collection: "course_observation_summary_api",
    sort: "item_number",
    limit: 100,
    fields: ["observation_summary_id", "course_id", "university_course_id", "course_code", "course_title", "college_name", "department_name", "raw_course", "catalog_match_status", "item_number", "item_text", "observation_count", "first_term_month", "last_term_month", "suppressed", "count_yes", "count_no", "count_exceeds", "count_meets", "count_below", "count_not_applicable", "count_coaching", "count_not_rated", "report_refresh_run_id", "report_as_of_utc"]
  }
];

for (const section of courseSections) {
  app.get(`/api/courses/:course_id/${section.path}`, async (req, res) => {
    const started = Date.now();
    const log = (status, extra = {}) => console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, ...extra, duration_ms: Date.now() - started }));
    const fail = (status, code, message) => {
      log(status);
      return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
    };

    try {
      if (Object.keys(req.query).length !== 0) return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");

      const courseId = typeof req.params.course_id === "string" ? req.params.course_id.trim() : "";
      if (!uuidPattern.test(courseId)) return fail(400, "INVALID_QUERY", "course_id must be a valid UUID.");

      const params = new URLSearchParams();
      params.set("fields", section.fields.join(","));
      params.set("filter[course_id][_eq]", courseId);
      params.set("sort", section.sort);
      params.set("limit", String(section.limit));

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      let upstream;
      try {
        upstream = await fetch(`${directusUrl}/items/${section.collection}?${params.toString()}`, {
          headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": req.requestId },
          signal: controller.signal
        });
      } finally {
        clearTimeout(timeout);
      }

      if (!upstream.ok) return fail(502, "DIRECTUS_UNAVAILABLE", `The ${section.label} data service is unavailable.`);

      const payload = await upstream.json();
      if (!Array.isArray(payload.data)) return fail(500, "INTERNAL_ERROR", "The request could not be completed.");

      const data = payload.data.map((row) => Object.fromEntries(section.fields.map((field) => [field, row[field] ?? null])));
      log(200, { returned: data.length });
      return res.status(200).json({
        ok: true,
        request_id: req.requestId,
        data,
        meta: {
          course_id: courseId,
          returned: data.length,
          sort: section.sort,
          ...section.meta,
          report_refresh_run_id: data[0]?.report_refresh_run_id ?? null,
          report_as_of_utc: data[0]?.report_as_of_utc ?? null
        }
      });
    } catch (error) {
      const timedOut = error?.name === "AbortError";
      return fail(
        timedOut ? 504 : 500,
        timedOut ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR",
        timedOut ? `The ${section.label} data service timed out.` : "The request could not be completed."
      );
    }
  });
}

// Data status: row count and last rebuild time of each reporting collection (one Directus aggregate call each).
app.get("/api/data-status", async (req, res) => {
  const started = Date.now();
  const log = (status, extra = {}) => console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, ...extra, duration_ms: Date.now() - started }));
  if (Object.keys(req.query).length !== 0) {
    log(400);
    return res.status(400).json({ ok: false, request_id: req.requestId, error: { code: "INVALID_QUERY", message: "The request contains an unsupported parameter." } });
  }
  const first = (value) => (value !== null && typeof value === "object" ? Object.values(value)[0] : value);
  const sections = [{ label: "Course catalog", collection: "course_current_catalog_api" }, ...courseSections];
  const data = await Promise.all(sections.map(async (section) => {
    const result = { section: section.label, collection: section.collection, available: false, rows: null, last_refreshed_utc: null };
    const params = new URLSearchParams();
    params.set("aggregate[count]", "*");
    params.set("aggregate[max]", "report_as_of_utc");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const upstream = await fetch(`${directusUrl}/items/${section.collection}?${params.toString()}`, {
        headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": req.requestId },
        signal: controller.signal
      });
      if (!upstream.ok) return result;
      const row = (await upstream.json())?.data?.[0] ?? {};
      const count = first(row.count);
      return { ...result, available: true, rows: count === null || count === undefined ? null : Number(count), last_refreshed_utc: first(row.max) ?? null };
    } catch {
      return result;
    } finally {
      clearTimeout(timeout);
    }
  }));
  log(200, { returned: data.length });
  return res.status(200).json({ ok: true, request_id: req.requestId, data, meta: { returned: data.length } });
});

// Bulk export: the JSON files written by the uploader's export step (twbx_upload.py export), served as they are.
// GET /api/export lists the datasets (from manifest.json); GET /api/export/<dataset> returns one whole dataset.
function readManifest() {
  try {
    return JSON.parse(readFileSync(path.join(exportDir, "manifest.json"), "utf8"));
  } catch {
    return null;
  }
}

app.get("/api/export", (req, res) => {
  const started = Date.now();
  const log = (status, extra = {}) => console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, ...extra, duration_ms: Date.now() - started }));
  if (Object.keys(req.query).length !== 0) {
    log(400);
    return res.status(400).json({ ok: false, request_id: req.requestId, error: { code: "INVALID_QUERY", message: "The request contains an unsupported parameter." } });
  }
  const manifest = readManifest();
  if (!manifest || !Array.isArray(manifest.datasets)) {
    log(404);
    return res.status(404).json({ ok: false, request_id: req.requestId, error: { code: "NOT_EXPORTED", message: "No export is available yet." } });
  }
  const data = manifest.datasets.map((d) => ({ ...d, url: `/api/export/${d.dataset}` }));
  log(200, { returned: data.length });
  return res.status(200).json({ ok: true, request_id: req.requestId, data, meta: { returned: data.length, exported_at_utc: manifest.exported_at_utc ?? null } });
});

app.get("/api/export/:dataset", (req, res) => {
  const started = Date.now();
  const log = (status, extra = {}) => console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.path, status, ...extra, duration_ms: Date.now() - started }));
  const fail = (status, code, message) => {
    log(status);
    return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  };
  if (Object.keys(req.query).length !== 0) return fail(400, "INVALID_QUERY", "The request contains an unsupported parameter.");
  const name = String(req.params.dataset || "");
  const entry = readManifest()?.datasets?.find((d) => d.dataset === name);   // only datasets listed in the manifest
  if (!/^[a-z0-9-]{1,64}$/.test(name) || !entry) return fail(404, "NOT_FOUND", "That dataset is not in the current export.");
  res.set({ "Cache-Control": "no-store", "X-Export-Sha256": entry.sha256 ?? "", "X-Export-Rows": String(entry.rows ?? "") });
  res.type("application/json");
  return res.sendFile(path.join(exportDir, `${name}.json`), (error) => {
    if (error) {
      if (!res.headersSent) return fail(500, "INTERNAL_ERROR", "The export file could not be read.");
      return log(500);
    }
    log(200, { rows: entry.rows });
  });
});

app.listen(port, "0.0.0.0", () => {
  console.log(`AIR middleware listening on port ${port}`);
});

