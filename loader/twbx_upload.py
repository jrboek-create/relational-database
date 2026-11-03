"""Tableau .twbx upload for the AIR Course Development Master Hub.

    python twbx_upload.py preview   # stage the newest .twbx, compare, write a report; changes no live tables
    python twbx_upload.py check     # run the whole apply, then roll it back (nothing is saved)
    python twbx_upload.py apply     # add the new rows from the last preview and rebuild the reporting tables
    python twbx_upload.py refresh   # only rebuild the reporting tables from the data already loaded

Rules (agreed 2 Nov 2026, see the "AIR Hub data input map" doc): rows are matched by key; new keys are
added, unchanged keys skipped, changed keys listed (never applied), keys missing from the file are kept.
Cell values are read as calculated values, not formulas.
"""
import hashlib, json, os, sys, uuid, zipfile, tempfile
from datetime import datetime, date, time
from pathlib import Path

import psycopg
from openpyxl import load_workbook

IMPORT_DIR = Path(os.getenv("UPLOAD_DIR", "/imports_hold"))
REPORT_DIR = Path(os.getenv("REPORT_DIR", "/upload_reports"))
REFRESH_DIR = Path(os.getenv("REFRESH_DIR", "/sql_refresh"))
ROW_LIMIT = int(os.getenv("UPLOAD_ROW_LIMIT", "0"))  # testing only; 0 = all rows

ONLINE_OLD = ["raw_master_online_part_s01_online_31fb6e24", "raw_master_online_part_s01_online_3417e822",
              "raw_master_online_part_s01_online_324dd997", "raw_master_online_part_s01_online_6164ddea"]
# existing: ("grades",) = core.grade · ("course_list",) = phase2 Master Course rows · ("raw", tables) = staging tables
# key "*" = match on the whole row (used where the ID column is mostly blank)
DATASETS = [
    dict(name="grades", file="SSBI_Worldwide Canvas Final Course Grades.xlsx", sheet="Final Grades",
         key=["Month of Start", "Course_Section", "Userid"], existing=("grades",), private=["Userid"]),
    dict(name="course_list", file="Master_CourseList.xlsx", sheet="Master Course", key=["Term", "Course Code", "Section"],
         existing=("course_list",), compared=["Enrollment Count", "Course Title", "College", "Department", "Modality"]),
    dict(name="student_survey_old", file="Master_Online.xlsx", sheet="Online", key=["ResponseUniqueId"], existing=("raw", ONLINE_OLD)),
    dict(name="student_survey_new_spots", file="MASTER_Online_NEW.xlsx", sheet="SPOTS", key=["ResponseUniqueId"],
         existing=("raw", ["raw_master_online_new_s02_spots_3caa2498"])),
    dict(name="student_survey_new_rawdata", file="MASTER_Online_NEW.xlsx", sheet="RawData", key=["ResponseUniqueId"],
         existing=("raw", ["raw_master_online_new_s01_rawdata_3caa2498"])),
    dict(name="faculty_survey_old", file="Master_FacultyCourseFeedback.xlsx", sheet="FEOTS", key="*", skip_blank=["UniqueID"],
         existing=("raw", ["raw_master_facultycour_s01_feots_e4a0bf70"])),
    dict(name="faculty_survey_new", file="New_Master_FacultyCourseFeedback.xlsx", sheet="FEOTS (New)", key=["ResponseUniqueId"],
         existing=("raw", ["raw_new_master_faculty_s02_feots_new_18832c28"])),
    dict(name="idd", file="Master IDD Production Schedule.xlsx", sheet="IDD Prod Schd", key=["Course", "Term", "Type"],
         existing=("raw", ["raw_master_idd_product_s02_idd_prod_schd_40a4d388"])),
    dict(name="observations", file="Faculty Obs Master.xlsx", sheet="Faculty Obs Master", key=["Observation Id"],
         existing=("raw", ["raw_faculty_obs_master_s02_faculty_obs_master_49ca0349"])),
    dict(name="integrations", file="MASTER Integrations.xlsx", sheet="Integrations", key=["Course_Code"],
         existing=("raw", ["raw_master_integration_s01_integrations_1c657953"])),
    dict(name="redeveloped", file="Redeveloped Courses MASTER.xlsx", sheet="ReDev", key=["Id"],
         existing=("raw", ["raw_redeveloped_course_s01_redev_466db3fd"])),
    dict(name="ai_production", file="Master AI Production Schedule.xlsx", sheet="AI Prod Schd", key=["Course", "Month", "Type"],
         existing=("raw", ["raw_master_ai_producti_s02_ai_prod_schd_142fe4ef"])),
    dict(name="ai_course_list", file="Master AI Production Schedule.xlsx", sheet="AI Course List & Start Months",
         key=["Sis Source Id (Course Sections)"], existing=("raw", ["raw_master_ai_producti_s05_ai_course_list_sta_142fe4ef"])),
]

