// Vanilla JS, no build step, no framework -- matches this repo's
// established "hand-roll it, it's small enough" style (see
// generator/diagram/svg_primitives.py's docstring). Talks to
// generator/webapp/server.py's /api/preview, /api/generate, /api/compile.
"use strict";

const LAYOUT_HINTS = {
  breaker_and_half: "3 breakers per diameter, 2 taps per diameter -- needs an even tap count.",
  single_bus: "One bus, one breaker per tap -- the simplest arrangement.",
  main_and_transfer: "Main bus + transfer bus + one tie breaker.",
  ring_bus: "Breakers form a closed loop -- needs at least 3 taps to close it.",
};

let cidCounter = 0;
function newCid(prefix) {
  cidCounter += 1;
  return prefix + "-" + cidCounter;
}

const form = document.getElementById("station-form");
const vlList = document.getElementById("vl-list");
const vlTemplate = document.getElementById("vl-template");
const tapTemplate = document.getElementById("tap-template");
const lvOutputTemplate = document.getElementById("lv-output-template");

//--- building the dynamic card tree -----------------------------------------------------------

function addVoltageLevel() {
  const node = vlTemplate.content.firstElementChild.cloneNode(true);
  node.dataset.cid = newCid("vl");
  node.querySelector(".vl-layout").addEventListener("change", (e) => {
    node.querySelector(".layout-hint").textContent = LAYOUT_HINTS[e.target.value] || "";
    schedulePreview();
  });
  node.querySelector(".layout-hint").textContent = LAYOUT_HINTS[node.querySelector(".vl-layout").value];
  node.querySelector(".remove-vl").addEventListener("click", () => {
    node.remove();
    schedulePreview();
  });
  node.querySelector(".add-tap").addEventListener("click", () => {
    addTap(node.querySelector(".tap-list"));
    schedulePreview();
  });
  vlList.appendChild(node);
  return node;
}

function addTap(tapList) {
  const node = tapTemplate.content.firstElementChild.cloneNode(true);
  node.dataset.cid = newCid("tap");
  const kindSelect = node.querySelector(".tap-kind");
  const xfmrFields = node.querySelector(".xfmr-fields");
  kindSelect.addEventListener("change", () => {
    xfmrFields.hidden = kindSelect.value !== "transformer";
    schedulePreview();
  });
  node.querySelector(".remove-tap").addEventListener("click", () => {
    node.remove();
    schedulePreview();
  });
  node.querySelector(".add-lv-output").addEventListener("click", () => {
    addLvOutput(node.querySelector(".lv-output-list"));
    schedulePreview();
  });
  tapList.appendChild(node);
  return node;
}

function addLvOutput(list) {
  const node = lvOutputTemplate.content.firstElementChild.cloneNode(true);
  node.querySelector(".remove-output").addEventListener("click", () => {
    node.remove();
    schedulePreview();
  });
  list.appendChild(node);
  return node;
}

document.getElementById("add-vl").addEventListener("click", () => {
  addVoltageLevel();
  schedulePreview();
});

//--- collapsible "defaults" sections: small UX niceties that mirror the wizard's own conditional questions -----------------------------------------------------------

const curveSelect = document.querySelector(".ptoc-curve");
function updatePtocVisibility() {
  const isDefiniteTime = curveSelect.value === "DEFINITE_TIME";
  document.querySelector(".ptoc-time-multiplier").hidden = isDefiniteTime;
  document.querySelector(".ptoc-definite-time").hidden = !isDefiniteTime;
}
curveSelect.addEventListener("change", updatePtocVisibility);
updatePtocVisibility();

const autoUvCheckbox = document.querySelector(".auto-uv");
function updateUvRatioVisibility() {
  document.querySelector(".undervoltage-ratio").hidden = !autoUvCheckbox.checked;
}
autoUvCheckbox.addEventListener("change", updateUvRatioVisibility);
updateUvRatioVisibility();

const compileNowCheckbox = document.getElementById("compile-now");
compileNowCheckbox.addEventListener("change", () => {
  document.getElementById("compile-dir-row").hidden = !compileNowCheckbox.checked;
});

//--- collecting form state into the JSON shape generator/webapp/formdata.py expects -----------------------------------------------------------

function numOrNull(el) {
  return el.value === "" ? null : Number(el.value);
}

function collectDefaults(sectionPrefix) {
  const out = {};
  for (const el of form.querySelectorAll(`[data-field^="${sectionPrefix}."]`)) {
    const field = el.dataset.field.slice(sectionPrefix.length + 1);
    let value;
    if (el.type === "checkbox") value = el.checked;
    else if (el.type === "number") value = numOrNull(el);
    else value = el.value === "" ? null : el.value;
    out[field] = value;
  }
  return out;
}

function collectLvOutputs(list) {
  return Array.from(list.querySelectorAll(".lv-output-row")).map((row) => ({
    name: row.querySelector(".output-name").value.trim(),
    kind: row.querySelector(".output-kind").value,
  }));
}

function collectTap(row) {
  const kind = row.querySelector(".tap-kind").value;
  const tap = { _cid: row.dataset.cid, name: row.querySelector(".tap-name").value.trim(), kind };
  if (kind === "transformer") {
    tap.transformer = {
      name: row.querySelector(".xfmr-name").value.trim(),
      lv_kv: numOrNull(row.querySelector(".xfmr-lv-kv")),
      lv_outputs: collectLvOutputs(row.querySelector(".lv-output-list")),
    };
  }
  return tap;
}

