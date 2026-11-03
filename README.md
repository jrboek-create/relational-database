# AIR Course Development Master Hub

A local web app for browsing the ERAU Worldwide course catalog and viewing each course's performance, feedback, and instructional design data in one place.

It runs as a set of Docker containers: a PostgreSQL database, Directus as the data API, a small Node.js middleware, and a static web UI.

## How it fits together

```
Browser ──> ui (nginx, :8080) ──/api/──> middleware (Node, :3001) ──> directus (:DIRECTUS_PORT) ──> database (PostgreSQL)
                                                                                                └─> cache (Redis)
```

- **ui** serves the web page and passes `/api/` requests to the middleware.
- **middleware** is the only thing that talks to Directus. It authenticates with the static token in `.secrets/`, allows only approved fields and filters, and returns clean JSON.
- **directus** exposes the `reporting` schema in PostgreSQL. It connects as the limited `directus_runtime` database role.
- **database** and **cache** sit on an internal network and are not reachable from outside Docker.

All published ports are bound to `127.0.0.1`, so the app is only reachable from this computer.

## What the app shows

Search the current course catalog by code, title, college, or department. Open a course to see:

- Course identity, college, and department
- Curriculum (description, goals, learning outcomes)
- Course performance: grades, enrollment, and DFWI
- Faculty survey and student survey results, including question-level student survey results
- Instructional design and development history
- AI in this course (AI production projects), integrations (month last done or started per integration type), redeveloped-course feedback from instructors (without names or emails), and faculty observation totals (ratings shown only for courses with at least 3 observations)

A **Data status** box under the filters shows each data area's row count and when it was last rebuilt.

## Project layout

| Path | Purpose |
|---|---|
| `compose.yaml` | Defines and runs all services |
| `compose.loader.yaml` | Optional Excel import job (see below) |
| `compose.upload.yaml` | Tableau `.twbx` upload: `preview`, `check`, `apply`, `refresh` (see below) |
| `ui/` | Web UI: `index.html`, `app.js`, `styles.css`, plus the nginx config and Dockerfile |
| `middleware/` | Node.js/Express API (`src/server.js`) |
| `loader/` | `load_excel.py` (Excel import) and `twbx_upload.py` (Tableau upload and reporting rebuild) |
| `sql/refresh/` | Build SQL for every reporting table, used by `apply` and `refresh`; `verify/` checks them against live data |
| `sql/schema/` | One-time setup for newer reporting tables and their Directus registration |

These local folders are **not in git** (see `.gitignore`):

| Path | Contents |
|---|---|
| `.env` | Database name/user/password, Directus version, port, URL, and secret |
| `.secrets/` | `directus_runtime_db_password.txt` and `wwairml_directus_static_token.txt` |
| `data/` | PostgreSQL data files (the actual database) |
| `backups/` | Database dumps |
| `upload_reports/` | Upload preview reports (they list grade changes) |
| `exports/` | JSON exports of every reporting dataset |
| `imports/`, `imports_hold/` | Source Excel files, which include student and faculty data |
| `uploads/`, `extensions/` | Directus uploads and extensions |

Never commit these. They contain credentials or protected student data.

## Requirements

- Docker Desktop with Docker Compose
- The `.env` file and `.secrets/` folder described above

## Running the app

From `C:\Directus\relational-repository`:

```powershell
docker compose up -d --build
```

Then open <http://localhost:8080>.

Useful commands:

```powershell
docker compose ps                   # status and health of each service
docker compose logs -f middleware   # follow middleware logs
docker compose down                 # stop everything (data is kept in data/)
```

Health checks:

- UI: <http://localhost:8080/health>
- Middleware: <http://localhost:3001/health>

## API endpoints (middleware)

All are `GET` requests and return JSON with a `request_id`.

