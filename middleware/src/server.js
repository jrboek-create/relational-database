import express from "express";
import compression from "compression";
import { readFileSync, statSync } from "node:fs";
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
const apiKeysFile = path.resolve(process.env.API_KEYS_FILE || path.resolve(__dirname, "../../.secrets/api_keys.json"));
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

// /api/v1/... is the versioned path for tools; it serves the same routes as /api/... (numbers converted, see toNumbers).
app.use((req, res, next) => {
  if (req.url === "/api/v1" || req.url.startsWith("/api/v1/") || req.url.startsWith("/api/v1?")) {
    req.apiVersion = 1;
    req.url = "/api" + req.url.slice("/api/v1".length);
  }
  next();
});

// API keys: every /api call needs X-API-Key (the web app's key is added by nginx). Keys are kept as SHA-256
// fingerprints in .secrets/api_keys.json (managed with src/keys.js) and re-read when the file changes.
let apiKeys = { mtimeMs: -1, byHash: null };
function loadApiKeys() {
  try {
    const { mtimeMs } = statSync(apiKeysFile);
    if (mtimeMs !== apiKeys.mtimeMs) {
      const doc = JSON.parse(readFileSync(apiKeysFile, "utf8"));
      apiKeys = { mtimeMs, byHash: new Map((doc.keys || []).map((k) => [k.sha256, k.name])) };
    }
    return apiKeys.byHash;
  } catch {
    apiKeys = { mtimeMs: -1, byHash: null };
    return null;
  }
}