function collectVoltageLevel(card) {
  return {
    _cid: card.dataset.cid,
    vl_name: card.querySelector(".vl-name").value.trim(),
    kv: numOrNull(card.querySelector(".vl-kv")),
    layout_kind: card.querySelector(".vl-layout").value,
    taps: Array.from(card.querySelectorAll(".tap-list > .tap-row")).map(collectTap),
  };
}

function collectFormState() {
  return {
    name: document.getElementById("station-name").value.trim(),
    voltage_levels: Array.from(vlList.querySelectorAll(".vl-card")).map(collectVoltageLevel),
    protection: collectDefaults("protection"),
    network: collectDefaults("network"),
    ied_settings: collectDefaults("ied_settings"),
    scada: collectDefaults("scada"),
  };
}

//--- live preview -----------------------------------------------------------

function clearErrors() {
  document.querySelectorAll(".error").forEach((el) => { el.textContent = ""; });
}

function paintErrors(errors) {
  clearErrors();
  const nameError = document.querySelector('[data-error-for="name"]');
  if (errors.name) nameError.textContent = errors.name;

  for (const card of vlList.querySelectorAll(".vl-card")) {
    const msg = errors.voltage_levels && errors.voltage_levels[card.dataset.cid];
    if (msg) card.querySelector('[data-role="vl-error"]').textContent = msg;
  }
  for (const row of vlList.querySelectorAll(".tap-row")) {
    const msg = errors.transformers && errors.transformers[row.dataset.cid];
    if (msg) row.querySelector('[data-role="tap-error"]').textContent = msg;
  }
}

function renderSummary(summary) {
  const el = document.getElementById("summary");
  if (!summary.voltage_levels.length) {
    el.innerHTML = '<p class="placeholder">Add a voltage level to see a summary.</p>';
    return;
  }
  const rows = summary.voltage_levels.map((vl) =>
    `<li>${vl.vl_name}: ${vl.kv}kV, ${vl.layout_kind}, ${vl.taps} tap(s), ${vl.breakers} breaker(s), ${vl.disconnects} disconnect(s)</li>`
  ).join("");
  const xfmrRows = summary.transformers.map((x) =>
    `<li>${x.name}: HV tap in ${x.hv_vl} (${x.hv_kv}kV) -&gt; LV ${x.lv_kv}kV, ${x.lv_outputs} output(s)</li>`
  ).join("");
  el.innerHTML = `
    <h2>Summary</h2>
    <ul>${rows}</ul>
    ${summary.transformers.length ? `<h3>Transformers</h3><ul>${xfmrRows}</ul>` : ""}
    <p>Total breaker IEDs: ${summary.total_breakers}<br>
       Total isolating disconnects: ${summary.total_disconnects}<br>
       SCADA IED: ${summary.scada_ied_name}</p>
  `;
}

function renderDiagram(svg) {
  const el = document.getElementById("diagram-preview");
  el.innerHTML = svg || '<p class="placeholder">Add a voltage level to see the one-line diagram.</p>';
}

let previewTimer = null;
function schedulePreview() {
  if (previewTimer) clearTimeout(previewTimer);
  previewTimer = setTimeout(runPreview, 350);
}

async function runPreview() {
  const res = await fetch("/api/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(collectFormState()),
  });
  const data = await res.json();
  renderDiagram(data.svg);
  renderSummary(data.summary);
  paintErrors(data.errors);
}

form.addEventListener("input", schedulePreview);
form.addEventListener("change", schedulePreview);

//--- generate / compile -----------------------------------------------------------

function setStatus(html) {
  document.getElementById("generate-status").innerHTML = html;
}

async function generate(overwrite) {
  const payload = collectFormState();
  payload.out_dir = document.getElementById("out-dir").value.trim() || "scl";
  payload.overwrite = !!overwrite;

  const res = await fetch("/api/generate", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json();

  if (res.status === 409) {
    if (confirm(data.paths.join(", ") + " already exist(s) -- overwrite?")) {
      return generate(true);
    }
    setStatus("<p>Not overwritten.</p>");
    return;
  }
  if (res.status === 400) {
    paintErrors(data.errors || {});
    setStatus('<p class="error-text">Fix the errors above before generating.</p>');
    return;
  }
  if (!res.ok) {
    setStatus('<p class="error-text">' + (data.error || "generate failed") + "</p>");
    return;
  }

  let html = `<p>wrote ${data.scdPath}</p><p>wrote ${data.svgPath}</p>`;
  html += data.xsdOk ? "<p>XSD validation: OK</p>" : `<p class="error-text">XSD validation FAILED: ${data.xsdError}</p>`;
  setStatus(html);

  if (compileNowCheckbox.checked) {
    const compileRes = await fetch("/api/compile", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        scd_path: data.scdPath,
        compiled_dir: document.getElementById("compile-dir").value.trim() || "etc/generated",
      }),
    });
    const compileData = await compileRes.json();
    if (compileRes.ok) {
      html += "<p>compiled:</p><ul>" + compileData.files.map((f) => `<li>${f}</li>`).join("") + "</ul>";
    } else {
      html += `<p class="error-text">compile failed: ${compileData.error}</p>`;
    }
    setStatus(html);
  }
}

document.getElementById("generate-btn").addEventListener("click", () => generate(false));

//--- initial state: one blank voltage level to start from, matching the wizard's own "voltage level 1" opening prompt -----------------------------------------------------------

addVoltageLevel();
schedulePreview();
