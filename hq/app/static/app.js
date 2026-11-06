/* MESH HQ console. Plain JS, no build step. Polls the admin API every few seconds. */
(() => {
  "use strict";

  // ------------------------------------------------------------------ helpers

  const $ = (sel, root = document) => root.querySelector(sel);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
    del(k) { try { localStorage.removeItem(k); } catch { /* private mode */ } },
  };
  let token = store.get("hq_token") || "";
  let auditor = store.get("hq_auditor") || "";

  const PR = { t1: "T1 Immediate", t2: "T2 Delayed", t3: "T3 Minimal", t4: "T4 Expectant" };
  const prChip = (p, short) => p ? `<span class="chip pr ${esc(p)}">${short ? esc(p.toUpperCase()) : esc(PR[p] || p)}</span>` : "";
  const KIND = { triage: "Conflicting triage", venue: "Patient at two venues", duplicate: "Duplicate registration" };
  const TYPE_ICON = {
    PatientRegistered: ["＋", ""], PriorityChanged: ["⚑", ""], ObservationAdded: ["♥", ""],
    DiagnosisRecorded: ["Dx", "clin"], RemediationRecorded: ["Tx", "clin"], FollowUpRecommended: ["↻", "clin"],
    StockCounted: ["▤", "inv"], StockAdjusted: ["±", "inv"], SupplyRequested: ["⇪", "inv"],
    AnnouncementPosted: ["✉", ""], MessageSent: ["✎", ""],
  };
  const icon = (type) => { const [g, c] = TYPE_ICON[type] || ["•", ""]; return `<span class="ico ${c}">${g}</span>`; };

  function ago(ms) {
    const s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 45) return "just now";
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    return `${Math.round(s / 86400)} d ago`;
  }
  const clock = (ms) => new Date(ms).toLocaleString([], { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });

  function toast(msg) {
    const t = $("#toast");
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(toast._t);
    toast._t = setTimeout(() => { t.hidden = true; }, 3200);
  }

  async function api(path, opts = {}) {
    const res = await fetch(path, {
      ...opts,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        "X-Auditor": auditor,
        ...(opts.headers || {}),
      },
    });
    if (res.status === 401) { showLogin(); throw new Error("Signed out"); }
    if (!res.ok) {
      let detail = res.statusText;
      try { detail = (await res.json()).detail || detail; } catch { /* not JSON */ }
      throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
    }
    return res.json();
  }

  /** Small form dialog. fields: [{name, label, type, value, options}] → resolves with values or null. */
  function dialog(title, fields, submitLabel = "Confirm") {
    return new Promise((resolve) => {
      const back = $("#dialog");
      const form = $("#dialog-form");
      form.innerHTML = `<h2>${esc(title)}</h2>` + fields.map((f) => f.type === "textarea"
        ? `<label>${esc(f.label)}<textarea name="${f.name}">${esc(f.value || "")}</textarea></label>`
        : `<label>${esc(f.label)}<input name="${f.name}" value="${esc(f.value || "")}"></label>`).join("") +
        `<div class="toolbar" style="justify-content:flex-end;margin:0"><button type="button" class="btn" data-cancel>Cancel</button>
         <button class="btn primary" type="submit">${esc(submitLabel)}</button></div>`;
      back.hidden = false;
      const done = (v) => { back.hidden = true; form.onsubmit = null; resolve(v); };
      form.querySelector("[data-cancel]").onclick = () => done(null);
      form.onsubmit = (e) => { e.preventDefault(); done(Object.fromEntries(new FormData(form))); };
      form.querySelector("input,textarea")?.focus();
    });
  }

  // ------------------------------------------------------------------ login

  function showLogin(msg) {
    $("#login").hidden = false;
    $("#login-error").hidden = !msg;
    $("#login-error").textContent = msg || "";
    const f = $("#login-form");
    f.auditor.value = auditor;
    (auditor ? f.token : f.auditor).focus();
  }

  $("#login-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = e.target;
    token = f.token.value.trim();
    auditor = f.auditor.value.trim();
    try {
      await api("/api/admin/check");
      store.set("hq_token", token);
      store.set("hq_auditor", auditor);
      $("#login").hidden = true;
      $("#auditor-name").textContent = auditor;
      route();
    } catch (err) {
      showLogin(err.message === "Signed out" ? "That token isn't right." : err.message);
    }
  });

  $("#logout").onclick = () => { token = ""; store.del("hq_token"); showLogin(); };

  // ------------------------------------------------------------------ views

  const views = {};
  let current = null;
  let seenFeed = null;

  views.overview = {
    render(root) {
      root.innerHTML = `
        <div class="head"><div><h1>Overview</h1><div class="sub muted">Live reports from field clusters, verified on arrival</div></div></div>
        <div class="kpis" data-slot="kpis"></div>
        <div class="grid cols-2">
          <section class="card"><h2>Incoming reports <span class="chip line" data-slot="count"></span></h2><ul class="feed" data-slot="feed"></ul></section>
          <div class="grid" style="align-content:start">
            <section class="card"><h2>Open conflicts</h2><div data-slot="conflicts"></div></section>
            <section class="card"><h2>Uplink gateways</h2><div data-slot="gateways"></div></section>
          </div>
        </div>`;
    },
    async refresh(root) {
      const [o, feed, conflicts] = await Promise.all([api("/api/admin/overview"), api("/api/admin/feed?limit=60"), api("/api/admin/conflicts")]);
      const tri = Object.entries(o.by_priority).map(([k, v]) => `<span style="background:var(--${k})">${k.toUpperCase()} ${v}</span>`).join("");
      $('[data-slot="kpis"]', root).innerHTML = `
        <a class="kpi" href="#/patients"><div class="v">${o.patients}</div><div class="l">Patients in care</div><div class="tri">${tri}</div></a>
        <a class="kpi ${o.open_conflicts ? "alert" : ""}" href="#/conflicts"><div class="v">${o.open_conflicts}</div><div class="l">Conflicts to audit</div></a>
        <a class="kpi ${o.pending_requests ? "alert" : ""}" href="#/inventory"><div class="v">${o.pending_requests}</div><div class="l">Supply requests pending</div></a>
        <a class="kpi" href="#/inventory"><div class="v">${o.low_stock}</div><div class="l">Items at or below minimum</div></a>
        <div class="kpi"><div class="v">${o.gateways.filter((g) => g.online).length}<span class="muted" style="font-size:16px"> / ${o.gateways.length}</span></div><div class="l">Gateways online · ${o.devices} devices known</div></div>`;
      $('[data-slot="count"]', root).textContent = `${o.events} signed events`;
      const firstLoad = seenFeed === null;
      seenFeed = seenFeed || new Set();
      $('[data-slot="feed"]', root).innerHTML = feed.length ? feed.map((f) => {
        const isNew = !firstLoad && !seenFeed.has(f.id);
        seenFeed.add(f.id);
        const link = f.pid ? `href="#/patients/${encodeURIComponent(f.pid)}"` : "";
        return `<li class="${isNew ? "new" : ""}">${icon(f.type)}
          <div><div class="t">${link ? `<a ${link} style="text-decoration:none">${esc(f.summary)}</a>` : esc(f.summary)}</div>
          <div class="m">${esc(f.author.name)} · ${esc(f.author.roles.join(", "))}${f.fac ? ` · ${esc(f.fac)}` : ""}${f.gateway ? ` · via ${esc(f.gateway)}` : ""}</div></div>
          <div class="when" title="Signed ${esc(clock(f.ts))}">${ago(f.received_at)}</div></li>`;
      }).join("") : `<li class="empty" style="display:block">No reports yet. Turn on Uplink on a phone and set this server's address.</li>`;
      const open = conflicts.filter((c) => c.status === "open");
      $('[data-slot="conflicts"]', root).innerHTML = open.length ? open.slice(0, 6).map((c) => `
        <a class="list-item" href="#/conflicts/${c.id}"><span class="chip warn">${esc(KIND[c.kind] || c.kind)}</span>
        <span class="grow ellipsis">${esc(c.summary)}</span><span class="muted small">${ago(c.created_at)}</span></a>`).join("")
        : `<div class="empty">Nothing to audit.</div>`;
      $('[data-slot="gateways"]', root).innerHTML = o.gateways.length ? o.gateways.map((g) => `
        <div class="list-item"><span class="dot ${g.online ? "on" : ""}"></span>
        <span class="grow"><b>${esc(g.name)}</b><div class="muted small">${esc(g.fac || "No facility set")} · ${esc(g.dev)} · ${g.uploads} events</div></span>
        <span class="muted small">${ago(g.last_seen)}</span></div>`).join("")
        : `<div class="empty">No phone has synced yet.</div>`;
    },
  };

  views.patients = {
    state: { q: "", fac: "", pr: "" },
    render(root) {
      root.innerHTML = `
        <div class="head"><div><h1>Patients</h1><div class="sub muted">Every patient reported by any cluster</div></div></div>
        <div class="toolbar">
          <input type="search" placeholder="Search ID, name, ID tag or description" data-f="q" style="flex:1;min-width:220px">
          <select data-f="fac"><option value="">All facilities</option></select>
          <select data-f="pr"><option value="">All priorities</option>${Object.entries(PR).map(([k, v]) => `<option value="${k}">${v}</option>`).join("")}</select>
        </div>
        <section class="card table-wrap"><table><thead><tr><th>Patient</th><th>Priority</th><th>Facility</th><th>Care stage</th><th>Updated</th><th></th></tr></thead><tbody data-slot="rows"></tbody></table></section>`;
      root.querySelectorAll("[data-f]").forEach((el) => {
        el.value = this.state[el.dataset.f];
        el.oninput = () => { this.state[el.dataset.f] = el.value; this.refresh(root, true); };
      });
    },
    async refresh(root, cached) {
      if (!cached || !this.data) this.data = await api("/api/admin/patients");
      const { q, fac, pr } = this.state;
      const sel = $('[data-f="fac"]', root);
      const facs = [...new Set(this.data.flatMap((p) => p.facilities.length ? p.facilities : [p.fac]).filter(Boolean))].sort();
      if (sel.options.length - 1 !== facs.length) {
        sel.innerHTML = `<option value="">All facilities</option>` + facs.map((f) => `<option>${esc(f)}</option>`).join("");
        sel.value = fac;
      }
      const ql = q.toLowerCase();
      const rows = this.data.filter((p) =>
        (!ql || [p.pid, p.name, p.ident, p.desc].some((x) => (x || "").toLowerCase().includes(ql))) &&
        (!fac || p.fac === fac || p.facilities.includes(fac)) && (!pr || p.priority === pr));
      $('[data-slot="rows"]', root).innerHTML = rows.length ? rows.map((p) => `
        <tr class="clickable" data-pid="${esc(p.pid)}">
          <td><b class="mono">${esc(p.pid)}</b>${p.voided ? ' <span class="chip void">Voided</span>' : ""}<div class="muted small">${esc([p.name, p.ident].filter(Boolean).join(" · ") || p.desc)}</div></td>
          <td>${prChip(p.priority)}</td>
          <td>${esc(p.fac || "-")}<div class="muted small">${esc(p.loc)}</div></td>
          <td><div class="stage">${[0, 1, 2, 3, 4].map((i) => `<i class="${i <= p.stage ? "on" : ""}"></i>`).join("")}</div></td>
          <td class="muted small">${ago(p.updated)}</td>
          <td>${p.open_conflicts ? `<span class="chip warn">${p.open_conflicts} conflict${p.open_conflicts > 1 ? "s" : ""}</span>` : ""}</td>
        </tr>`).join("") : `<tr><td colspan="6" class="empty">No patients match.</td></tr>`;
      root.querySelectorAll("tr[data-pid]").forEach((tr) => { tr.onclick = () => { location.hash = `#/patients/${encodeURIComponent(tr.dataset.pid)}`; }; });
    },
  };

  views.patient = {
    render(root, pid) { this.pid = pid; root.innerHTML = `<div data-slot="body"><p class="muted">Loading…</p></div>`; },
    async refresh(root) {
      const [list, conflicts] = await Promise.all([api("/api/admin/patients"), api("/api/admin/conflicts")]);
      const p = list.find((x) => x.pid === this.pid);
      const body = $('[data-slot="body"]', root);
      if (!p) { body.innerHTML = `<p class="empty">Patient ${esc(this.pid)} not found.</p>`; return; }
      const mine = conflicts.filter((c) => c.reports.some((r) => r.pid === p.pid));
      body.innerHTML = `
        <div class="head"><div><a href="#/patients" class="muted small">← Patients</a><h1 class="mono" style="margin-top:6px">${esc(p.pid)}</h1>
          <div class="sub muted">${esc([p.name, p.ident && `ID ${p.ident}`].filter(Boolean).join(" · ") || "Name not recorded")}</div></div>
          <div class="spacer"></div>${prChip(p.priority)}${p.voided ? '<span class="chip void">Registration voided by audit</span>' : ""}</div>
        <div class="grid cols-2">
          <section class="card"><h2>Record · ${p.entries.length} signed entries</h2>
            <ul class="timeline">${p.entries.slice().reverse().map((e) => `
              <li>${icon(e.type)}<div class="entry ${e.voided ? "voided" : ""}">
                <div class="top"><b>${esc(e.label)}</b>${e.voided ? '<span class="chip void">Overruled by audit</span>' : ""}<span class="grow"></span><span class="muted small">${esc(clock(e.ts))}</span></div>
                <p class="txt">${esc(e.text)}</p>
                ${Object.keys(e.fields).length ? `<div class="fields">${Object.entries(e.fields).map(([k, v]) => `<span>${esc(k)} <b>${esc(v)}</b></span>`).join("")}</div>` : ""}
                <div class="meta"><span>${esc(e.author.name)} · ${esc(e.author.roles.join(", "))}</span>${e.fac ? `<span>${esc(e.fac)}</span>` : ""}<span>device ${esc(e.dev)} #${e.seq}</span><span class="verified">✓ signature verified</span></div>
              </div></li>`).join("")}</ul></section>
          <div class="grid" style="align-content:start">
            <section class="card"><h2>Summary</h2>
              <p style="margin:0 0 10px;line-height:1.45">${esc(p.desc)}</p>
              <div class="meta" style="flex-direction:column;gap:6px">
                <span>Arrived ${esc(clock(p.arrival))} (${ago(p.arrival)})</span>
                <span>Facility: <b>${esc(p.fac || "-")}</b> · ${esc(p.loc)}</span>
                ${p.facilities.length > 1 ? `<span>Reported from: <b>${esc(p.facilities.join(", "))}</b></span>` : ""}
              </div></section>
            <section class="card"><h2>Audit</h2>${mine.length ? mine.map((c) => `
              <a class="list-item" href="#/conflicts/${c.id}"><span class="chip ${c.status === "open" ? "warn" : "ok"}">${c.status === "open" ? "Open" : "Resolved"}</span>
              <span class="grow">${esc(KIND[c.kind] || c.kind)}<div class="muted small">${esc(c.summary)}</div></span></a>`).join("") : `<div class="empty">No conflicts for this patient.</div>`}
            </section>
          </div>
        </div>`;
    },
  };

  views.conflicts = {
    state: { tab: "open" },
    render(root) {
      root.innerHTML = `
        <div class="head"><div><h1>Conflicts</h1><div class="sub muted">Reports that disagree, held for a human auditor</div></div><div class="spacer"></div>
          <div class="seg" data-slot="tabs"><button data-t="open">Open</button><button data-t="resolved">Resolved</button></div></div>
        <section class="card" data-slot="list"></section>`;
      root.querySelectorAll("[data-t]").forEach((b) => { b.onclick = () => { this.state.tab = b.dataset.t; this.refresh(root, true); }; });
    },
    async refresh(root, cached) {
      if (!cached || !this.data) this.data = await api("/api/admin/conflicts");
      root.querySelectorAll("[data-t]").forEach((b) => b.classList.toggle("on", b.dataset.t === this.state.tab));
      const list = this.data.filter((c) => c.status === this.state.tab);
      $('[data-slot="list"]', root).innerHTML = list.length ? list.map((c) => `
        <a class="list-item" href="#/conflicts/${c.id}">
          <span class="chip ${c.status === "open" ? "warn" : "ok"}">${esc(KIND[c.kind] || c.kind)}</span>
          <span class="grow"><b>${esc(c.summary)}</b><div class="muted small">#${c.id} · flagged ${ago(c.created_at)}${c.status === "resolved" ? ` · ${esc(decisionText(c))} by ${esc(c.by)}` : ""}</div></span>
          <span class="muted">›</span></a>`).join("")
        : `<div class="empty">${this.state.tab === "open" ? "No open conflicts. New ones appear here as reports arrive." : "No resolved conflicts yet."}</div>`;
    },
  };

  const decisionText = (c) => ({ a: "Kept report A", b: "Kept report B", both: "Kept both" }[c.decision] || "");

  function reportValue(r) {
    if (r.type === "PatientRegistered") return r.fields.Priority || r.text;
    if (r.type === "PriorityChanged") return r.text;
    return r.label;
  }

  views.conflict = {
    render(root, id) { this.id = Number(id); this.drawn = false; root.innerHTML = `<div data-slot="body"><p class="muted">Loading…</p></div>`; },
    async refresh(root) {
      const list = await api("/api/admin/conflicts");
      const c = list.find((x) => x.id === this.id);
      const body = $('[data-slot="body"]', root);
      if (!c) { body.innerHTML = `<p class="empty">Conflict #${this.id} not found.</p>`; return; }
      if (this.drawn && c.status === this.status) return; // keep the auditor's half-finished form
      this.drawn = true;
      this.status = c.status;
      const [a, b] = c.reports;
      const cls = (side) => c.status !== "resolved" ? "" : (c.decision === "both" || c.decision === side ? "keep" : "drop");
      const card = (r, side) => r ? `
        <div class="report ${cls(side)}"><div class="tag">REPORT ${side.toUpperCase()}</div>
          <div class="val">${esc(reportValue(r))}</div>
          <div class="muted">${esc(r.text)}</div>
          <dl>
            <dt>Patient</dt><dd><a href="#/patients/${encodeURIComponent(r.pid)}">${esc(r.pid)}</a></dd>
            <dt>Type</dt><dd>${esc(r.label)}</dd>
            <dt>Reported by</dt><dd>${esc(r.author.name)}<div class="muted small">${esc(r.author.roles.join(", "))}</div></dd>
            <dt>Facility</dt><dd>${esc(r.fac || "-")}${r.fields.Location ? ` · ${esc(r.fields.Location)}` : ""}</dd>
            <dt>Signed at</dt><dd>${esc(clock(r.ts))}</dd>
            <dt>Received</dt><dd>${esc(clock(r.received_at))}${r.gateway ? ` via ${esc(r.gateway)}` : ""}</dd>
            <dt>Device</dt><dd class="mono">${esc(r.dev)} #${r.seq}</dd>
            <dt>Signature</dt><dd class="verified">✓ verified</dd>
          </dl></div>` : `<div class="report"><p class="muted">Report missing</p></div>`;
      const help = {
        triage: "Two devices set different triage priorities for the same patient within a short window.",
        venue: "The same patient was reported from two facilities. One patient cannot be at two venues at once.",
        duplicate: "The same person (ID tag) was registered as two separate patients at one facility.",
      }[c.kind] || "";
      body.innerHTML = `
        <div class="head"><div><a href="#/conflicts" class="muted small">← Conflicts</a><h1 style="margin-top:6px">${esc(KIND[c.kind] || c.kind)}</h1>
          <div class="sub muted">#${c.id} · ${esc(c.summary)}</div></div></div>
        <p class="banner warn" style="margin:0 0 16px">${esc(help)}</p>
        <div class="versus">${card(a, "a")}${card(b, "b")}</div>
        <div class="section-label">Decision</div>
        ${c.status === "resolved" ? `
          <div class="banner ok"><div><b>${esc(decisionText(c))}</b> · finalised by ${esc(c.by)} ${ago(c.resolved_at)}
          ${c.note ? `<div class="muted" style="margin-top:4px">${esc(c.note)}</div>` : ""}
          <div class="muted small" style="margin-top:4px">Sent to every cluster as an HQ-signed audit decision.</div></div></div>`
        : `<form data-slot="decide" class="card">
            <div class="decide">
              <label><input type="radio" name="d" value="a" required><span>Keep A only<small>Report B is overruled on every device</small></span></label>
              <label><input type="radio" name="d" value="b"><span>Keep B only<small>Report A is overruled on every device</small></span></label>
              <label><input type="radio" name="d" value="both"><span>Keep both<small>Both stay valid (for example a real transfer)</small></span></label>
            </div>
            <label>Audit note<textarea name="note" placeholder="Reason for the decision (shown to the field)"></textarea></label>
            <div class="toolbar" style="margin:14px 0 0;justify-content:flex-end"><button class="btn primary" type="submit">Finalise decision</button></div>
          </form>`}`;
      const form = $('[data-slot="decide"]', body);
      if (form) {
        form.onsubmit = async (e) => {
          e.preventDefault();
          const fd = new FormData(form);
          const btn = form.querySelector("button[type=submit]");
          btn.disabled = true;
          try {
            await api(`/api/admin/conflicts/${c.id}/resolve`, { method: "POST", body: JSON.stringify({ decision: fd.get("d"), note: fd.get("note") || "" }) });
            toast("Decision finalised and queued for the field");
            this.drawn = false;
            this.refresh(root);
            poll();
          } catch (err) { toast(err.message); btn.disabled = false; }
        };
      }
    },
  };

  views.broadcast = {
    render(root) {
      root.innerHTML = `
        <div class="head"><div><h1>Broadcast</h1><div class="sub muted">HQ-signed announcements go to every uplink phone, which floods them over Bluetooth to the rest of its cluster</div></div></div>
        <div class="grid cols-half">
          <form class="card grid" data-slot="form" style="align-content:start">
            <h2>New announcement</h2>
            <label>Title<input name="title" maxlength="120" required placeholder="e.g. Casevac window 1430–1500"></label>
            <label>Message<textarea name="body" maxlength="2000" required></textarea></label>
            <label class="check"><input type="checkbox" name="urgent"> Mark as urgent (pinned on every device)</label>
            <div><button class="btn primary" type="submit">Sign and broadcast</button></div>
          </form>
          <section class="card"><h2>Announcements</h2><div data-slot="list"></div></section>
        </div>`;
      const form = $('[data-slot="form"]', root);
      form.onsubmit = async (e) => {
        e.preventDefault();
        const fd = new FormData(form);
        try {
          await api("/api/admin/announcements", { method: "POST", body: JSON.stringify({ title: fd.get("title"), body: fd.get("body"), urgent: fd.get("urgent") === "on" }) });
          form.reset();
          toast("Broadcast queued. Phones pick it up on their next sync.");
          this.refresh(root);
        } catch (err) { toast(err.message); }
      };
    },
    async refresh(root) {
      const list = await api("/api/admin/announcements");
      $('[data-slot="list"]', root).innerHTML = list.length ? list.map((a) => `
        <div class="ann"><div class="top">${a.urgent ? '<span class="chip warn">URGENT</span>' : ""}
          ${a.from_hq ? '<span class="chip pr t4">HQ</span>' : `<span class="chip line">Field · ${esc(a.author.name)}</span>`}
          <span class="grow"></span><span class="muted small">${ago(a.ts)}</span></div>
          <b>${esc(a.title)}</b><p>${esc(a.body)}</p>
          ${a.from_hq ? `<div class="muted small">${a.delivered_via.length ? `✓ Delivered via ${esc(a.delivered_via.join(", "))}` : "Waiting for an uplink phone to sync"}</div>` : ""}
        </div>`).join("") : `<div class="empty">No announcements yet.</div>`;
    },
  };

  views.inventory = {
    state: { fac: "" },
    render(root) {
      root.innerHTML = `
        <div class="head"><div><h1>Inventory</h1><div class="sub muted">Stock counts from each facility and supply requests to HQ</div></div><div class="spacer"></div>
          <select data-slot="fac"></select></div>
        <section class="card"><h2>Supply requests</h2><div class="table-wrap"><table><thead><tr><th>Request</th><th>Facility</th><th>Urgency</th><th>Requested</th><th>Status</th><th></th></tr></thead><tbody data-slot="req"></tbody></table></div></section>
        <div class="section-label">Stock</div>
        <div data-slot="stock" class="grid"></div>`;
      const sel = $('[data-slot="fac"]', root);
      sel.onchange = () => { this.state.fac = sel.value; this.refresh(root, true); };
    },
    async refresh(root, cached) {
      if (!cached || !this.data) this.data = await api("/api/admin/inventory");
      const { facilities, requests } = this.data;
      const facs = [...new Set([...Object.keys(facilities), ...requests.map((r) => r.fac)])].sort();
      const sel = $('[data-slot="fac"]', root);
      const opts = `<option value="">All facilities</option>` + facs.map((f) => `<option>${esc(f)}</option>`).join("");
      if (sel.dataset.opts !== opts) { sel.innerHTML = opts; sel.dataset.opts = opts; }
      sel.value = this.state.fac;
      const show = (f) => !this.state.fac || f === this.state.fac;
      const req = requests.filter((r) => show(r.fac));
      $('[data-slot="req"]', root).innerHTML = req.length ? req.map((r) => `
        <tr><td><b>${esc(r.qty)} ${esc(r.unit)} ${esc(r.item)}</b>${r.note ? `<div class="muted small">${esc(r.note)}</div>` : ""}
          ${r.history.length ? `<div class="muted small">${r.history.map((h) => `${esc(h.status)} by ${esc(h.by)}${h.note ? `: ${esc(h.note)}` : ""}`).join("<br>")}</div>` : ""}</td>
          <td>${esc(r.fac)}<div class="muted small">${esc(r.by)}</div></td>
          <td>${r.urgency === "urgent" ? '<span class="chip warn">Urgent</span>' : '<span class="chip line">Routine</span>'}</td>
          <td class="muted small">${ago(r.ts)}</td>
          <td><span class="chip st-${esc(r.status)}">${esc(r.status)}</span></td>
          <td style="white-space:nowrap">${r.status === "pending" ? `<button class="btn sm dark" data-act="approved" data-rid="${esc(r.rid)}">Approve</button>
              <button class="btn sm danger" data-act="denied" data-rid="${esc(r.rid)}">Deny</button>`
            : r.status === "approved" ? `<button class="btn sm primary" data-act="dispatched" data-rid="${esc(r.rid)}">Mark dispatched</button>` : ""}</td></tr>`).join("")
        : `<tr><td colspan="6" class="empty">No supply requests.</td></tr>`;
      root.querySelectorAll("[data-act]").forEach((b) => {
        b.onclick = async () => {
          const label = { approved: "Approve request", denied: "Deny request", dispatched: "Mark as dispatched" }[b.dataset.act];
          const v = await dialog(label, [{ name: "note", label: "Note to the facility (optional)", type: "textarea" }], label);
          if (!v) return;
          try {
            await api(`/api/admin/requests/${encodeURIComponent(b.dataset.rid)}/status`, { method: "POST", body: JSON.stringify({ status: b.dataset.act, note: v.note || "" }) });
            toast("Update signed and queued for the facility");
            this.refresh(root);
          } catch (err) { toast(err.message); }
        };
      });
      const stock = Object.entries(facilities).filter(([f]) => show(f));
      $('[data-slot="stock"]', root).innerHTML = stock.length ? stock.map(([f, items]) => `
        <section class="card table-wrap"><h2>${esc(f)} <span class="chip line">${items.length} items</span>
          ${items.some((i) => i.min && i.qty <= i.min) ? `<span class="chip warn">${items.filter((i) => i.min && i.qty <= i.min).length} low</span>` : ""}</h2>
          <table><thead><tr><th>Item</th><th>Category</th><th>On hand</th><th>Minimum</th><th>Last update</th></tr></thead><tbody>
          ${items.map((i) => `<tr class="${i.min && i.qty <= i.min ? "low" : ""}"><td><b>${esc(i.item)}</b></td><td>${esc(i.category)}</td>
            <td class="mono"><b>${esc(i.qty)}</b> ${esc(i.unit)}</td><td class="mono">${i.min ? esc(i.min) : "-"}</td>
            <td class="muted small">${ago(i.updated)} · ${esc(i.by)}</td></tr>`).join("")}
          </tbody></table></section>`).join("") : `<div class="card empty">No stock counts reported yet.</div>`;
    },
  };

  // ------------------------------------------------------------------ router + polling

  function route() {
    if (!token) return showLogin();
    const [, page = "overview", arg] = (location.hash || "#/overview").split("/");
    const name = arg && page === "patients" ? "patient" : arg && page === "conflicts" ? "conflict" : page;
    const view = views[name] || views.overview;
    document.querySelectorAll("[data-nav]").forEach((a) => a.classList.toggle("active", a.dataset.nav === page));
    current = { view, root: $("#view") };
    if (view.data) view.data = null;
    view.render(current.root, arg && decodeURIComponent(arg));
    poll();
  }

  async function poll() {
    if (!token || !current) return;
    try {
      await current.view.refresh(current.root);
      const o = await api("/api/admin/overview");
      const set = (id, n) => { const el = $(id); el.hidden = !n; el.textContent = n; };
      set("#nav-conflicts", o.open_conflicts);
      set("#nav-requests", o.pending_requests);
      $("#conn-dot").className = "dot on";
      $("#conn-text").textContent = "Live";
    } catch (err) {
      if (err.message !== "Signed out") {
        $("#conn-dot").className = "dot off";
        $("#conn-text").textContent = "Server unreachable";
      }
    }
  }

  window.addEventListener("hashchange", route);
  setInterval(poll, 4000);
  $("#auditor-name").textContent = auditor;
  route();
})();