SETUP_SQL = [
    "CREATE SCHEMA IF NOT EXISTS upload",
    """CREATE TABLE IF NOT EXISTS upload.run (run_id uuid PRIMARY KEY, twbx_name text NOT NULL, twbx_sha256 text NOT NULL,
       started_at timestamptz NOT NULL DEFAULT now(), status text NOT NULL, applied_at timestamptz)""",
    """CREATE TABLE IF NOT EXISTS upload.workbook (run_id uuid NOT NULL, dataset text NOT NULL, inner_file text NOT NULL,
       sheet text NOT NULL, file_sha256 text NOT NULL, headers jsonb NOT NULL, PRIMARY KEY (run_id, dataset))""",
    "CREATE TABLE IF NOT EXISTS upload.row (run_id uuid NOT NULL, dataset text NOT NULL, row_number integer NOT NULL, vals jsonb NOT NULL)",
    """CREATE TABLE IF NOT EXISTS upload.summary (run_id uuid NOT NULL, dataset text NOT NULL, file_rows bigint, file_keys bigint,
       existing_keys bigint, new_keys bigint, new_rows bigint, unchanged_keys bigint, changed_keys bigint,
       missing_from_file_keys bigint, repeated_keys_in_file bigint, headers_added jsonb, headers_missing jsonb,
       PRIMARY KEY (run_id, dataset))""",
    "CREATE TABLE IF NOT EXISTS upload.change (run_id uuid NOT NULL, dataset text NOT NULL, key_label text NOT NULL, detail text NOT NULL)",
    "CREATE TABLE IF NOT EXISTS upload.new_row (run_id uuid NOT NULL, dataset text NOT NULL, row_number integer NOT NULL)",
    "ALTER TABLE upload.summary ADD COLUMN IF NOT EXISTS new_rows_skipped bigint",
    "ALTER TABLE upload.run ADD COLUMN IF NOT EXISTS import_batch_id uuid",
    # '5', '5.0', ' 5 ' compare equal; numbers compare to 6 decimals; ISO date-times with T or space compare equal;
    # surrounding spaces/line breaks are ignored and Windows/Unix line breaks compare equal; blank = NULL
    r"""CREATE OR REPLACE FUNCTION upload.norm(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
        SELECT CASE
          WHEN NULLIF(x, '') IS NULL THEN NULL
          WHEN x ~ '^-?[0-9]+(\.[0-9]+)?$' THEN trim_scale(round(x::numeric, 6))::text
          WHEN x ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN replace(x, 'T', ' ')
          ELSE x END
        FROM (SELECT btrim(replace(t, E'\r\n', E'\n'), E' \t\r\n') AS x) s $$""",
]


EXCEL_EPOCH = datetime(1899, 12, 30)
EXCEL_ERRORS = {"#NULL!": 2000, "#DIV/0!": 2007, "#VALUE!": 2015, "#REF!": 2023, "#NAME?": 2029, "#NUM!": 2036, "#N/A": 2042}


def text(v, excel_style=False):
    """Cell value as text. excel_style matches how the staging tables were first loaded (through Excel itself):
    dates as Excel serial numbers and errors as Excel error numbers."""
    if v is None:
        return None
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if excel_style and isinstance(v, (datetime, date, time)):
        if isinstance(v, time):
            v = (v.hour * 3600 + v.minute * 60 + v.second) / 86400
        else:
            d = (v if isinstance(v, datetime) else datetime.combine(v, time())) - EXCEL_EPOCH
            v = d.days + d.seconds / 86400
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else f"{v:.15g}"  # Excel keeps 15 significant digits
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(v, (date, time)):
        return v.isoformat()
    s = str(v)
    if excel_style and s in EXCEL_ERRORS:
        return str(-2146828288 + EXCEL_ERRORS[s])
    return s if s.strip() else None


def lit(s):
    return "'" + s.replace("'", "''") + "'"


