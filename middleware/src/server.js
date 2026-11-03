import express from "express";
import compression from "compression";
import { readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import crypto from "node:crypto";
import { effectivePermissions, SECTION_PERMISSION, questionKey, PERMISSIONS } from "./permissions.js";

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

// ---------------------------------------------------------------- sign-in, roles and permissions (stage 1)
// People use the web app (nginx adds the "ui" key) and must sign in; tools with their own keys keep full access.
// Passwords are checked by Directus. The session is a signed HttpOnly cookie, so sign-ins survive a middleware restart. Roles and ticked items come
// from app_role / app_role_permission / app_user, read with the read-only token and cached briefly.
const UI_KEY_NAME = process.env.UI_KEY_NAME || "ui";
const SESSION_COOKIE = "air_session";
const SESSION_IDLE_MS = 4 * 60 * 60 * 1000;   // signed out after 4 hours without activity
const SESSION_MAX_MS = 12 * 60 * 60 * 1000;   // and after 12 hours in any case
const ACCESS_CACHE_MS = 30 * 1000;            // role changes apply within 30 seconds
const LOGIN_FAILURE_LIMIT = 5;                // per email, per 15 minutes
const SESSION_REFRESH_MS = 5 * 60 * 1000;     // the cookie's "last seen" time is renewed at most every 5 minutes
const signedOut = new Map();                  // "userId:created" -> time the session would end anyway (sign-outs since start)
const accessCache = new Map();                // userId -> { at, access }
const loginFailures = new Map();              // email -> { count, first }
const TOOL_ACCESS = { tool: true, admin: true, user: null, role: { name: "API key", is_admin: true }, permissions: effectivePermissions([], true) };

function readCookie(req, name) {
  for (const part of (req.get("cookie") || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return null;
}

// Cookie = base64url({u: user id, c: created, s: last seen}) + "." + HMAC signature. The signing key is derived from
// the read-only Directus token in .secrets, so replacing that token signs everyone out.
const sessionKey = crypto.createHash("sha256").update("air-session-v1:" + directusToken).digest();
const sign = (payload) => crypto.createHmac("sha256", sessionKey).update(payload).digest("base64url");

function setSessionCookie(res, userId, created, lastSeen) {
  const payload = Buffer.from(JSON.stringify({ u: userId, c: created, s: lastSeen })).toString("base64url");
  const maxAge = Math.max(0, Math.floor((created + SESSION_MAX_MS - Date.now()) / 1000));
  res.append("Set-Cookie", `${SESSION_COOKIE}=${payload}.${sign(payload)}; HttpOnly; SameSite=Strict; Path=/api; Max-Age=${maxAge}`);
}

function currentSession(req, res) {
  const token = readCookie(req, SESSION_COOKIE) || "";
  const [payload, signature = ""] = token.split(".");
  if (!payload) return null;
  const expected = Buffer.from(sign(payload)), given = Buffer.from(signature);
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  let data;
  try { data = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")); } catch { return null; }
  const { u: userId, c: created, s: lastSeen } = data || {};
  const now = Date.now();
  if (typeof userId !== "string" || !Number.isFinite(created) || !Number.isFinite(lastSeen)) return null;
  if (now - lastSeen > SESSION_IDLE_MS || now - created > SESSION_MAX_MS || signedOut.has(`${userId}:${created}`)) return null;
  if (res && now - lastSeen > SESSION_REFRESH_MS) setSessionCookie(res, userId, created, now);
  return { userId, created };
}

const endSession = (session) => signedOut.set(`${session.userId}:${session.created}`, session.created + SESSION_MAX_MS);

setInterval(() => {   // forget sign-outs of sessions that have ended anyway, and old login failures
  const now = Date.now();
  for (const [key, until] of signedOut) if (until < now) signedOut.delete(key);
  for (const [email, f] of loginFailures) if (now - f.first > 15 * 60 * 1000) loginFailures.delete(email);
}, 10 * 60 * 1000).unref();

async function directusJson(pathAndQuery) {
  const upstream = await fetch(`${directusUrl}${pathAndQuery}`, { headers: { Authorization: `Bearer ${directusToken}`, Accept: "application/json" } });
  return upstream.ok ? (await upstream.json()).data : null;
}

// { user, role, admin, permissions } for a Directus user, or null if they have no (active) access to this app.
async function loadAccess(userId, fresh = false) {
  const cached = accessCache.get(userId);
  if (!fresh && cached && Date.now() - cached.at < ACCESS_CACHE_MS) return cached.access;
  const id = encodeURIComponent(userId);
  const users = await directusJson(`/items/app_user?filter[directus_user_id][_eq]=${id}&fields=directus_user_id,email,display_name,role_id,active&limit=1`);
  if (users === null) throw new Error("app_user unavailable");
  const user = users[0];
  let access = null;
  if (user && user.active) {
    const roles = await directusJson(`/items/app_role?filter[id][_eq]=${encodeURIComponent(user.role_id)}&fields=id,name,is_admin&limit=1`);
    const ticked = await directusJson(`/items/app_role_permission?filter[role_id][_eq]=${encodeURIComponent(user.role_id)}&fields=permission_key&limit=-1`);
    if (roles === null || ticked === null) throw new Error("app_role unavailable");
    const role = roles[0];
    if (role) {
      access = {
        tool: false,
        admin: role.is_admin === true,
        user: { id: user.directus_user_id, email: user.email, display_name: user.display_name },
        role: { id: role.id, name: role.name, is_admin: role.is_admin === true },
        permissions: effectivePermissions(ticked.map((t) => t.permission_key), role.is_admin === true)
      };
    }
  }
  accessCache.set(userId, { at: Date.now(), access });
  return access;
}

const describeAccess = (access) => ({ user: access.user, role: access.role, permissions: [...access.permissions] });

// Every /api call from the web app needs a signed-in user (except signing in and out).
app.use("/api", async (req, res, next) => {
  // SIGN_IN_REQUIRED stays off until the app's sign-in screen is deployed (stage 2); until then the app works as before.
  if (req.apiClient !== UI_KEY_NAME || process.env.SIGN_IN_REQUIRED !== "true") {
    req.access = TOOL_ACCESS;
    return next();
  }
  if (req.path === "/auth/login" || req.path === "/auth/logout") return next();
  const deny = (status, code, message) => res.status(status).json({ ok: false, request_id: req.requestId, error: { code, message } });
  const session = currentSession(req, res);
  if (!session) return deny(401, "SIGN_IN_REQUIRED", "Please sign in.");
  try {
    const access = await loadAccess(session.userId);
    if (!access) {
      endSession(session);
      res.set("Set-Cookie", `${SESSION_COOKIE}=; HttpOnly; SameSite=Strict; Path=/api; Max-Age=0`);
      return deny(401, "NO_ACCESS", "This account no longer has access. Ask the Admin.");
    }
    req.access = access;
    return next();
  } catch {
    return deny(503, "DIRECTUS_UNAVAILABLE", "The sign-in service is unavailable.");
  }
});

app.post("/api/auth/login", async (req, res) => {
  const reply = (status, body) => {
    console.log(JSON.stringify({ event: "sign_in", request_id: req.requestId, status, email: typeof req.body?.email === "string" ? req.body.email.toLowerCase().slice(0, 254) : null }));
    return res.status(status).json({ ok: status === 200, request_id: req.requestId, ...body });
  };
  const email = typeof req.body?.email === "string" ? req.body.email.trim().toLowerCase() : "";
  const password = typeof req.body?.password === "string" ? req.body.password : "";
  if (!email || !password || email.length > 254 || password.length > 1024) {
    return reply(400, { error: { code: "INVALID_QUERY", message: "Enter your email and password." } });
  }
  const failures = loginFailures.get(email);
  if (failures && failures.count >= LOGIN_FAILURE_LIMIT && Date.now() - failures.first < 15 * 60 * 1000) {
    return reply(429, { error: { code: "TOO_MANY_ATTEMPTS", message: "Too many failed sign-ins. Try again in 15 minutes." } });
  }
  try {
    const login = await fetch(`${directusUrl}/auth/login`, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ email, password }) });
    if (!login.ok) {
      const f = loginFailures.get(email);
      loginFailures.set(email, f && Date.now() - f.first < 15 * 60 * 1000 ? { count: f.count + 1, first: f.first } : { count: 1, first: Date.now() });
      return reply(login.status >= 500 ? 503 : 401, { error: { code: login.status >= 500 ? "DIRECTUS_UNAVAILABLE" : "INVALID_LOGIN", message: login.status >= 500 ? "The sign-in service is unavailable." : "Email or password is incorrect." } });
    }
    const tokens = (await login.json()).data || {};
    // We only need to know who this is: the user id is in the token Directus just issued to us. Then end that Directus session.
    const userId = JSON.parse(Buffer.from(String(tokens.access_token || "").split(".")[1] || "", "base64url").toString("utf8") || "{}").id;
    if (tokens.refresh_token) {
      fetch(`${directusUrl}/auth/logout`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: tokens.refresh_token }) }).catch(() => {});
    }
    if (!userId) return reply(503, { error: { code: "DIRECTUS_UNAVAILABLE", message: "The sign-in service is unavailable." } });
    const access = await loadAccess(userId, true);
    if (!access) return reply(403, { error: { code: "NO_ACCESS", message: "This account has no access to the app. Ask the Admin." } });
    loginFailures.delete(email);
    const now = Date.now();
    setSessionCookie(res, userId, now, now);
    return reply(200, { data: describeAccess(access) });
  } catch {
    return reply(503, { error: { code: "DIRECTUS_UNAVAILABLE", message: "The sign-in service is unavailable." } });
  }
});

