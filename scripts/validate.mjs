import fs from "node:fs";
import vm from "node:vm";

const file = new URL("../index.html", import.meta.url);
const html = fs.readFileSync(file, "utf8");
const fail = (message) => { console.error("FAIL:", message); process.exitCode = 1; };
const pass = (message) => console.log("PASS:", message);

if (!html.startsWith("<!doctype html>")) fail("index.html must start with a doctype");
else pass("HTML document has a doctype");

const ids = [...html.matchAll(/\bid=["']([^"']+)["']/g)].map(m => m[1]);
const duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
if (duplicates.length) fail("Duplicate element IDs: " + [...new Set(duplicates)].join(", "));
else pass("Element IDs are unique");

const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!scripts.length) fail("No inline application script found");
else {
  try { new vm.Script(scripts.join("\n"), { filename: "index.html:inline-script" }); pass("Inline JavaScript parses"); }
  catch (error) { fail("Inline JavaScript syntax error: " + error.message); }
}

const taskBlock = html.match(/var tasks=([\s\S]*?);\s*\nvar current=/);
if (!taskBlock) fail("Task catalogue was not found");
else {
  try {
    const tasks = vm.runInNewContext(taskBlock[1]);
    const taskIds = tasks.map(t => t.id);
    if (new Set(taskIds).size !== taskIds.length) fail("Task IDs must be unique");
    else pass("Task IDs are unique");

    const taskCategories = new Set(tasks.map(t => t.cat));
    const filterCategories = new Set([...html.matchAll(/data-filter="([^"]+)"/g)].map(m => m[1]));
    const missing = [...filterCategories].filter(c => c !== "全部" && !taskCategories.has(c));
    if (missing.length) fail("Filters without tasks: " + missing.join(", "));
    else pass("Every task filter maps to an existing category");

    if (tasks.some(t => typeof t.pay !== "number" || t.pay < 0)) fail("Task pay must be a non-negative number");
    else pass("Task pay values are valid");

    if (!tasks.some(t => t.pay === 0)) fail("Keep at least one unpriced task as a safety case");
    else pass("Unpriced task safety case exists");
  } catch (error) { fail("Task catalogue could not be evaluated: " + error.message); }
}

for (const required of ["requestForm", "requestBudget", "feeBase", "feeService", "feeTotal", "taskList", "myOrders"]) {
  if (!ids.includes(required)) fail("Missing required UI element #" + required);
}
if (["requestForm", "requestBudget", "feeBase", "feeService", "feeTotal", "taskList", "myOrders"].every(id => ids.includes(id))) {
  pass("Core user flows have their required UI elements");
}

if (!html.includes("当前不会产生真实订单")) fail("Demo claim flow must clearly disclose that it creates no real order");
else pass("Demo task claim is clearly labelled");

if (!html.includes("不会发送到平台后台")) fail("Local-only request storage must be disclosed in the UI");
else pass("Local-only request submission is clearly disclosed");

if (process.exitCode) process.exit(process.exitCode);
console.log("Quality checks completed.");