| Endpoint | Returns |
|---|---|
| `/api/courses` | Course catalog list. Query params: `page`, `limit`, `course_code`, `course_title`, `college_name`, `department_name`, `sort` (`course_code` or `-course_code`) |
| `/api/courses/:course_id` | Course detail |
| `/api/courses/:course_id/all` | Course detail plus every section below in one call (`data.course`, `data.sections`; `meta.sections` says which sections were available) |
| `/api/filter-options` | Distinct college and department pairs for the filter dropdowns |
| `/api/data-status` | Row count and last rebuild time for each data area (shown in the UI's Data status panel) |
| `/api/export` | List of exported datasets (from `exports/manifest.json`), each with rows, checksum and URL |
| `/api/export/:dataset` | One whole dataset as JSON, exactly as written to `exports/` (see Exporting data as JSON) |
| `/api/v1/openapi.json` | OpenAPI 3.0 description of every endpoint and field |
| `/api/courses/:course_id/grades` | Grade summary |
| `/api/courses/:course_id/enrollment` | Enrollment summary |
| `/api/courses/:course_id/dfwi` | DFWI summary |
| `/api/courses/:course_id/faculty-survey` | Faculty survey summary |
| `/api/courses/:course_id/student-survey` | Student survey summary |
| `/api/courses/:course_id/student-survey/questions` | Student survey question-level summary |
| `/api/courses/:course_id/instructional-design-development` | Instructional design and development summary |
| `/api/courses/:course_id/ai-production` | AI production projects for the course (AI in this course) |
| `/api/courses/:course_id/integrations` | Integrations for the course (month last done or started, per integration type) |
| `/api/courses/:course_id/redeveloped` | Instructor feedback on redeveloped sections (no instructor names or emails) |
| `/api/courses/:course_id/observations` | Faculty observation totals for the course, all terms combined (no Emplids or comments; ratings hidden below 3 observations) |

Each endpoint reads from a matching `*_api` collection in the `reporting` schema (for example, `course_grade_summary_api`).

Responses are gzip-compressed for clients that send `Accept-Encoding: gzip`.

### For other tools: `/api/v1` and API keys

Tools should call **`/api/v1/...`** (the same endpoints as `/api/...`). In `/api/v1`, numeric fields are JSON numbers (in `/api` some come through as text, e.g. `"67"`). The full description is at `/api/v1/openapi.json`.

Every `/api` and `/api/v1` call needs an **`X-API-Key`** header; `/health` does not. Each tool gets its own key. Only a SHA-256 fingerprint of each key is kept, in `.secrets/api_keys.json`. The web app's key is added by nginx (from `UI_API_KEY` in `.env`), so the browser never sees it and the app needs no key of its own. If the key file is missing, the API refuses all calls.

Manage keys with `src/keys.js` (the key is printed once; copy it then):

```
docker compose run --rm --no-deps -v "${PWD}\.secrets:/keys" --entrypoint node middleware src/keys.js add n8n
docker compose run --rm --no-deps -v "${PWD}\.secrets:/keys" --entrypoint node middleware src/keys.js list
docker compose run --rm --no-deps -v "${PWD}\.secrets:/keys" --entrypoint node middleware src/keys.js revoke n8n
```

A revoked key stops working within seconds, without a restart. A tool calls, for example:

```
curl.exe -H "X-API-Key: <key>" http://127.0.0.1:3001/api/v1/data-status
```

**Setting up the web app's key** (once, or after replacing it): run `keys.js add ui`, then open `.env` in Notepad and add the key on **a new line of its own** as `UI_API_KEY=air_...`, save, and run `docker compose up -d`. Don't append it with `Add-Content`: if `.env` doesn't end with a line break, the key is glued onto the previous setting.

The API is still reachable only from this computer (ports bound to `127.0.0.1`).

## Importing Excel data (optional)

The loader reads every `.xlsx` file in `imports/`, skipping any with "old" in the name. It stores each row as raw JSON in the `phase2_staging` tables and records the batch, file, and checksum. It only stages data; it does not change the reporting tables.

```powershell
docker compose -f compose.yaml -f compose.loader.yaml run --rm --build loader
```

## Uploading a Tableau workbook (.twbx)

Put the new `.twbx` in `imports_hold/` (the file name can change; the newest `.twbx` is used). Then run:

```
docker compose -f compose.yaml -f compose.upload.yaml run --rm --build upload preview
```

The preview unpacks the workbook, compares every dataset with the existing data by its key, and writes a report to `upload_reports/`: new rows, unchanged rows, changed rows, rows missing from the file, and any added or missing columns. It changes nothing in the live tables. Changed rows are only listed, never applied, and rows missing from the file are kept.

After reviewing the report, back up the database, run `check` (does everything, then rolls it back), and then `apply`:

```
New-Item -ItemType Directory -Force backups | Out-Null
docker compose exec -T database sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f /tmp/before-upload.dump'
docker compose cp database:/tmp/before-upload.dump backups/before-upload.dump
docker compose -f compose.yaml -f compose.upload.yaml run --rm --build upload check
docker compose -f compose.yaml -f compose.upload.yaml run --rm --build upload apply
```

To rebuild only the reporting tables from the data already loaded (no upload), run `upload refresh` the same way.

`apply` only works on the file that was previewed. It adds the new rows (grades with any new terms and sections, the Master Course rows, and the survey and schedule rows) under one new import batch, then rebuilds the reporting tables and their API copies with the `sql/refresh` builds, all in one transaction. Old faculty survey rows with no `UniqueID` are skipped. A preview run after an apply should show nothing left to add.

## Exporting data as JSON

Every `apply` and `refresh` ends by writing all 12 reporting datasets to `exports/` as JSON. To write them on their own:

```
docker compose -f compose.yaml -f compose.upload.yaml run --rm --build upload export
```

Each file is `exports/<dataset>.json` with the shape `{"meta": {...}, "data": [ ... ]}`. `meta` gives the dataset, source table, row count, field names, data as-of time and export time. `exports/manifest.json` (written last) lists every file with its row count and SHA-256 checksum. Files are written under a temporary name and renamed when complete, so a reader never sees a half-written file. All datasets come from one consistent snapshot and use the same tables, and privacy rules, as the API.

Datasets: `catalog`, `grades`, `enrollment`, `dfwi`, `faculty-survey`, `student-survey`, `student-survey-questions`, `instructional-design-development`, `ai-production`, `integrations`, `redeveloped`, `observations`.

Other tools can read the folder or call `GET /api/export` (list) and `GET /api/export/<dataset>` (one file, gzip-compressed if requested, with `X-Export-Sha256` and `X-Export-Rows` headers).

## Making changes

- **UI:** edit files in `ui/`, then run `docker compose up -d --build ui`
- **Middleware:** edit `middleware/src/server.js`, then run `docker compose up -d --build middleware`

### Adding a new course section

Follow the pattern of the AI, Integrations and Redeveloped sections:

1. `sql/refresh/build_<name>.sql`: builds a temporary table `tmp_course_<name>_summary` from the staging data.
2. `sql/schema/create_<name>_tables.sql`: creates `reporting.course_<name>_summary` and its `_api` copy (owner `directus_repository`; `SELECT` on the `_api` copy for `directus_runtime`). Run it once.
3. `sql/schema/register_<name>_directus.sql`: copies the DFWI collection's Directus settings and read permission. Run it once, then `docker compose restart directus`.
4. `loader/twbx_upload.py`: add the table to `PROJECTIONS` (with its API id formula) and the build file to `BUILD_FILES`. Run `upload refresh` to fill it.
5. `middleware/src/server.js`: add an entry to `courseSections` (path, collection, sort, fields).
6. `ui/`: add the section to `index.html` and its loader to `app.js` (use `loadSectionRows`), then rebuild `middleware` and `ui`.

### Running SQL from PowerShell

Pipe the SQL in. Windows PowerShell removes double quotes inside a single-quoted argument, so `psql -c "..."` does not work as written:

```
"SELECT count(*) FROM core.grade;" | docker compose exec -T database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
Get-Content some_file.sql | docker compose exec -T database sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

## Database notes

The database structure (the `core`, `staging`, `phase2_staging` and `reporting` schemas, roles, and permissions) exists in the running database. The reporting tables can be rebuilt at any time from the data already loaded with `upload refresh`; the build SQL in `sql/refresh/` was verified on 2 Nov 2026 to reproduce the original tables exactly. The scripts that first created the schemas are in the first commit's history on GitHub. Keep regular backups in `backups/`, because that is the main way to restore the database.

### Restoring a backup

This puts the whole database back exactly as it was when the backup was taken. Anything added later is removed, including tables and Directus registrations from `sql/schema/` (run those again afterwards if needed). Restore into a recreated database: a plain `pg_restore --clean` does not remove tables created after the backup.

```
docker compose stop directus middleware
docker compose cp backups/before-upload.dump database:/tmp/restore.dump
docker compose exec -T database sh -c 'dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB" && pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/restore.dump'
docker compose start directus middleware
```
