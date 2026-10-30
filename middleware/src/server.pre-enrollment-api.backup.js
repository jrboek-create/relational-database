import express from "express";
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
const approvedFields = ["course_id","university_course_id","course_code","course_title","college_name","department_name","source_system_code","report_refresh_run_id","report_as_of_utc"];
const detailFields = ["course_id","university_course_id","course_code","course_title","college_name","department_name","course_description","course_goals","course_learning_outcomes"];
const allowedParams = new Set(["page","limit","course_code","course_title","college_name","department_name","sort"]);
const allowedSorts = new Set(["course_code","-course_code"]);

app.disable("x-powered-by");
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


const gradeFields = [
  "grade_summary_id",
  "course_id",
  "term_id",
  "term_code",
  "term_label",
  "university_course_id",
  "course_code",
  "course_title",
  "college_name",
  "department_name",
  "grade_count",
  "scored_count",
  "average_final_score",
  "grade_a_count",
  "grade_au_count",
  "grade_b_count",
  "grade_c_count",
  "grade_d_count",
  "grade_f_count",
  "grade_fx_count",
  "grade_i_count",
  "grade_ip_count",
  "grade_n_count",
  "grade_nc_count",
  "grade_ns_count",
  "grade_ntg_count",
  "grade_p_count",
  "grade_s_count",
  "grade_w_count",
  "grade_wf_count",
  "other_grade_count",
  "report_refresh_run_id",
  "report_as_of_utc"
];

app.get("/api/courses/:course_id/grades", async (req, res) => {
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
      return fail(
        400,
        "INVALID_QUERY",
        "The request contains an unsupported parameter."
      );
    }

    const rawCourseId = req.params.course_id;
    const courseId =
      typeof rawCourseId === "string" ? rawCourseId.trim() : "";

    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (!uuidPattern.test(courseId)) {
      return fail(
        400,
        "INVALID_QUERY",
        "course_id must be a valid UUID."
      );
    }

    const params = new URLSearchParams();
    params.set("fields", gradeFields.join(","));
    params.set("filter[course_id][_eq]", courseId);
    params.set("sort", "-term_code");
    params.set("limit", "100");

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);

    let upstream;

    try {
      upstream = await fetch(
        `${directusUrl}/items/course_grade_summary_api?${params.toString()}`,
        {
          headers: {
            Authorization: `Bearer ${directusToken}`,
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
        "The Grades data service is unavailable."
      );
    }

    const payload = await upstream.json();

    if (!Array.isArray(payload.data)) {
      return fail(
        500,
        "INTERNAL_ERROR",
        "The request could not be completed."
      );
    }

    const data = payload.data.map((row) =>
      Object.fromEntries(
        gradeFields.map((field) => [field, row[field] ?? null])
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
        sort: "-term_code",
        report_refresh_run_id:
          data[0]?.report_refresh_run_id ?? null,
        report_as_of_utc:
          data[0]?.report_as_of_utc ?? null
      }
    });
  } catch (error) {
    const timedOut = error?.name === "AbortError";

    return fail(
      timedOut ? 504 : 500,
      timedOut ? "DIRECTUS_UNAVAILABLE" : "INTERNAL_ERROR",
      timedOut
        ? "The Grades data service timed out."
        : "The request could not be completed."
    );
  }
});

app.listen(port, "0.0.0.0", () => {
  console.log(`AIR middleware listening on port ${port}`);
});