app.post("/api/auth/logout", (req, res) => {
  const session = currentSession(req);
  if (session) endSession(session);
  res.set("Set-Cookie", `${SESSION_COOKIE}=; HttpOnly; SameSite=Strict; Path=/api; Max-Age=0`);
  return res.status(200).json({ ok: true, request_id: req.requestId });
});

app.get("/api/auth/me", (req, res) => res.status(200).json({ ok: true, request_id: req.requestId, data: describeAccess(req.access) }));

// Anyone signed in can change their own password. Body: { current_password, new_password }.
// The current password is checked with Directus (and counts toward the sign-in lockout); the new one is set with the admin token.
app.post("/api/auth/password", async (req, res) => {
  const reply = (status, body) => {
    console.log(JSON.stringify({ event: "password_change", request_id: req.requestId, status, user: req.access?.user?.email || null }));
    return res.status(status).json({ ok: status === 200, request_id: req.requestId, ...body });
  };
  const fail = (status, code, message) => reply(status, { error: { code, message } });
  const user = req.access?.user;
  if (!user) return fail(403, "FORBIDDEN", "Sign in to change your password.");
  const email = String(user.email).toLowerCase();
  const current = req.body?.current_password, next = req.body?.new_password;
  if (typeof current !== "string" || !current) return fail(400, "INVALID_QUERY", "Enter your current password.");
  const problem = passwordProblem(next);
  if (problem) return fail(400, "WEAK_PASSWORD", problem);
  if (next === current) return fail(400, "WEAK_PASSWORD", "The new password must be different from the current one.");
  const failures = loginFailures.get(email);
  if (failures && failures.count >= LOGIN_FAILURE_LIMIT && Date.now() - failures.first < 15 * 60 * 1000) {
    return fail(429, "TOO_MANY_ATTEMPTS", "Too many wrong passwords. Try again in 15 minutes.");
  }
  try {
    const check = await fetch(`${directusUrl}/auth/login`, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ email, password: current }) });
    if (check.status >= 500) return fail(503, "DIRECTUS_UNAVAILABLE", "The sign-in service is unavailable.");
    if (!check.ok) {
      const f = loginFailures.get(email);
      loginFailures.set(email, f && Date.now() - f.first < 15 * 60 * 1000 ? { count: f.count + 1, first: f.first } : { count: 1, first: Date.now() });
      return fail(400, "WRONG_PASSWORD", "Your current password is incorrect.");
    }
    const tokens = (await check.json()).data || {};
    if (tokens.refresh_token) {
      fetch(`${directusUrl}/auth/logout`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: tokens.refresh_token }) }).catch(() => {});
    }
    await directusWrite("PATCH", `/users/${user.id}`, { password: next });
    loginFailures.delete(email);
    return reply(200, { data: { changed: true } });
  } catch (error) {
    if (error.code === "ADMIN_TOKEN_MISSING") return fail(503, "ADMIN_TOKEN_MISSING", "Passwords can't be changed yet. Ask the Admin.");
    return fail(503, "DIRECTUS_UNAVAILABLE", "The password could not be changed. Please try again.");
  }
});

