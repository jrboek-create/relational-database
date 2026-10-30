
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
