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

## Project layout

| Path | Purpose |
|---|---|
| `compose.yaml` | Defines and runs all services |
| `compose.loader.yaml` | Optional Excel import job (see below) |
| `ui/` | Web UI: `index.html`, `app.js`, `styles.css`, plus the nginx config and Dockerfile |
| `middleware/` | Node.js/Express API (`src/server.js`) |
| `loader/` | Python script that loads Excel workbooks into staging tables |

These local folders are **not in git** (see `.gitignore`):

| Path | Contents |
|---|---|
| `.env` | Database name/user/password, Directus version, port, URL, and secret |
| `.secrets/` | `directus_runtime_db_password.txt` and `wwairml_directus_static_token.txt` |
| `data/` | PostgreSQL data files (the actual database) |
| `backups/` | Database dumps |
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
| `/api/filter-options` | Distinct college and department pairs for the filter dropdowns |
| `/api/courses/:course_id/grades` | Grade summary |
| `/api/courses/:course_id/enrollment` | Enrollment summary |
| `/api/courses/:course_id/dfwi` | DFWI summary |
| `/api/courses/:course_id/faculty-survey` | Faculty survey summary |
| `/api/courses/:course_id/student-survey` | Student survey summary |
| `/api/courses/:course_id/student-survey/questions` | Student survey question-level summary |
| `/api/courses/:course_id/instructional-design-development` | Instructional design and development summary |

Each endpoint reads from a matching `*_api` collection in the `reporting` schema (for example, `course_grade_summary_api`).

## Importing Excel data (optional)

The loader reads every `.xlsx` file in `imports/`, skipping any with "old" in the name. It stores each row as raw JSON in the `phase2_staging` tables and records the batch, file, and checksum. It only stages data; it does not change the reporting tables.

```powershell
docker compose -f compose.yaml -f compose.loader.yaml run --rm loader
```

## Making changes

- **UI:** edit files in `ui/`, then run `docker compose up -d --build ui`
- **Middleware:** edit `middleware/src/server.js`, then run `docker compose up -d --build middleware`

## Database notes

The database structure (the `reporting` and `phase2_staging` schemas, roles, and permissions) exists in the running database. The SQL scripts used to build it during development are not in the current version of this repo. They are in the first commit's history on GitHub. Keep regular backups in `backups/`, because that is the main way to restore the database.
