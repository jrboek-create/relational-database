// Manages API keys for tools that call the middleware directly. Only a SHA-256 fingerprint of each key is stored,
// in api_keys.json (in KEYS_DIR, default /keys), so the file cannot be used to call the API.
//   node src/keys.js add <name>      create a key (printed once)
//   node src/keys.js list            show key names
//   node src/keys.js revoke <name>   remove a key (takes effect within seconds, no restart)
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import crypto from "node:crypto";
import path from "node:path";

const file = path.join(process.env.KEYS_DIR || "/keys", "api_keys.json");
const load = () => (existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { keys: [] });
const save = (doc) => {
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n");
  renameSync(tmp, file);
};
const [command, name] = process.argv.slice(2);
const doc = load();

if (command === "add") {
  if (!/^[a-z0-9_-]{1,40}$/.test(name || "")) throw new Error("Give a key name: lowercase letters, digits, - or _ (e.g. ui, n8n, ida).");
  if (doc.keys.some((k) => k.name === name)) throw new Error(`A key named "${name}" already exists. Revoke it first to replace it.`);
  const key = "air_" + crypto.randomBytes(24).toString("base64url");
  doc.keys.push({ name, sha256: crypto.createHash("sha256").update(key).digest("hex"), created_utc: new Date().toISOString() });
  save(doc);
  console.log(`Key "${name}" created. Copy it now; it is not stored and cannot be shown again:\n\n${key}\n`);
} else if (command === "list") {
  if (doc.keys.length === 0) console.log("No keys.");
  for (const k of doc.keys) console.log(`${k.name.padEnd(20)} created ${k.created_utc}`);
} else if (command === "revoke") {
  const before = doc.keys.length;
  doc.keys = doc.keys.filter((k) => k.name !== name);
  if (doc.keys.length === before) throw new Error(`No key named "${name}".`);
  save(doc);
  console.log(`Key "${name}" revoked.`);
} else {
  console.log("Use: node src/keys.js add <name> | list | revoke <name>");
  process.exitCode = 1;
}
