import fs from "node:fs";
import vm from "node:vm";

const root = new URL("../", import.meta.url);
const html = fs.readFileSync(new URL("index.html", root), "utf8");
const admin = fs.readFileSync(new URL("admin.html", root), "utf8");
let failures = 0;
const check = (condition, passMessage, failMessage) => {
  if (condition) console.log("PASS:", passMessage);
  else { console.error("FAIL:", failMessage); failures++; }
};

function validatePage(source, name) {
  check(source.startsWith("<!doctype html>"), name + " has a doctype", name + " is missing its doctype");
  const ids = [...source.matchAll(/id=["']([^"']+)["']/g)].map(m => m[1]);
  const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
  check(duplicates.length === 0, name + " element IDs are unique", name + " has duplicate IDs: " + [...new Set(duplicates)].join(", "));
  const scripts = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  let syntaxOK = scripts.length > 0;
  try {
    if (!syntaxOK) throw new Error("No inline script found");
    for (const script of scripts) new vm.Script(script, { filename: name + ":inline-script" });
  } catch (error) {
    syntaxOK = false;
    console.error(name + " JavaScript:", error.message);
  }
  check(syntaxOK, name + " JavaScript parses", name + " JavaScript failed to parse");
  return ids;
}

const ids = validatePage(html, "index.html");
validatePage(admin, "admin.html");

const taskBlock = html.match(/var tasks=([\s\S]*?);\s*\nvar current=/);
let tasks = [];
try {
  if (!taskBlock) throw new Error("Task catalogue was not found");
  tasks = vm.runInNewContext(taskBlock[1]);
  check(new Set(tasks.map(t => t.id)).size === tasks.length, "Task IDs are unique", "Task IDs are duplicated");
  const categories = new Set(tasks.map(t => t.cat));
  const filters = new Set([...html.matchAll(/data-filter="([^"]+)"/g)].map(m => m[1]));
  const missing = [...filters].filter(c => c !== "全部" && !categories.has(c));
  check(missing.length === 0, "Every task filter maps to an existing category", "Filters without tasks: " + missing.join(", "));
  check(tasks.every(t => typeof t.pay === "number" && t.pay >= 0), "Task pay values are valid", "Task pay must be a non-negative number");
  check(tasks.some(t => t.pay === 0), "An unpriced task safety case exists", "Keep an unpriced task safety case");
} catch (error) {
  check(false, "", "Task catalogue validation failed: " + error.message);
}

for (const id of ["requestForm", "requestBudget", "feeBase", "feeService", "feeTotal", "taskList", "myOrders"]) {
  check(ids.includes(id), "Core UI element #" + id + " exists", "Missing core UI element #" + id);
}
check(html.includes("当前不会产生真实订单"), "Demo claim is clearly labelled", "Demo claim disclosure is missing");
check(html.includes("尚未发送到平台后台"), "Local-only request storage is disclosed", "Local-only storage disclosure is missing");
for (const label of ["需求审核", "项目与任务拆分", "任务履约与验收", "利润核算", "没有登录鉴权"]) {
  check(admin.includes(label), "Admin module/safeguard exists: " + label, "Admin module/safeguard missing: " + label);
}
check(admin.includes("本机") && admin.includes("演示"), "Admin prototype warns that data is local demo data", "Admin local-demo warning is missing");

if (failures) {
  console.error("Quality checks failed:", failures);
  process.exit(1);
}
console.log("All product prototype quality checks passed.");