def newest_twbx():
    files = sorted(IMPORT_DIR.glob("*.twbx"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        raise SystemExit(f"No .twbx file found in {IMPORT_DIR}")
    return files[0]


def sheet_rows(path, sheet, excel_style=False):
    """Returns (headers, iterator of (excel_row_number, {header: text})). Skips blank rows and repeated header rows."""
    wb = load_workbook(path, read_only=True, data_only=True)
    rows = wb[sheet].iter_rows(values_only=True)
    headers, seen = [], set()
    for n, h in enumerate(next(rows, ()), 1):
        name = (text(h) or "").strip() or f"column_{n}"
        name = f"{name}_{n}" if name in seen else name
        seen.add(name)
        headers.append(name)
    named = [h for h in headers if not h.startswith("column_")]

    def gen():
        count = 0
        for rownum, row in enumerate(rows, 2):
            vals = {h: text(v, excel_style) for h, v in zip(headers, row) if not h.startswith("column_")}
            if not any(v is not None for v in vals.values()):
                continue
            if named and all((vals.get(h) or "").strip() == h for h in named[:3]):
                continue
            yield rownum, vals
            count += 1
            if ROW_LIMIT and count >= ROW_LIMIT:
                break
        wb.close()
    return named, gen()


def keyexpr(cols, col):
    return " || ' | ' || ".join(f"coalesce(upload.norm({col(c)}), '')" for c in cols)


def hashexpr(cols, col):
    return "md5(concat_ws(' | ', " + ", ".join(f"coalesce(upload.norm({col(c)}), '')" for c in cols) + "))"


def compare(cur, run_id, ds, headers):
    name, key, kind = ds["name"], ds["key"], ds["existing"][0]
    p = {"run": run_id, "ds": name}
    up = lambda c: f"u.vals ->> {lit(c)}"
    added, missing = [], []
    if kind == "grades":
        src = {"Month of Start": "start_period_text", "Course_Section": "course_section_text", "Userid": "learner_source_identifier",
               "Official Grade": "official_grade_code", "Final Score": "final_score::text"}
        compared = ["Official Grade", "Final Score"]
        ex = lambda c: f"e.{src[c]}"
        exist_from = "core.grade e"
        exist_payload = "jsonb_build_object('Official Grade', e.official_grade_code, 'Final Score', e.final_score::text)"
        exj = lambda c: f"er.j ->> {lit(c)}"
    elif kind == "course_list":
        compared = ds["compared"]
        ex = lambda c: f"(e.raw_json -> 'values' ->> {lit(c)})"
        exist_from = ("phase2_staging.staging_row e JOIN phase2_staging.source_sheet s "
                      "ON s.id = e.source_sheet_id AND s.sheet_name = 'Master Course'")
        exist_payload = "e.raw_json -> 'values'"
        exj = lambda c: f"er.j ->> {lit(c)}"
    else:
        tables, maps = ds["existing"][1], {}
        for t in tables:  # each staging table has its own column map
            cur.execute("""SELECT m.source_header, m.staged_column FROM staging._phase2_column_map m
                           JOIN staging._phase2_components c USING (component_id) WHERE c.staging_table = %s
                           ORDER BY m.column_ordinal""", (t,))
            maps[t] = {h.strip(): c for h, c in cur.fetchall() if h}
            if not maps[t]:
                raise SystemExit(f"{name}: no column map for staging.{t}")
        cmap = maps[tables[0]]
        added = [h for h in headers if h not in cmap]
        missing = [h for h in cmap if h not in headers]
        compared = [h for h in headers if h in cmap]
        if key == "*":
            key = compared
        if [k for k in key if k not in cmap or k not in headers]:
            raise SystemExit(f"{name}: key column(s) {key} missing from the file or the existing data")
        alias = {h: f"h{i:04d}" for i, h in enumerate(compared)}
        parts = [f"SELECT {', '.join((('e.' + maps[t][h]) if h in maps[t] else 'NULL') + '::text AS ' + alias[h] for h in compared)} "
                 f"FROM staging.{t} e" for t in tables]
        header_row = " AND ".join(f"coalesce(e.{alias[k]}, '') = {lit(k)}" for k in key)  # header rows stored as data
        exist_from = f"({' UNION ALL '.join(parts)}) e WHERE NOT ({header_row})"
        ex = lambda c: f"e.{alias[c]}"
        exist_payload = "to_jsonb(e)"
        exj = lambda c: f"er.j ->> {lit(alias[c])}"

    cur.execute(f"""CREATE TEMP TABLE cmp_file_rows ON COMMIT DROP AS
        SELECT {keyexpr(key, up)} AS k, {hashexpr(compared, up)} AS h, u.row_number, u.vals AS j
        FROM upload.row u WHERE u.run_id = %(run)s AND u.dataset = %(ds)s""", p)
    cur.execute(f"""CREATE TEMP TABLE cmp_exist_rows ON COMMIT DROP AS
        SELECT {keyexpr(key, ex)} AS k, {hashexpr(compared, ex)} AS h, {exist_payload} AS j FROM {exist_from}""")
    cur.execute("""CREATE TEMP TABLE cmp_file ON COMMIT DROP AS
        SELECT k, string_agg(h, ',' ORDER BY h) AS h, count(*) AS n FROM cmp_file_rows GROUP BY k""")
    cur.execute("""CREATE TEMP TABLE cmp_exist ON COMMIT DROP AS
        SELECT k, string_agg(h, ',' ORDER BY h) AS h, count(*) AS n FROM cmp_exist_rows GROUP BY k""")
    # hash indexes: whole-row keys can be longer than a regular index allows
    cur.execute("CREATE INDEX ON cmp_file_rows USING hash (k); CREATE INDEX ON cmp_exist_rows USING hash (k)")
    cur.execute("ANALYZE cmp_file_rows; ANALYZE cmp_exist_rows; ANALYZE cmp_file; ANALYZE cmp_exist")
    cur.execute("""INSERT INTO upload.summary
        SELECT %(run)s, %(ds)s, (SELECT sum(n) FROM cmp_file), (SELECT count(*) FROM cmp_file), (SELECT count(*) FROM cmp_exist),
               count(*) FILTER (WHERE x.k IS NULL), coalesce(sum(f.n) FILTER (WHERE x.k IS NULL), 0),
               count(*) FILTER (WHERE x.h = f.h), count(*) FILTER (WHERE x.k IS NOT NULL AND x.h <> f.h),
               (SELECT count(*) FROM cmp_exist e WHERE NOT EXISTS (SELECT 1 FROM cmp_file c WHERE c.k = e.k)),
               (SELECT count(*) FROM cmp_file WHERE n > 1), %(added)s::jsonb, %(missing)s::jsonb
        FROM cmp_file f LEFT JOIN cmp_exist x ON x.k = f.k""",
                {**p, "added": json.dumps(added), "missing": json.dumps(missing)})
    skip = " OR ".join(f"upload.norm(fr.j ->> {lit(c)}) IS NULL" for c in ds.get("skip_blank", [])) or "false"
    cur.execute(f"""INSERT INTO upload.new_row SELECT %(run)s, %(ds)s, fr.row_number FROM cmp_file_rows fr
        WHERE NOT EXISTS (SELECT 1 FROM cmp_exist x WHERE x.k = fr.k) AND NOT ({skip})""", p)
    cur.execute("""UPDATE upload.summary SET new_rows_skipped = new_rows - (SELECT count(*) FROM upload.new_row WHERE run_id = %(run)s AND dataset = %(ds)s)
        WHERE run_id = %(run)s AND dataset = %(ds)s""", p)
    public = [k for k in key if k not in ds.get("private", [])][:3]
    label = keyexpr(public, lambda c: f"fr.j ->> {lit(c)}")
    if kind == "grades":
        cur.execute(f"""INSERT INTO upload.change
            SELECT %(run)s, %(ds)s, {label}, 'grade ' || o.g || ' -> ' || n.g
            FROM cmp_file f JOIN cmp_exist x ON x.k = f.k AND x.h <> f.h
            JOIN LATERAL (SELECT fr.j FROM cmp_file_rows fr WHERE fr.k = f.k ORDER BY fr.row_number LIMIT 1) fr ON true
            JOIN LATERAL (SELECT string_agg(coalesce(r.j ->> 'Official Grade', '(blank)') || ' (' || coalesce(upload.norm(r.j ->> 'Final Score'), 'no score') || ')', ', ' ORDER BY r.h) AS g
                          FROM cmp_file_rows r WHERE r.k = f.k) n ON true
            JOIN LATERAL (SELECT string_agg(coalesce(r.j ->> 'Official Grade', '(blank)') || ' (' || coalesce(upload.norm(r.j ->> 'Final Score'), 'no score') || ')', ', ' ORDER BY r.h) AS g
                          FROM cmp_exist_rows r WHERE r.k = f.k) o ON true""", p)
    else:
        diff = " || ".join(f"CASE WHEN upload.norm(fr.j ->> {lit(c)}) IS DISTINCT FROM upload.norm({exj(c)}) THEN {lit(c + ', ')} ELSE '' END"
                           for c in compared)
        cur.execute(f"""INSERT INTO upload.change
            SELECT %(run)s, %(ds)s, {label},
                   CASE WHEN f.n <> x.n THEN 'rows for this key: ' || x.n || ' -> ' || f.n
                        ELSE 'changed: ' || coalesce(nullif(rtrim({diff}, ', '), ''), '(row order)') END
            FROM cmp_file f JOIN cmp_exist x ON x.k = f.k AND x.h <> f.h
            JOIN LATERAL (SELECT fr.j FROM cmp_file_rows fr WHERE fr.k = f.k ORDER BY fr.row_number LIMIT 1) fr ON true
            JOIN LATERAL (SELECT er.j FROM cmp_exist_rows er WHERE er.k = f.k LIMIT 1) er ON true""", p)
    cur.execute("DROP TABLE cmp_file_rows, cmp_exist_rows, cmp_file, cmp_exist")


def write_report(cur, run_id, twbx, digest):
    cur.execute("SELECT * FROM upload.summary WHERE run_id = %s", (run_id,))
    cols = [d.name for d in cur.description]
    order = [d["name"] for d in DATASETS]
    summary = sorted((dict(zip(cols, r)) for r in cur.fetchall()), key=lambda s: order.index(s["dataset"]))
    n = lambda v: f"{v or 0:,}"
    lines = [f"# Upload preview: {twbx.name}", "",
             f"Run `{run_id}` · file SHA-256 `{digest[:16]}` · {datetime.now():%Y-%m-%d %H:%M}", "",
             "Nothing has been added yet. **New** rows are added when the upload is applied. **Changed** rows are listed "
             "only and never applied. Rows missing from the file are kept.", "",
             "| Dataset | Rows in file | New keys (rows) | Unchanged | Changed | Missing from file (kept) | Repeated keys in file |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    lines += [f"| {s['dataset']} | {n(s['file_rows'])} | {n(s['new_keys'])} ({n(s['new_rows'])}) | {n(s['unchanged_keys'])} | "
              f"{n(s['changed_keys'])} | {n(s['missing_from_file_keys'])} | {n(s['repeated_keys_in_file'])} |" for s in summary]
    lines += [f"\n{s['dataset']}: {s['new_rows_skipped']:,} of the new rows will not be added (blank {', '.join(d.get('skip_blank', []))})."
              for s in summary for d in DATASETS if d["name"] == s["dataset"] and s.get("new_rows_skipped")]
    drift = [s for s in summary if s["headers_added"] or s["headers_missing"]]
    lines += ["", "## Column changes", ""]
    lines += ([f"- **{s['dataset']}**: added {s['headers_added']}; missing {s['headers_missing']}" for s in drift]
              + ["", "Added columns are not loaded until they are mapped; missing columns are stored as blank."]
              if drift else ["None: every sheet has the same columns as the existing data."])
    cur.execute("SELECT dataset, key_label, detail FROM upload.change WHERE run_id = %s ORDER BY dataset, key_label", (run_id,))
    changes = cur.fetchall()
    lines += ["", f"## Changed rows: {len(changes):,} (listed only, not applied)", ""]
    cell = lambda v: v.replace("|", "\\|")
    lines += (["| Dataset | Key | What changed |", "| --- | --- | --- |"] + [f"| {d} | {cell(k)} | {cell(t)} |" for d, k, t in changes]
              if changes else ["None."])
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    out = REPORT_DIR / f"upload_preview_{datetime.now():%Y%m%d_%H%M%S}.md"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out, summary, len(changes)


def connect():
    return psycopg.connect(host=os.environ["PGHOST"], port=os.getenv("PGPORT", "5432"), dbname=os.environ["PGDATABASE"],
                           user=os.environ["PGUSER"], password=os.environ["PGPASSWORD"])


def preview():
    twbx = newest_twbx()
    h = hashlib.sha256()
    with open(twbx, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    digest = h.hexdigest()
    run_id = str(uuid.uuid4())
    print("PREVIEW:", twbx.name)
    conn = connect()
    try:
        with conn.cursor() as cur, zipfile.ZipFile(twbx) as zf, tempfile.TemporaryDirectory() as workdir:
            for stmt in SETUP_SQL:
                cur.execute(stmt)
            old = "(SELECT run_id FROM upload.run WHERE status = 'previewed')"
            for t in ("change", "summary", "new_row", "row", "workbook"):
                cur.execute(f"DELETE FROM upload.{t} WHERE run_id IN {old}")
            cur.execute("DELETE FROM upload.run WHERE status = 'previewed'")
            cur.execute("INSERT INTO upload.run (run_id, twbx_name, twbx_sha256, status) VALUES (%s, %s, %s, 'previewing')",
                        (run_id, twbx.name, digest))
            names = zf.namelist()
            for ds in DATASETS:
                inner = next((x for x in names if x == ds["file"] or x.endswith("/" + ds["file"])), None)
                if inner is None:
                    raise SystemExit(f"{ds['name']}: {ds['file']} is not inside {twbx.name}")
                path = zf.extract(inner, workdir)
                headers, rows = sheet_rows(path, ds["sheet"], ds["existing"][0] == "raw")
                count = 0
                with cur.copy("COPY upload.row (run_id, dataset, row_number, vals) FROM STDIN") as cp:
                    for rownum, vals in rows:
                        cp.write_row((run_id, ds["name"], rownum, json.dumps(vals)))
                        count += 1
                with open(path, "rb") as f:
                    file_hash = hashlib.sha256(f.read()).hexdigest()
                os.remove(path)
                cur.execute("INSERT INTO upload.workbook VALUES (%s, %s, %s, %s, %s, %s)",
                            (run_id, ds["name"], inner, ds["sheet"], file_hash, json.dumps(headers)))
                compare(cur, run_id, ds, headers)
                print(f"  {ds['name']}: {count:,} rows staged and compared")
            cur.execute("UPDATE upload.run SET status = 'previewed' WHERE run_id = %s", (run_id,))
            report, summary, n_changes = write_report(cur, run_id, twbx, digest)
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()
    print(f"\nPREVIEW WRITTEN: upload_reports/{report.name} ({n_changes:,} changed rows listed)")
    for s in summary:
        print(f"  {s['dataset']:<28} new {s['new_keys'] or 0:>7,}  unchanged {s['unchanged_keys'] or 0:>8,}  "
              f"changed {s['changed_keys'] or 0:>6,}  missing from file {s['missing_from_file_keys'] or 0:>6,}")


# ---------------------------------------------------------------- apply
# Projections rebuilt after new rows are added: (reporting table, temp table from sql/refresh, API id column, API id formula)
PROJECTIONS = [
    ("course_grade_summary", "tmp_grade_summary", "grade_summary_id", "md5(course_id::text || ':' || term_id::text)::uuid"),
    ("course_enrollment_summary", "tmp_enrollment_summary", "enrollment_summary_id", "md5(course_id::text || ':' || term_id::text)::uuid"),
    ("course_dfwi_summary", "tmp_dfwi_summary", "dfwi_summary_id", "md5(course_id::text || ':' || term_id::text)::uuid"),
    ("course_faculty_survey_summary", "tmp_course_faculty_survey_summary", "faculty_survey_summary_id",
     "md5(course_id::text || ':' || term_id::text)::uuid"),
    ("course_student_survey_summary", "tmp_course_student_survey_summary", "student_survey_summary_id",
     "md5(course_id::text || ':' || term_id::text)::uuid"),
    ("course_student_survey_question_summary", "tmp_course_student_survey_question_summary", "student_survey_question_summary_id",
     "md5(course_id::text || ':' || term_id::text || ':' || survey_version || ':' || question_code)::uuid"),
    ("course_instructional_design_development_summary", "tmp_course_instructional_design_development_summary",
     "instructional_design_development_summary_id", "md5(source_hash || ':' || source_row_number::text)::uuid"),
    ("course_ai_production_summary", "tmp_course_ai_production_summary", "ai_production_summary_id",
     "md5(source_hash || ':' || source_row_number::text)::uuid"),
    ("course_integration_summary", "tmp_course_integration_summary", "integration_summary_id",
     "md5(source_hash || ':' || source_row_number::text || ':' || integration_name)::uuid"),
    ("course_redeveloped_summary", "tmp_course_redeveloped_summary", "redeveloped_summary_id",
     "md5(source_hash || ':' || source_row_number::text)::uuid"),
    ("course_observation_summary", "tmp_course_observation_summary", "observation_summary_id",
     "md5(course_key || ':' || item_number::text)::uuid"),
]
BUILD_FILES = ["build_grade_enrollment_dfwi.sql", "build_faculty_survey.sql", "build_student_survey.sql",
               "build_student_survey_questions.sql", "build_instructional_design_development.sql", "build_ai_production.sql",
               "build_integrations.sql", "build_redeveloped.sql",
               "build_observations.sql"]


def columns(cur, schema, table):
    cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema = %s AND table_name = %s ORDER BY ordinal_position",
                (schema, table))
    return [r[0] for r in cur.fetchall()]


def add_new_rows(cur, run_id, twbx_name, batch_id):
    """Adds the rows the preview marked as new. Returns {dataset: rows added}."""
    cur.execute("SELECT dataset, inner_file, sheet, upper(file_sha256) FROM upload.workbook WHERE run_id = %s", (run_id,))
    wb = {d: (f, sh, h) for d, f, sh, h in cur.fetchall()}
    version = wb["grades"][2][:8]
    p = {"run": run_id, "batch": batch_id, "ver": version}
    new = lambda ds: f"upload.row u JOIN upload.new_row n USING (run_id, dataset, row_number) WHERE u.run_id = %(run)s AND u.dataset = {lit(ds)}"
    added = {}

    # one batch for the whole upload, recorded where the original load recorded its batch
    cur.execute("SELECT source_system_id FROM core.source_system WHERE system_code = 'WW_CANVAS_GRADES'")
    system = cur.fetchone()
    if not system:
        raise SystemExit("core.source_system WW_CANVAS_GRADES not found")
    cur.execute("""INSERT INTO core.import_batch (import_batch_id, source_system_id, batch_identifier, loaded_at, source_fingerprint,
                   authoritative_indicator, batch_status, notes, created_at)
                   VALUES (%(batch)s, %(sys)s, %(name)s, now(), %(fp)s, true, 'LOADED', %(notes)s, now())""",
                {**p, "sys": system[0], "name": f"{twbx_name} - new rows", "fp": wb["grades"][2],
                 "notes": f"TWBX upload of {twbx_name}: new rows only (upload run {run_id})."})
    cur.execute("""INSERT INTO staging._phase2_batches (batch_id, source_root, started_at, completed_at, status, file_count, component_count, failure_count)
                   VALUES (%(batch)s, %(root)s, now(), now(), 'STAGED', %(n)s, %(n)s, 0)""", {**p, "root": f"twbx: {twbx_name}", "n": len(wb)})
    cur.execute("""INSERT INTO phase2_staging.import_batch (id, batch_name, imported_at, status, notes)
                   VALUES (%(batch)s, %(name)s, now(), 'complete', %(notes)s)""",
                {**p, "name": f"twbx_{datetime.now():%Y%m%d_%H%M%S}", "notes": f"New Master Course rows from {twbx_name}"})

    # grades: new terms, then new sections for linked courses, then the grade rows (same rules as the original load)
    cur.execute(f"CREATE TEMP TABLE g_new ON COMMIT DROP AS SELECT n.row_number, u.vals FROM {new('grades')}", p)
    cur.execute("""INSERT INTO core.term (term_id, term_code, term_label, reporting_period_text, import_batch_id, source_identifier,
                   source_record_locator, source_version_label, created_at)
                   SELECT gen_random_uuid(), min(code), label, label, %(batch)s, min(code), 'Final Grades:term:' || min(code), %(ver)s, now()
                   FROM (SELECT btrim(vals ->> 'Term') AS code, vals ->> 'Month of Start' AS label FROM g_new) x
                   WHERE label IS NOT NULL AND code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.term t WHERE t.term_label = x.label)
                   GROUP BY label""", p)
    added["terms"] = cur.rowcount
    cur.execute("""CREATE TEMP TABLE g_link ON COMMIT DROP AS
        SELECT g.row_number, g.vals, t.term_id, t.term_code, c.course_id
        FROM g_new g
        LEFT JOIN (SELECT DISTINCT ON (term_label) term_label, term_id, term_code FROM core.term ORDER BY term_label, term_code) t
               ON t.term_label = g.vals ->> 'Month of Start'
        LEFT JOIN (SELECT DISTINCT ON (replace(course_code, ' ', '')) replace(course_code, ' ', '') AS k, course_id
                   FROM core.course WHERE is_current ORDER BY 1, course_id) c
               ON c.k = split_part(g.vals ->> 'Course_Section', '_', 1)""")
    cur.execute("""INSERT INTO core.course_offering_section (course_offering_id, course_id, term_id, section_identifier, source_section_identifier,
                   enrollment_count, import_batch_id, source_identifier, source_record_locator, source_version_label, is_current, created_at)
        SELECT gen_random_uuid(), x.course_id, x.term_id, split_part(x.cs, '_', 2), x.cs, e.n, %(batch)s, x.cs,
               'Final Grades:offering:' || x.term_code || ':' || split_part(x.cs, '_', 1) || ':' || split_part(x.cs, '_', 2), %(ver)s, true, now()
        FROM (SELECT DISTINCT ON (term_id, vals ->> 'Course_Section') course_id, term_id, term_code, vals ->> 'Course_Section' AS cs
              FROM g_link WHERE course_id IS NOT NULL AND term_id IS NOT NULL ORDER BY term_id, vals ->> 'Course_Section', course_id) x
        LEFT JOIN (SELECT btrim(vals ->> 'Term') AS term_code, btrim(vals ->> 'Course_Section') AS cs,
                          sum(upload.norm(vals ->> 'Enrollment Count')::numeric)::integer AS n
                   FROM upload.row WHERE run_id = %(run)s AND dataset = 'course_list' AND upload.norm(vals ->> 'Enrollment Count') ~ '^[0-9]+$'
                   GROUP BY 1, 2) e ON e.term_code = x.term_code AND e.cs = x.cs
        WHERE NOT EXISTS (SELECT 1 FROM core.course_offering_section o WHERE o.source_section_identifier = x.cs AND o.term_id = x.term_id)""", p)
    added["sections"] = cur.rowcount
    cur.execute("""INSERT INTO core.grade (grade_id, grade_source_identifier, learner_source_identifier, course_id, course_offering_id, term_id,
                   course_section_text, final_score, official_grade_code, start_period_text, import_batch_id, source_identifier,
                   source_record_locator, source_version_label, created_at)
        SELECT gen_random_uuid(), l.vals ->> 'DB_row2', l.vals ->> 'Userid', l.course_id, o.course_offering_id, l.term_id,
               l.vals ->> 'Course_Section',
               CASE WHEN btrim(l.vals ->> 'Final Score') ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN btrim(l.vals ->> 'Final Score')::numeric END,
               l.vals ->> 'Official Grade', l.vals ->> 'Month of Start', %(batch)s, l.vals ->> 'DB_row2',
               'Final Grades:row:' || l.row_number, %(ver)s, now()
        FROM g_link l
        LEFT JOIN (SELECT DISTINCT ON (source_section_identifier, term_id) source_section_identifier, term_id, course_offering_id
                   FROM core.course_offering_section ORDER BY 1, 2, course_offering_id) o
               ON l.course_id IS NOT NULL AND o.source_section_identifier = l.vals ->> 'Course_Section' AND o.term_id = l.term_id""", p)
    added["grades"] = cur.rowcount

    # course list: same row layout as the Excel loader (load_excel.py), on the existing Master Course sheet
    cur.execute("""SELECT r.source_sheet_id FROM phase2_staging.staging_row r JOIN phase2_staging.source_sheet s ON s.id = r.source_sheet_id
                   WHERE s.sheet_name = 'Master Course' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1""")
    sheet = cur.fetchone()
    if not sheet:
        raise SystemExit("phase2_staging: no Master Course sheet found")
    f, sh, _ = wb["course_list"]
    cur.execute(f"""INSERT INTO phase2_staging.staging_row (id, source_sheet_id, import_batch_id, row_number, raw_json, created_at)
        SELECT gen_random_uuid(), %(sheet)s, %(batch)s, n.row_number,
               jsonb_build_object('_meta', jsonb_build_object('workbook', %(wbname)s::text, 'worksheet', %(sh)s::text, 'excel_row_number', n.row_number,
                                                              'historical_sheet', false, 'twbx', %(twbx)s::text),
                                  'values', u.vals), now()
        FROM {new('course_list')}""", {**p, "sheet": sheet[0], "wbname": Path(f).name, "sh": sh, "twbx": twbx_name})
    added["course_list"] = cur.rowcount
    cur.execute("UPDATE phase2_staging.source_sheet SET row_count = coalesce(row_count, 0) + %s WHERE id = %s", (added["course_list"], sheet[0]))

    # survey, schedule and other sheets: appended to the staging table they were first loaded into, same column map
    for ds in DATASETS:
        if ds["existing"][0] != "raw":
            continue
        target = ds["existing"][1][-1]
        cur.execute("""SELECT m.source_header, m.staged_column FROM staging._phase2_column_map m
                       JOIN staging._phase2_components c USING (component_id) WHERE c.staging_table = %s""", (target,))
        cmap = {h.strip(): c for h, c in cur.fetchall() if h}
        cur.execute("SELECT headers FROM upload.workbook WHERE run_id = %s AND dataset = %s", (run_id, ds["name"]))
        cols = [(h, cmap[h]) for h in cur.fetchone()[0] if h in cmap]
        f, sh, digest = wb[ds["name"]]
        cur.execute(f"""INSERT INTO staging.{target} ({', '.join(c for _, c in cols)}, source_filename, source_component, source_hash,
                        import_batch_id, source_row_number, imported_at)
            SELECT {', '.join(f'u.vals ->> {lit(h)}' for h, _ in cols)}, %(file)s, %(sh)s, %(hash)s, %(batch)s, n.row_number, now()
            FROM {new(ds['name'])}""", {**p, "file": ds["file"], "sh": sh, "hash": digest})
        added[ds["name"]] = cur.rowcount
    return added


def refresh_reporting(cur, twbx_name, run_id):
    """Rebuilds the reporting tables and their API copies with the verified sql/refresh builds. Returns {table: (before, after)}."""
    for table, _, id_col, id_expr in PROJECTIONS:  # API ids must follow the formula, or the rebuilt ids would differ
        cur.execute(f"SELECT count(*), count(*) FILTER (WHERE {id_col} = {id_expr}) FROM reporting.{table}_api")
        n, ok = cur.fetchone()
        if n != ok:
            raise SystemExit(f"reporting.{table}_api: {n - ok} of {n} ids do not follow {id_expr}; stopping before any change")
    for _, tmp, _, _ in PROJECTIONS:  # some builds keep their temp table until the connection ends; start clean
        cur.execute(f"DROP TABLE IF EXISTS pg_temp.{tmp}")
    result = {}
    # Each table is replaced right after its build, because later builds read earlier tables
    # (survey questions read the student survey summary; IDD reads the enrollment summary).
    for f in BUILD_FILES:
        cur.execute((REFRESH_DIR / f).read_text(encoding="utf-8-sig"))
        for table, tmp, id_col, id_expr in PROJECTIONS:
            if table in result:
                continue
            cur.execute("SELECT to_regclass(%s) IS NOT NULL", (f"pg_temp.{tmp}",))
            if cur.fetchone()[0]:
                result[table] = replace_table(cur, table, tmp, id_col, id_expr, twbx_name, run_id)
    missing = [t for t, *_ in PROJECTIONS if t not in result]
    if missing:
        raise SystemExit(f"No build produced {missing}")
    return result


def replace_table(cur, table, tmp, id_col, id_expr, twbx_name, run_id):
    """Replaces one reporting table and its API copy from its temp table, and logs it. Returns (rows before, rows after)."""
    cols, api_cols = columns(cur, "reporting", table), columns(cur, "reporting", table + "_api")
    cur.execute(f"SELECT * FROM {tmp} LIMIT 0")
    tmp_cols = [d.name for d in cur.description]
    business = [c for c in cols if c in tmp_cols and c not in ("core_import_batch_id", "report_refresh_run_id", "report_as_of_utc", "business_row_hash")]
    refresh_id = str(uuid.uuid4())
    fill = {"report_refresh_run_id": f"{lit(refresh_id)}::uuid", "report_as_of_utc": "now()",
            "business_row_hash": "md5(concat_ws('|', " + ", ".join(f"{c}::text" for c in business) + "))"}
    missing = [c for c in cols if c not in tmp_cols and c not in fill]
    api_missing = [c for c in api_cols if c != id_col and c not in cols]
    if missing or api_missing:
        raise SystemExit(f"reporting.{table}: no source for columns {missing + api_missing}")
    cur.execute(f"SELECT count(*) FROM reporting.{table}")
    before = cur.fetchone()[0]
    cur.execute(f"DELETE FROM reporting.{table}")
    cur.execute(f"INSERT INTO reporting.{table} ({', '.join(cols)}) SELECT {', '.join(c if c in tmp_cols else fill[c] for c in cols)} FROM {tmp}")
    after = cur.rowcount
    cur.execute(f"DELETE FROM reporting.{table}_api")
    cur.execute(f"INSERT INTO reporting.{table}_api ({', '.join(api_cols)}) "
                f"SELECT {', '.join(id_expr if c == id_col else c for c in api_cols)} FROM reporting.{table}")
    cur.execute(f"SELECT max(report_refresh_run_id::text)::uuid FROM reporting.{table}")
    log_id = cur.fetchone()[0] or refresh_id
    cur.execute("SELECT 1 FROM reporting.projection_refresh_run WHERE run_id = %s", (log_id,))
    if cur.fetchone():
        log_id = str(uuid.uuid4())
    checksum_of = "business_row_hash" if "business_row_hash" in cols else "md5(concat_ws('|', " + ", ".join(f"{c}::text" for c in cols) + "))"
    cur.execute(f"SELECT md5(coalesce(string_agg({checksum_of}, '' ORDER BY {checksum_of}), '')) FROM reporting.{table}")
    checksum = cur.fetchone()[0]
    # the log's rules for COMPLETED: every count, a checksum, and source_state/source_filter objects
    cur.execute("""INSERT INTO reporting.projection_refresh_run (run_id, projection_name, started_at, completed_at, source_filter, source_state,
                   source_row_count, rows_inserted, rows_updated, rows_deleted, rows_unchanged, business_checksum, status, notes)
                   VALUES (%s, %s, now(), clock_timestamp(), %s, %s, %s, %s, 0, %s, 0, %s, 'COMPLETED', %s)""",
                (log_id, table, json.dumps({"upload_run": run_id, "twbx": twbx_name}), json.dumps({"rows_before": before, "rows_after": after}),
                 after, after, before, checksum, f"Rebuilt after TWBX upload of {twbx_name} (sql/refresh builds)."))
    return before, after


def apply(save):
    twbx = newest_twbx()
    h = hashlib.sha256()
    with open(twbx, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    for f in BUILD_FILES:
        if not (REFRESH_DIR / f).exists():
            raise SystemExit(f"Missing {REFRESH_DIR / f}")
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT run_id::text, twbx_name, twbx_sha256 FROM upload.run WHERE status = 'previewed'")
            runs = cur.fetchall()
            if len(runs) != 1:
                raise SystemExit("No previewed upload found. Run the preview first.")
            run_id, name, digest = runs[0]
            if (name, digest) != (twbx.name, h.hexdigest()):
                raise SystemExit(f"{twbx.name} is not the file that was previewed ({name}). Run the preview again.")
            cur.execute("SELECT to_regclass('upload.new_row') IS NOT NULL")
            if not cur.fetchone()[0] or not cur.execute("SELECT 1 FROM upload.new_row WHERE run_id = %s LIMIT 1", (run_id,)).fetchone():
                raise SystemExit("This preview has no new rows recorded (or was made by an older version). Run the preview again.")
            print(("APPLY: " if save else "CHECK (nothing will be saved): ") + twbx.name)
            batch_id = str(uuid.uuid4())
            added = add_new_rows(cur, run_id, twbx.name, batch_id)
            for k, v in added.items():
                print(f"  added {k:<28}{v:>8,}")
            print("  rebuilding reporting tables ...")
            for table, (before, after) in refresh_reporting(cur, twbx.name, run_id).items():
                print(f"  {table:<50}{before:>9,} -> {after:>9,} rows")
            if not save:
                conn.rollback()
                print("\nCHECK PASSED. Nothing was saved. Run 'apply' to add the rows.")
                return
            cur.execute("UPDATE upload.run SET status = 'applied', applied_at = now(), import_batch_id = %s WHERE run_id = %s", (batch_id, run_id))
            cur.execute("DELETE FROM upload.row WHERE run_id = %s", (run_id,))  # staged copy no longer needed
        conn.commit()
        print(f"\nAPPLIED. Import batch {batch_id}.")
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def refresh():
    """Rebuilds the reporting tables and API copies from the data already loaded (no upload)."""
    for f in BUILD_FILES:
        if not (REFRESH_DIR / f).exists():
            raise SystemExit(f"Missing {REFRESH_DIR / f}")
    conn = connect()
    try:
        with conn.cursor() as cur:
            print("REFRESH: rebuilding reporting tables ...")
            for table, (before, after) in refresh_reporting(cur, "(refresh only)", None).items():
                print(f"  {table:<50}{before:>9,} -> {after:>9,} rows")
        conn.commit()
        print("\nREFRESHED.")
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "preview"
    if cmd == "preview":
        preview()
    elif cmd in ("check", "apply"):
        apply(save=cmd == "apply")
    elif cmd == "refresh":
        refresh()
    else:
        raise SystemExit(f"Unknown command {cmd!r}. Use: preview, check, apply or refresh")

