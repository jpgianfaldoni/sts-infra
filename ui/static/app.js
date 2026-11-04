/* Local form-based UI for ./infra. Talks only to the local JSON API in ui/server.py. */
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const state = { manifest: null, targets: {}, templates: [], environments: [], current: null, run: null, poll: null };

function notice(text, isError = false) {
  const el = $("#notice");
  el.textContent = text || "";
  el.classList.toggle("error", isError);
  if (text) setTimeout(() => { if (el.textContent === text) el.textContent = ""; }, 8000);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: options.body ? { "Content-Type": "application/json" } : {},
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `${response.status} ${response.statusText}`);
  return payload;
}

function show(view) {
  $$("nav button").forEach(b => b.classList.toggle("active", b.dataset.view === view));
  $$(".view").forEach(v => v.classList.toggle("hidden", v.id !== `view-${view}`));
}
$$("nav button").forEach(b => b.addEventListener("click", () => show(b.dataset.view)));

/* ---------------- environments list ---------------- */

function ageText(seconds) {
  if (seconds < 3600) return `${Math.max(Math.floor(seconds / 60), 0)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

async function loadEnvironments() {
  const data = await api("/api/environments");
  state.environments = data.environments;
  const list = $("#environment-list");
  list.innerHTML = "";
  if (!data.environments.length) {
    list.innerHTML = '<div class="item muted">No environments yet. Use "New environment".</div>';
    return;
  }
  for (const env of data.environments) {
    const item = document.createElement("div");
    item.className = "item" + (state.current === env.name ? " active" : "");
    const badges = [`<span class="badge ${env.cloud}">${env.cloud}</span>`];
    if (env.resources) badges.push(`<span class="badge live">${env.resources} resources</span>`);
    if (env.running) badges.push('<span class="badge running">running</span>');
    item.innerHTML = `<div class="name">${env.name}${badges.join("")}</div>
      <div class="meta">${env.scenario || env.tfvars}</div>
      <div class="meta">${env.target ? "target " + env.target : "no target"}${env.stage ? " · stage " + env.stage : ""}${env.verify ? " · verify " + env.verify.status : ""}</div>`;
    item.addEventListener("click", () => openEnvironment(env.name));
    list.appendChild(item);
  }
}

/* ---------------- environment detail ---------------- */

function fillTargetSelect(select, cloud, selected) {
  select.innerHTML = '<option value="">(none)</option>';
  for (const [name, target] of Object.entries(state.targets)) {
    if (target.cloud !== cloud) continue;
    const option = document.createElement("option");
    option.value = name;
    option.textContent = `${name}${target.description ? " · " + target.description : ""}`;
    option.selected = name === selected;
    select.appendChild(option);
  }
}

function renderForm(root, detail) {
  const formEl = $(".env-form", root);
  const model = detail.form;
  $('textarea[name="text"]', formEl).value = detail.text;
  if (!model) {
    $(".features", formEl).innerHTML = `<p class="err">Terraform rejected this file, so the form cannot be shown. Fix the text below.</p><pre class="output">${escapeHtml(detail.error || "")}</pre>`;
    $(".connectivity tbody", formEl).innerHTML = "";
    $("details.raw", formEl).open = true;
    return;
  }
  const components = state.manifest.clouds[detail.cloud].components;
  fillTargetSelect($('select[name="target"]', formEl), detail.cloud, model.target);
  const region = $('input[name="region"]', formEl);
  region.value = model.explicit_region ? (model.region || "") : "";
  region.placeholder = model.region ? `${model.region} (from target or default)` : (detail.cloud === "aws" ? "us-west-2" : "westus2");
  $(".region-label", formEl).firstChild.textContent = detail.cloud === "aws" ? "Region " : "Location ";
  $('select[name="endpoint_approval"]', formEl).value = model.endpoint_approval || "auto";

  const features = $(".features", formEl);
  features.innerHTML = "";
  for (const [name, on] of Object.entries(model.features)) {
    const component = components[name];
    const row = document.createElement("label");
    row.className = "feature inline";
    row.innerHTML = `<input type="checkbox" name="feature:${name}" ${on ? "checked" : ""}>
      <span><strong>${name}</strong> <span class="cost">${component.cost || ""}${component.minutes ? ", ~" + component.minutes + " min" : ""}</span><br><span class="summary">${escapeHtml(component.summary || "")}</span></span>`;
    features.appendChild(row);
  }
  const tbody = $(".connectivity tbody", formEl);
  tbody.innerHTML = "";
  for (const [name, entry] of Object.entries(model.connectivity)) {
    const tr = document.createElement("tr");
    tr.dataset.source = name;
    const cell = (compute) => {
      if (!entry[compute]) return "<td class=\"muted\">n/a</td>";
      const options = entry[compute].allowed.map(mode => `<option value="${mode}" ${mode === entry[compute].mode ? "selected" : ""}>${mode}</option>`).join("");
      return `<td><select name="conn:${name}:${compute}">${options}</select></td>`;
    };
    tr.innerHTML = `<td><strong>${name}</strong></td>${cell("classic")}${cell("serverless")}`;
    tbody.appendChild(tr);
  }
  syncConnectivityRows(formEl);
  $$('input[name^="feature:"]', formEl).forEach(cb => cb.addEventListener("change", () => syncConnectivityRows(formEl)));
}

function syncConnectivityRows(formEl) {
  $$(".connectivity tbody tr", formEl).forEach(tr => {
    const cb = $(`input[name="feature:${tr.dataset.source}"]`, formEl);
    const enabled = !cb || cb.checked;
    tr.style.opacity = enabled ? "1" : ".4";
    $$("select", tr).forEach(s => s.disabled = !enabled);
  });
}

function collectForm(root, detail) {
  const formEl = $(".env-form", root);
  const model = { cloud: detail.cloud, features: {}, connectivity: {} };
  model.target = $('select[name="target"]', formEl).value || null;
  model.region = $('input[name="region"]', formEl).value.trim() || null;
  model.endpoint_approval = $('select[name="endpoint_approval"]', formEl).value;
  $$('input[name^="feature:"]', formEl).forEach(cb => { model.features[cb.name.slice(8)] = cb.checked; });
  $$('select[name^="conn:"]', formEl).forEach(sel => {
    const [, source, compute] = sel.name.split(":");
    model.connectivity[source] = model.connectivity[source] || {};
    model.connectivity[source][compute] = { mode: sel.value };
  });
  return model;
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function renderExplain(pre, report) {
  if (report.valid === false && report.error) { pre.textContent = `Terraform rejected the file:\n${report.error}`; return; }
  const lines = [];
  lines.push("What gets built:");
  for (const c of report.components || []) lines.push(`  - ${c.name}${c.derived ? " (derived)" : ""}: ${c.summary}`);
  if ((report.paths || []).length) {
    lines.push("", "Network paths from Databricks compute:");
    for (const p of report.paths) lines.push(`  - ${p.compute} -> ${p.source}: ${p.mode}${p.mode === "none" ? " (this compute cannot reach it)" : ". " + p.description}`);
  }
  lines.push("", "After deploy:");
  if (report.stages === 2) lines.push("  - A new AWS workspace deploys in two stages, with one browser login to the new workspace in between.");
  if (report.endpoint_approval === "auto") lines.push("  - Serverless private endpoint connections are approved right after apply.");
  if (report.endpoint_approval === "manual") lines.push("  - Serverless private endpoint connections stay pending until you approve them (Endpoints).");
  if ((report.checks || []).length) {
    lines.push("  - Verify runs these checks:");
    for (const c of report.checks) lines.push(`      ${c.compute} -> ${c.source} over ${c.mode}${c.sample_data ? ", loading the sample tables customers and orders" : ""}`);
  } else lines.push("  - No lab checks: no source has a compute path.");
  if (report.estimate) lines.push(`  - Typical build time: about ${report.estimate.minutes} minutes; running cost: ${report.estimate.cost}.`);
  pre.innerHTML = escapeHtml(lines.join("\n"));
  if ((report.findings || []).length) {
    pre.innerHTML += "\n\nFindings:\n" + report.findings.map(f => `<span class="finding-${f.level}">  [${f.level}] ${escapeHtml(f.message)}</span>`).join("\n");
  }
}

function renderPlanSummary(el, summary, kind) {
  if (!summary) { el.classList.add("hidden"); el.innerHTML = ""; return null; }
  const c = summary.counts || {};
  const parts = [`<strong>${kind} plan</strong>${summary.fresh ? "" : ' <span class="err">(older than an hour: plan again before applying)</span>'}`,
    `create=${c.create} update=${c.update} replace=${c.replace} delete=${c.delete}`];
  const risky = [...(summary.replace || []).map(a => `replace: ${a}`), ...(summary.delete || []).map(a => `delete: ${a}`)];
  if (risky.length) parts.push(`<div class="warn">${risky.map(escapeHtml).join("<br>")}</div>`);
  if (summary.stage === "foundation") parts.push("Deployment stage: foundation (1 of 2). Unity Catalog, Glue catalogs, and the lab check job come with the second plan after the workspace login.");
  if (summary.new_endpoint_rules) parts.push(`Endpoints: ${summary.new_endpoint_rules} serverless private endpoint connection(s) will be ${summary.endpoint_approval === "manual" ? "left pending for manual approval" : "approved automatically after apply"}.`);
  for (const w of summary.warnings || []) parts.push(`<span class="err">Warning: ${escapeHtml(w)}</span>`);
  el.innerHTML = parts.join("<br>");
  el.classList.remove("hidden");
  return summary;
}

async function refreshPlans(root, env) {
  const plans = await api(`/api/environments/${env.name}/plans`);
  const applySummary = renderPlanSummary($(".plan-summary", root), plans.apply, "Apply");
  const ack = $(".apply-ack", root);
  $(".confirm-apply", root).classList.toggle("hidden", !applySummary);
  ack.checked = false;
  $(".act-apply", root).disabled = !(applySummary && applySummary.fresh && ack.checked);
  ack.onchange = () => { $(".act-apply", root).disabled = !(applySummary && applySummary.fresh && ack.checked); };
  const destroySummary = renderPlanSummary($(".destroy-summary", root), plans.destroy, "Destroy");
  $(".confirm-destroy", root).classList.toggle("hidden", !destroySummary);
  $(".destroy-token", root).textContent = `destroy-${env.cloud}`;
  const input = $(".destroy-input", root);
  input.value = "";
  $(".act-destroy", root).disabled = true;
  input.oninput = () => { $(".act-destroy", root).disabled = !(destroySummary && destroySummary.fresh && input.value === `destroy-${env.cloud}`); };
  if (plans.verify && env.resources) {
    const v = plans.verify;
    $(".verify-result", root).innerHTML = `last run ${escapeHtml(v.checked_at || "")}: <span class="${v.status === "passed" ? "ok" : "err"}">${v.status}</span>`;
  }
}

async function openEnvironment(name) {
  state.current = name;
  stopPolling();
  await loadEnvironments();
  const root = $("#environment-detail");
  root.innerHTML = "";
  root.appendChild($("#detail-template").content.cloneNode(true));
  const env = state.environments.find(e => e.name === name);
  $(".env-name", root).textContent = name;
  $(".env-cloud", root).textContent = env.cloud;
  $(".env-scenario", root).textContent = env.scenario || env.tfvars;
  $(".env-state", root).textContent = env.resources
    ? `${env.resources} cloud resources deployed${env.stage && env.stage !== "complete" ? " (stage " + env.stage + ")" : ""}${env.workspace_url ? " · " + env.workspace_url : ""}`
    : "Nothing deployed yet.";
  let detail;
  try {
    detail = await api(`/api/environments/${name}`);
  } catch (error) { notice(error.message, true); return; }
  renderForm(root, detail);
  refreshPlans(root, env).catch(e => notice(e.message, true));

  const explainOut = $(".explain-output", root);
  const inspectOut = $(".inspect-output", root);
  const formEl = $(".env-form", root);

  async function save() {
    if (!detail.form) throw new Error("fix the file text first");
    detail = await api(`/api/environments/${name}`, { method: "PUT", body: { form: collectForm(root, detail) } });
    renderForm(root, detail);
    notice("Saved.");
  }
  formEl.addEventListener("submit", async (e) => { e.preventDefault(); try { await save(); } catch (err) { notice(err.message, true); } });
  $(".act-explain", root).addEventListener("click", async () => {
    try {
      if (detail.form) await save();
      explainOut.textContent = "Evaluating with Terraform...";
      renderExplain(explainOut, await api(`/api/environments/${name}/explain`));
    } catch (err) { notice(err.message, true); }
  });
  $(".toggle-raw", root).addEventListener("click", () => { const d = $("details.raw", root); d.open = !d.open; });
  $(".save-raw", root).addEventListener("click", async () => {
    try {
      detail = await api(`/api/environments/${name}`, { method: "PUT", body: { text: $('textarea[name="text"]', formEl).value } });
      renderForm(root, detail);
      notice("File saved.");
    } catch (err) { notice(err.message, true); }
  });

  $(".act-doctor", root).addEventListener("click", async () => {
    const out = $(".doctor-result", root);
    out.textContent = "checking...";
    try {
      const report = await api(`/api/environments/${name}/doctor`);
      const lines = (report.checks || []).map(c => `${c.id}: ${c.status}${c.detail ? " · " + c.detail : ""}`);
      inspectOut.textContent = lines.join("\n") + (report.warnings && report.warnings.length ? "\n\nWarnings:\n" + report.warnings.join("\n") : "");
      const setup = $(".act-setup", root);
      if (report.exit_code === 0) { out.innerHTML = '<span class="ok">ready</span>'; setup.classList.add("hidden"); }
      else if (report.exit_code === 10) { out.innerHTML = '<span class="err">browser login needed</span>'; setup.classList.remove("hidden"); }
      else if (report.exit_code === 11) { out.innerHTML = `<span class="err">${escapeHtml(report.next_action ? report.next_action.detail : "identity or account mismatch")}</span>`; setup.classList.add("hidden"); }
      else out.innerHTML = `<span class="err">${escapeHtml(report.next_action ? report.next_action.detail : report.stderr || "check failed")}</span>`;
    } catch (err) { out.textContent = err.message; }
  });
  $(".act-setup", root).addEventListener("click", () => startRun(root, env, { action: "setup" }, "A browser window opens for the login; come back here when it finishes."));
  $(".act-plan", root).addEventListener("click", async () => {
    try { if (detail.form) await save(); } catch (err) { notice(err.message, true); return; }
    startRun(root, env, { action: "plan" }, "Planning takes a few minutes.");
  });
  $(".act-apply", root).addEventListener("click", () => startRun(root, env, { action: "apply", confirm: "apply" }, "Applying; this takes 10 to 40 minutes."));
  $(".act-verify", root).addEventListener("click", () => startRun(root, env, { action: "verify" }, "Verifying; classic checks start a small cluster (about 5 minutes)."));
  $(".act-destroy-plan", root).addEventListener("click", () => startRun(root, env, { action: "destroy-plan" }, "Planning the destroy."));
  $(".act-destroy", root).addEventListener("click", () => startRun(root, env, { action: "destroy", confirm: $(".destroy-input", root).value }, "Destroying."));
  $(".act-status", root).addEventListener("click", async () => {
    const s = await api(`/api/environments/${name}/status`).catch(e => ({ error: e.message }));
    inspectOut.textContent = s.error ? s.error : `resources: ${s.resources}${s.stage ? " (stage " + s.stage + ")" : ""}\n${s.workspace_url ? "workspace: " + s.workspace_url + "\n" : ""}next: ${s.next_action.command || "nothing to do"}\n(${s.next_action.reason})`;
  });
  $(".act-output", root).addEventListener("click", async () => {
    const o = await api(`/api/environments/${name}/output`).catch(e => ({ error: e.message }));
    inspectOut.textContent = o.error ? o.error : (o.exit_code ? (o.stderr || "no state yet") : JSON.stringify(Object.fromEntries(Object.entries(o).filter(([k]) => k !== "exit_code").map(([k, v]) => [k, v.value])), null, 2));
  });
  $(".act-endpoints", root).addEventListener("click", async () => {
    inspectOut.textContent = "reading endpoint state...";
    const o = await api(`/api/environments/${name}/endpoints`).catch(e => ({ output: e.message }));
    inspectOut.textContent = o.output || "";
  });
}

/* ---------------- background runs ---------------- */

function stopPolling() { if (state.poll) { clearInterval(state.poll); state.poll = null; } }

async function startRun(root, env, body, hint) {
  const log = $(".log", root);
  const runState = $(".run-state", root);
  try {
    const run = await api(`/api/environments/${env.name}/run`, { method: "POST", body });
    state.run = run;
    log.textContent = "";
    runState.textContent = `${run.command} — running. ${hint || ""}`;
    let offset = 0;
    stopPolling();
    state.poll = setInterval(async () => {
      try {
        const current = await api(`/api/runs/${run.id}?offset=${offset}`);
        if (current.chunk) { log.textContent += current.chunk; log.scrollTop = log.scrollHeight; }
        offset = current.offset;
        if (current.exit_code !== null) {
          stopPolling();
          const ok = current.exit_code === 0;
          runState.innerHTML = `${escapeHtml(run.command)} — <span class="${ok ? "ok" : "err"}">${ok ? "finished" : "exit " + current.exit_code}</span>`;
          if (current.exit_code === 10) runState.innerHTML += ' · a browser login is needed: use "Check authentication" then "Log in".';
          if (current.exit_code === 11) runState.innerHTML += " · identity, account, or target mismatch: see the log.";
          if (current.exit_code === 13) runState.innerHTML += " · a network check failed: see the stage and hint in the log.";
          await loadEnvironments();
          const fresh = state.environments.find(e => e.name === env.name) || env;
          $(".env-state", root).textContent = fresh.resources ? `${fresh.resources} cloud resources deployed${fresh.workspace_url ? " · " + fresh.workspace_url : ""}` : "Nothing deployed yet.";
          refreshPlans(root, fresh).catch(e => notice(e.message, true));
        }
      } catch (err) { stopPolling(); notice(err.message, true); }
    }, 2000);
  } catch (err) { notice(err.message, true); }
}

/* ---------------- new environment ---------------- */

function syncTemplateOptions() {
  const formEl = $("#new-form");
  const cloud = formEl.cloud.value;
  const select = formEl.template;
  select.innerHTML = "";
  for (const t of state.templates.filter(t => t.cloud === cloud)) {
    const option = document.createElement("option");
    option.value = t.template;
    option.textContent = t.template;
    option.dataset.description = t.description;
    select.appendChild(option);
  }
  fillTargetSelect(formEl.target, cloud, Object.keys(state.targets).find(n => state.targets[n].cloud === cloud) || "");
  $("#template-description").textContent = select.selectedOptions[0] ? select.selectedOptions[0].dataset.description : "";
}
$("#new-form").cloud.addEventListener("change", syncTemplateOptions);
$("#new-form").template.addEventListener("change", () => { const o = $("#new-form").template.selectedOptions[0]; $("#template-description").textContent = o ? o.dataset.description : ""; });
$("#new-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  try {
    const created = await api("/api/environments", { method: "POST", body: { cloud: f.cloud.value, name: f.name.value.trim(), template: f.template.value, target: f.target.value || null } });
    notice(created.message.split("\n")[0]);
    f.name.value = "";
    show("environments");
    await openEnvironment(created.name);
  } catch (err) { notice(err.message, true); }
});

/* ---------------- targets ---------------- */

async function loadTargets() {
  const data = await api("/api/targets");
  state.targets = data.targets || {};
  const list = $("#target-list");
  const rows = Object.entries(state.targets).map(([name, t]) => `<tr><td><strong>${escapeHtml(name)}</strong><br><span class="muted">${escapeHtml(t.description || "")}</span></td><td><span class="badge ${t.cloud}">${t.cloud}</span></td><td class="muted">${escapeHtml(t.cloud === "aws" ? `aws ${t.aws_account_id || ""} · ${t.region || ""}` : `sub ${t.subscription_id || ""} · ${t.location || ""}`)}<br>${escapeHtml(t.databricks_account_id ? "databricks " + t.databricks_account_id : "")}${t.metastore ? "<br>metastore " + escapeHtml(t.metastore) : ""}</td></tr>`);
  list.innerHTML = `<h2>Targets</h2><p class="muted">Named accounts; environments refer to them instead of repeating IDs.</p>` + (rows.length ? `<table class="connectivity"><tbody>${rows.join("")}</tbody></table>` : '<p class="muted">No targets yet.</p>');
}
$("#target-form").cloud.addEventListener("change", (e) => {
  $$("#target-form [data-cloud]").forEach(d => d.classList.toggle("hidden", d.dataset.cloud !== e.target.value));
});
$("#target-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  const body = { name: f.name.value.trim(), cloud: f.cloud.value, description: f.description.value, classic_node_type: f.classic_node_type.value };
  if (body.cloud === "aws") Object.assign(body, { aws_account_id: f.aws_account_id.value, databricks_account_id: f.databricks_account_id.value, region: f.region.value, sso_start_url: f.sso_start_url.value, sso_region: f.sso_region.value, sso_role_name: f.sso_role_name.value, metastore: f.metastore.value });
  else Object.assign(body, { subscription_id: f.subscription_id.value, tenant_id: f.tenant_id.value, databricks_account_id: f.databricks_account_id_azure.value, location: f.location.value });
  try {
    const result = await api("/api/targets", { method: "POST", body });
    notice(result.message.split("\n")[0] || "Target added.");
    f.reset();
    await loadTargets();
    syncTemplateOptions();
  } catch (err) { notice(err.message, true); }
});

/* ---------------- boot ---------------- */

(async function boot() {
  try {
    state.manifest = await api("/api/manifest");
    const templates = await api("/api/templates");
    state.templates = templates.templates || [];
    await loadTargets();
    syncTemplateOptions();
    await loadEnvironments();
  } catch (err) { notice(err.message, true); }
})();