app.use("/api", (req, res, next) => {
  const deny = (status, code, message) => {
    console.log(JSON.stringify({ event: "request", request_id: req.requestId, method: req.method, path: req.originalUrl.split("?")[0], status, duration_ms: 0 }));
    return res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  };
  const keys = loadApiKeys();
  if (!keys) return deny(503, "API_KEYS_NOT_CONFIGURED", "API keys are not set up on this server.");
  const provided = req.get("x-api-key");
  const client = provided ? keys.get(crypto.createHash("sha256").update(provided).digest("hex")) : undefined;
  if (!client) return deny(401, "UNAUTHORIZED", "A valid X-API-Key header is required.");
  req.apiClient = client;
  console.log(JSON.stringify({ event: "api_client", request_id: req.requestId, client, version: req.apiVersion || 0, path: req.originalUrl.split("?")[0] }));
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
    meta: { formula: "(D + F + W + I) / grades * 100", grades: "A, B, C, D, F, W, I, AU, NS, NTG, P, WF (as in Tableau)" },
    fields: ["dfwi_summary_id", "course_id", "term_id", "term_code", "term_label", "university_course_id", "course_code", "course_title", "college_name", "department_name", "enrollment_count", "grade_count", "d_count", "f_count", "w_count", "i_count", "dfwi_count", "dfwi_rate_pct", "report_refresh_run_id", "report_as_of_utc"]
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

      let data = payload.data.map((row) => Object.fromEntries(section.fields.map((field) => [field, row[field] ?? null])));
      if (req.apiVersion === 1) data = toNumbers(data, await numericFields(section.collection));
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

// Directus sends big whole numbers and decimals as text ("67"). In /api/v1 those fields become JSON numbers.
// Which fields are numeric comes from Directus's own field types, so text IDs such as term_code "2983" stay text.
const numericFieldCache = new Map();
async function numericFields(collection) {
  if (numericFieldCache.has(collection)) return numericFieldCache.get(collection);
  try {
    const upstream = await fetch(`${directusUrl}/fields/${collection}`, { headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json" } });
    if (!upstream.ok) return new Set();
    const payload = await upstream.json();
    const set = new Set((payload.data || []).filter((f) => ["integer", "bigInteger", "float", "decimal"].includes(f.type)).map((f) => f.field));
    numericFieldCache.set(collection, set);
    return set;
  } catch {
    return new Set();
  }
}
function toNumbers(rows, numeric) {
  if (numeric.size === 0) return rows;
  return rows.map((row) => {
    const out = { ...row };
    for (const field of numeric) {
      const value = out[field];
      if (typeof value === "string" && value.trim() !== "" && Number.isFinite(Number(value))) out[field] = Number(value);
    }
    return out;
  });
}

// OpenAPI description of /api/v1, generated from the same configuration the endpoints use.
function openApiSpec() {
  const ok = (description, dataSchema) => ({ description, content: { "application/json": { schema: { type: "object", properties: { ok: { type: "boolean" }, request_id: { type: "string" }, data: dataSchema, meta: { type: "object" } } } } } });
  const err = { description: "Error", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } };
  const errors = { 400: err, 401: err, 404: err, 502: err, 503: err, 504: err };
  const rowsOf = (fields) => ({ type: "array", items: { type: "object", properties: Object.fromEntries(fields.map((f) => [f, {}])) } });
  const courseId = { name: "course_id", in: "path", required: true, schema: { type: "string", format: "uuid" } };
  const paths = {
    "/courses": { get: { summary: "Course catalog list", parameters: ["page", "limit", "course_code", "course_title", "college_name", "department_name", "sort"].map((name) => ({ name, in: "query", required: false, schema: { type: "string" } })), responses: { 200: ok("Courses", rowsOf(approvedFields)), ...errors } } },
    "/courses/{course_id}": { get: { summary: "Course detail", parameters: [courseId], responses: { 200: ok("Course", { type: "object", properties: Object.fromEntries(detailFields.map((f) => [f, {}])) }), ...errors } } },
    "/courses/{course_id}/all": { get: { summary: "Course detail plus every section in one call", description: "data.course, data.sections.<section> (null if that section was unavailable); meta.sections and meta.unavailable report each section's status.", parameters: [courseId], responses: { 200: ok("Course and sections", { type: "object" }), ...errors } } },
    "/filter-options": { get: { summary: "College and department pairs for filters", responses: { 200: ok("Pairs", rowsOf(["college_name", "department_name"])), ...errors } } },
    "/data-status": { get: { summary: "Row count and last rebuild time per data area", responses: { 200: ok("Status", rowsOf(["section", "collection", "available", "rows", "last_refreshed_utc"])), ...errors } } },
    "/export": { get: { summary: "List of exported datasets (manifest)", responses: { 200: ok("Datasets", rowsOf(["dataset", "file", "rows", "sha256", "report_as_of_utc", "url"])), ...errors } } },
    "/export/{dataset}": { get: { summary: "One whole exported dataset", description: 'Returns the export file as written: {"meta": {...}, "data": [...]}. Headers X-Export-Sha256 and X-Export-Rows.', parameters: [{ name: "dataset", in: "path", required: true, schema: { type: "string" } }], responses: { 200: { description: "Dataset file", content: { "application/json": { schema: { type: "object" } } } }, ...errors } } }
  };
  for (const section of courseSections) {
    paths[`/courses/{course_id}/${section.path}`] = { get: { summary: section.label, parameters: [courseId], responses: { 200: ok(section.label, rowsOf(section.fields)), ...errors } } };
  }
  return {
    openapi: "3.0.3",
    info: { title: "AIR Course Development Master Hub API", version: "1", description: "Read-only course data. Every call needs an X-API-Key header. Numeric fields are JSON numbers in /api/v1. Responses are gzip-compressed when requested." },
    servers: [{ url: "/api/v1" }],
    components: {
      securitySchemes: { ApiKey: { type: "apiKey", in: "header", name: "X-API-Key" } },
      schemas: { Error: { type: "object", properties: { ok: { type: "boolean" }, request_id: { type: "string" }, error: { type: "object", properties: { code: { type: "string" }, message: { type: "string" } } } } } }
    },
    security: [{ ApiKey: [] }],
    paths
  };
}

app.get("/api/openapi.json", (req, res) => res.status(200).json(openApiSpec()));

// One Directus read: { ok, data } or { ok: false, timedOut }.
async function directusItems(collection, params, requestId) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const upstream = await fetch(`${directusUrl}/items/${collection}?${params.toString()}`, {
      headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json", "x-request-id": requestId },
      signal: controller.signal
    });
    if (!upstream.ok) return { ok: false, timedOut: false };
    const payload = await upstream.json();
    return Array.isArray(payload.data) ? { ok: true, data: payload.data } : { ok: false, timedOut: false };
  } catch (error) {
    return { ok: false, timedOut: error?.name === "AbortError" };
  } finally {
    clearTimeout(timeout);
  }
}

// Everything about one course in one call: the course detail plus every section, fetched in parallel.
// Each section uses the same fields, filter, sort and limit as its own endpoint. A section whose data service
// fails comes back as null with available: false in meta; the rest are still returned.
app.get("/api/courses/:course_id/all", async (req, res) => {
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

    const detailParams = new URLSearchParams();
    detailParams.set("fields", detailFields.join(","));
    detailParams.set("filter[course_id][_eq]", courseId);
    detailParams.set("limit", "1");

    const [detail, ...results] = await Promise.all([
      directusItems("course_catalog_detail_api", detailParams, req.requestId),
      ...courseSections.map((section) => {
        const params = new URLSearchParams();
        params.set("fields", section.fields.join(","));
        params.set("filter[course_id][_eq]", courseId);
        params.set("sort", section.sort);
        params.set("limit", String(section.limit));
        return directusItems(section.collection, params, req.requestId);
      })
    ]);

    if (!detail.ok) return fail(detail.timedOut ? 504 : 502, "DIRECTUS_UNAVAILABLE", "The course data service is unavailable.");
    if (detail.data.length === 0) return fail(404, "NOT_FOUND", "The requested course was not found.");

    const course = Object.fromEntries(detailFields.map((field) => [field, detail.data[0][field] ?? null]));
    const numeric = req.apiVersion === 1 ? await Promise.all(courseSections.map((section) => numericFields(section.collection))) : null;
    const sections = {};
    const sectionMeta = {};
    courseSections.forEach((section, i) => {
      const key = section.path.replaceAll("/", "-");
      const result = results[i];
      let rows = result.ok ? result.data.map((row) => Object.fromEntries(section.fields.map((field) => [field, row[field] ?? null]))) : null;
      if (rows && numeric) rows = toNumbers(rows, numeric[i]);
      sections[key] = rows;
      sectionMeta[key] = {
        label: section.label,
        available: result.ok,
        returned: rows ? rows.length : null,
        report_as_of_utc: rows?.[0]?.report_as_of_utc ?? null
      };
    });
    const unavailable = Object.keys(sectionMeta).filter((key) => !sectionMeta[key].available);
    log(200, { sections: Object.keys(sections).length, unavailable: unavailable.length });
    return res.status(200).json({ ok: true, request_id: req.requestId, data: { course, sections }, meta: { course_id: courseId, sections: sectionMeta, unavailable } });
  } catch {
    return fail(500, "INTERNAL_ERROR", "The request could not be completed.");
  }
});

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