// Exports, data status and the OpenAPI description: Admin (and tools with keys) only.
app.use(["/api/data-status", "/api/export", "/api/openapi.json"], (req, res, next) => {
  if (req.access?.admin) return next();
  return res.status(403).json({ ok: false, request_id: req.requestId, error: { code: "FORBIDDEN", message: "Only the Admin can use this." } });
});

// ---- Admin page: roles and their ticked items ------------------------------------------------------
// Only a signed-in Admin may use these. Changes are written with a separate Directus admin token
// (.secrets/directus_admin_token.txt); it is read on each change, so adding it needs no restart.
const adminTokenPath = path.resolve(__dirname, "../../.secrets/directus_admin_token.txt");
const permissionKeys = new Set(PERMISSIONS.map((p) => p.key));
const isUuid = (value) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(value));

async function directusWrite(method, pathAndQuery, body) {
  let token;
  try { token = readFileSync(adminTokenPath, "utf8").trim(); } catch { token = ""; }
  if (!token) throw Object.assign(new Error("admin token missing"), { code: "ADMIN_TOKEN_MISSING" });
  const upstream = await fetch(`${directusUrl}${pathAndQuery}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  if (!upstream.ok) throw Object.assign(new Error(`Directus ${method} ${upstream.status}`), { code: "DIRECTUS_WRITE_FAILED", status: upstream.status });
  return upstream.status === 204 ? null : (await upstream.json()).data;
}

async function loadRoles() {
  const [roles, ticked, users] = await Promise.all([
    directusJson("/items/app_role?fields=id,name,is_admin,built_in&sort=name&limit=-1"),
    directusJson("/items/app_role_permission?fields=id,role_id,permission_key&limit=-1"),
    directusJson("/items/app_user?fields=role_id,active&limit=-1")
  ]);
  if (roles === null || ticked === null || users === null) throw Object.assign(new Error("roles unavailable"), { code: "DIRECTUS_UNAVAILABLE" });
  return roles.map((role) => ({
    id: role.id, name: role.name, is_admin: role.is_admin === true, built_in: role.built_in === true,
    user_count: users.filter((u) => u.role_id === role.id && u.active).length,
    permissions: ticked.filter((t) => t.role_id === role.id).map((t) => t.permission_key),
    ticked_rows: ticked.filter((t) => t.role_id === role.id)
  }));
}

app.use("/api/admin", (req, res, next) => {
  if (req.access?.admin && req.access.user) return next();
  return res.status(403).json({ ok: false, request_id: req.requestId, error: { code: "FORBIDDEN", message: "Only a signed-in Admin can use this." } });
});

function adminRoute(handler) {
  return async (req, res) => {
    const reply = (status, body) => res.status(status).json({ ok: status < 300, request_id: req.requestId, ...body });
    const fail = (status, code, message) => reply(status, { error: { code, message } });
    try {
      await handler(req, reply, fail);
    } catch (error) {
      console.log(JSON.stringify({ event: "admin_error", request_id: req.requestId, path: req.path, code: error.code, status: error.status }));
      if (error.code === "ADMIN_TOKEN_MISSING") return fail(503, "ADMIN_TOKEN_MISSING", "Changes can't be saved yet: the Directus admin token isn't set up (see the README).");
      return fail(503, "DIRECTUS_UNAVAILABLE", "The change could not be saved. Please reload and try again.");
    }
  };
}

const logChange = (req, action, detail) =>
  console.log(JSON.stringify({ event: "admin_change", request_id: req.requestId, by: req.access.user.email, action, ...detail }));

const cleanName = (value) => (typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "");

// Roles with their ticked items, plus the list of items (with question wording) for the checkboxes.
app.get("/api/admin/roles", adminRoute(async (req, reply) => {
  const roles = (await loadRoles()).map(({ ticked_rows, ...role }) => role);
  reply(200, { data: { roles, items: PERMISSIONS.map(({ key, label, title, parent }) => ({ key, label, title: title || null, parent })) } });
}));

app.post("/api/admin/roles", adminRoute(async (req, reply, fail) => {
  const name = cleanName(req.body?.name);
  if (!name || name.length > 60) return fail(400, "INVALID_NAME", "Enter a role name (up to 60 characters).");
  const roles = await loadRoles();
  if (roles.some((r) => r.name.toLowerCase() === name.toLowerCase())) return fail(409, "NAME_TAKEN", "A role with that name already exists.");
  const id = crypto.randomUUID();
  await directusWrite("POST", "/items/app_role", { id, name, is_admin: false, built_in: false });
  logChange(req, "role_created", { role: name });
  reply(201, { data: { id } });
}));

// Body: { name?, permissions? } — permissions is the full list of ticked keys for the role.
app.patch("/api/admin/roles/:id", adminRoute(async (req, reply, fail) => {
  if (!isUuid(req.params.id)) return fail(404, "NOT_FOUND", "Role not found.");
  const roles = await loadRoles();
  const role = roles.find((r) => r.id === req.params.id);
  if (!role) return fail(404, "NOT_FOUND", "Role not found.");
  if (role.is_admin) return fail(403, "ADMIN_LOCKED", "The Admin role always sees everything and can't be changed.");
  const changes = {};
  if (req.body?.name !== undefined) {
    const name = cleanName(req.body.name);
    if (!name || name.length > 60) return fail(400, "INVALID_NAME", "Enter a role name (up to 60 characters).");
    if (roles.some((r) => r.id !== role.id && r.name.toLowerCase() === name.toLowerCase())) return fail(409, "NAME_TAKEN", "A role with that name already exists.");
    if (name !== role.name) changes.name = name;
  }
  let add = [], remove = [];
  if (req.body?.permissions !== undefined) {
    const wanted = req.body.permissions;
    if (!Array.isArray(wanted) || !wanted.every((k) => permissionKeys.has(k))) return fail(400, "INVALID_PERMISSIONS", "The list of ticked items is not valid.");
    const want = new Set(wanted);
    add = [...want].filter((k) => !role.permissions.includes(k));
    remove = role.ticked_rows.filter((t) => !want.has(t.permission_key));
  }
  if (changes.name) await directusWrite("PATCH", `/items/app_role/${role.id}`, { name: changes.name });
  for (const row of remove) await directusWrite("DELETE", `/items/app_role_permission/${row.id}`);
  if (add.length) await directusWrite("POST", "/items/app_role_permission", add.map((permission_key) => ({ id: crypto.randomUUID(), role_id: role.id, permission_key })));
  accessCache.clear();   // signed-in users get the change on their next request
  logChange(req, "role_updated", { role: changes.name || role.name, renamed_from: changes.name ? role.name : undefined, added: add, removed: remove.map((r) => r.permission_key) });
  reply(200, { data: { id: role.id } });
}));

app.delete("/api/admin/roles/:id", adminRoute(async (req, reply, fail) => {
  if (!isUuid(req.params.id)) return fail(404, "NOT_FOUND", "Role not found.");
  const roles = await loadRoles();
  const role = roles.find((r) => r.id === req.params.id);
  if (!role) return fail(404, "NOT_FOUND", "Role not found.");
  if (role.is_admin || role.built_in) return fail(403, "ADMIN_LOCKED", "The Admin role can't be deleted.");
  const assigned = await directusJson(`/items/app_user?filter[role_id][_eq]=${role.id}&fields=directus_user_id&limit=-1`);
  if (assigned === null) throw Object.assign(new Error("users unavailable"), { code: "DIRECTUS_UNAVAILABLE" });
  if (assigned.length) return fail(409, "ROLE_IN_USE", `${assigned.length} user${assigned.length === 1 ? " has" : "s have"} this role. Give them another role first.`);
  for (const row of role.ticked_rows) await directusWrite("DELETE", `/items/app_role_permission/${row.id}`);
  await directusWrite("DELETE", `/items/app_role/${role.id}`);
  accessCache.clear();
  logChange(req, "role_deleted", { role: role.name });
  reply(200, { data: { id: role.id } });
}));

// ---- Admin page: users ------------------------------------------------------------------------------
// Passwords live only in Directus. New accounts get no Directus role, so they can sign in to this app
// but can't use the Directus admin screens. app_user links each account to its app role.
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD = 12;
const passwordProblem = (value) =>
  typeof value !== "string" || value.length < MIN_PASSWORD || value.length > 200 ? `Use a password of at least ${MIN_PASSWORD} characters.` : null;

async function loadAppUser(id) {
  const rows = await directusJson(`/items/app_user?filter[directus_user_id][_eq]=${encodeURIComponent(id)}&fields=directus_user_id,email,display_name,role_id,active&limit=1`);
  if (rows === null) throw Object.assign(new Error("app_user unavailable"), { code: "DIRECTUS_UNAVAILABLE" });
  return rows[0] || null;
}

app.get("/api/admin/users", adminRoute(async (req, reply) => {
  const users = await directusJson("/items/app_user?fields=directus_user_id,email,display_name,role_id,active&sort=display_name&limit=-1");
  if (users === null) throw Object.assign(new Error("app_user unavailable"), { code: "DIRECTUS_UNAVAILABLE" });
  reply(200, { data: users.map((u) => ({ id: u.directus_user_id, email: u.email, display_name: u.display_name, role_id: u.role_id, active: u.active === true })) });
}));

// Body: { display_name, email, password, role_id }. If the email already has a Directus account, that account is
// linked and its password is left as it is.
app.post("/api/admin/users", adminRoute(async (req, reply, fail) => {
  const name = cleanName(req.body?.display_name);
  const email = typeof req.body?.email === "string" ? req.body.email.trim().toLowerCase() : "";
  if (!name || name.length > 100) return fail(400, "INVALID_NAME", "Enter the person's name.");
  if (!emailPattern.test(email) || email.length > 254) return fail(400, "INVALID_EMAIL", "Enter a valid email address.");
  const roles = await loadRoles();
  if (!roles.some((r) => r.id === req.body?.role_id)) return fail(400, "INVALID_ROLE", "Choose a role.");
  const taken = await directusJson(`/items/app_user?filter[email][_eq]=${encodeURIComponent(email)}&fields=directus_user_id&limit=1`);
  if (taken === null) throw Object.assign(new Error("app_user unavailable"), { code: "DIRECTUS_UNAVAILABLE" });
  if (taken.length) return fail(409, "EMAIL_TAKEN", "This person already has an account in the app.");
  const existing = await directusWrite("GET", `/users?filter[email][_eq]=${encodeURIComponent(email)}&fields=id&limit=1`);
  let id = existing[0]?.id, created = false;
  if (!id) {
    const problem = passwordProblem(req.body?.password);
    if (problem) return fail(400, "WEAK_PASSWORD", problem);
    id = crypto.randomUUID();
    await directusWrite("POST", "/users", { id, email, password: req.body.password, first_name: name, status: "active" });
    created = true;
  }
  try {
    await directusWrite("POST", "/items/app_user", { directus_user_id: id, email, display_name: name, role_id: req.body.role_id, active: true });
  } catch (error) {
    if (created) await directusWrite("DELETE", `/users/${id}`).catch(() => {});   // don't leave a half-made account
    throw error;
  }
  logChange(req, "user_created", { user: email, role: roles.find((r) => r.id === req.body.role_id).name, new_directus_account: created });
  reply(201, { data: { id, linked_existing_account: !created } });
}));

// Body: { role_id?, active? }. You can't change your own role or deactivate yourself (so the Admin can't lock themselves out).
app.patch("/api/admin/users/:id", adminRoute(async (req, reply, fail) => {
  if (!isUuid(req.params.id)) return fail(404, "NOT_FOUND", "User not found.");
  const user = await loadAppUser(req.params.id);
  if (!user) return fail(404, "NOT_FOUND", "User not found.");
  const changes = {};
  if (req.body?.role_id !== undefined && req.body.role_id !== user.role_id) {
    const roles = await loadRoles();
    if (!roles.some((r) => r.id === req.body.role_id)) return fail(400, "INVALID_ROLE", "Choose a role.");
    changes.role_id = req.body.role_id;
  }
  if (req.body?.active !== undefined) {
    if (typeof req.body.active !== "boolean") return fail(400, "INVALID_QUERY", "active must be true or false.");
    if (req.body.active !== user.active) changes.active = req.body.active;
  }
  if (!Object.keys(changes).length) return reply(200, { data: { id: user.directus_user_id } });
  if (user.directus_user_id === req.access.user.id) return fail(403, "SELF_CHANGE", "You can't change your own role or deactivate yourself.");
  await directusWrite("PATCH", `/items/app_user/${user.directus_user_id}`, changes);
  accessCache.clear();   // takes effect on the person's next click; a deactivated person is signed out
  logChange(req, "user_updated", { user: user.email, ...changes });
  reply(200, { data: { id: user.directus_user_id } });
}));

// Deletes a deactivated person from the app. Their Directus account is deleted too, but only if it has no Directus
// role (an account made for this app); Directus staff and admin accounts are kept.
app.delete("/api/admin/users/:id", adminRoute(async (req, reply, fail) => {
  if (!isUuid(req.params.id)) return fail(404, "NOT_FOUND", "User not found.");
  const user = await loadAppUser(req.params.id);
  if (!user) return fail(404, "NOT_FOUND", "User not found.");
  if (user.directus_user_id === req.access.user.id) return fail(403, "SELF_CHANGE", "You can't delete yourself.");
  if (user.active) return fail(409, "STILL_ACTIVE", "Deactivate this person before deleting them.");
  let account = null;
  try {
    account = await directusWrite("GET", `/users/${user.directus_user_id}?fields=id,role`);
  } catch (error) {
    if (error.status !== 403 && error.status !== 404) throw error;   // Directus answers 403 for an account that no longer exists
  }
  await directusWrite("DELETE", `/items/app_user/${user.directus_user_id}`);
  const deleteAccount = Boolean(account) && !account.role;
  if (deleteAccount) await directusWrite("DELETE", `/users/${user.directus_user_id}`);
  accessCache.clear();
  logChange(req, "user_deleted", { user: user.email, directus_account_deleted: deleteAccount });
  reply(200, { data: { id: user.directus_user_id, directus_account_deleted: deleteAccount } });
}));

// Body: { password } — sets a new password in Directus and clears any sign-in lockout for that email.
app.post("/api/admin/users/:id/password", adminRoute(async (req, reply, fail) => {
  if (!isUuid(req.params.id)) return fail(404, "NOT_FOUND", "User not found.");
  const user = await loadAppUser(req.params.id);
  if (!user) return fail(404, "NOT_FOUND", "User not found.");
  const problem = passwordProblem(req.body?.password);
  if (problem) return fail(400, "WEAK_PASSWORD", problem);
  await directusWrite("PATCH", `/users/${user.directus_user_id}`, { password: req.body.password });
  loginFailures.delete(String(user.email).toLowerCase());
  logChange(req, "password_reset", { user: user.email });
  reply(200, { data: { id: user.directus_user_id } });
}));

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
      const needed = SECTION_PERMISSION[section.path];
      if (needed && !req.access.permissions.has(needed)) return fail(403, "FORBIDDEN", `Your role does not include ${section.label}.`);

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
      if (section.path === "student-survey/questions") data = data.filter((row) => req.access.permissions.has(questionKey(row.survey_version, row.question_number)));
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

    const allowedSections = courseSections.filter((section) => !SECTION_PERMISSION[section.path] || req.access.permissions.has(SECTION_PERMISSION[section.path]));
    const notPermitted = courseSections.filter((section) => !allowedSections.includes(section)).map((section) => section.path.replaceAll("/", "-"));
    const [detail, ...results] = await Promise.all([
      directusItems("course_catalog_detail_api", detailParams, req.requestId),
      ...allowedSections.map((section) => {
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
    const numeric = req.apiVersion === 1 ? await Promise.all(allowedSections.map((section) => numericFields(section.collection))) : null;
    const sections = {};
    const sectionMeta = {};
    allowedSections.forEach((section, i) => {
      const key = section.path.replaceAll("/", "-");
      const result = results[i];
      let rows = result.ok ? result.data.map((row) => Object.fromEntries(section.fields.map((field) => [field, row[field] ?? null]))) : null;
      if (rows && section.path === "student-survey/questions") rows = rows.filter((row) => req.access.permissions.has(questionKey(row.survey_version, row.question_number)));
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
    return res.status(200).json({ ok: true, request_id: req.requestId, data: { course, sections }, meta: { course_id: courseId, sections: sectionMeta, unavailable, not_permitted: notPermitted } });
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

