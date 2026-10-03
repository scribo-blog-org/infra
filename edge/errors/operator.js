(function () {
    var root = document.getElementById("operator");
    if (!root) return;

    var style = document.createElement("style");
    style.textContent = [
        "#operator { margin-top: 36px; padding-top: 8px; border-top: 1px solid var(--line); }",
        "#operator h2 { margin-top: 28px; }",
        "#operator h2:first-child { margin-top: 20px; }",
        ".op-lead { margin-bottom: 16px; }",
        ".op-form { display: grid; gap: 10px; max-width: 320px; }",
        ".op-form label { display: grid; gap: 4px; font-size: 13px; color: var(--muted); }",
        ".op-form input {",
        "  width: 100%; border: 1px solid var(--line); border-radius: 8px;",
        "  padding: 10px 12px; background: var(--bg); color: var(--text); font: inherit; font-size: 14px;",
        "}",
        ".op-form button, .op-toolbar button, .op-actions button { margin-top: 0; }",
        ".op-error { min-height: 1.2em; color: var(--bad); }",
        ".op-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; }",
        ".op-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 28px; margin-top: 8px; }",
        ".op-stat { margin: 8px 0 0; color: var(--text); }",
        ".meter { height: 8px; margin-top: 10px; border-radius: 99px; background: var(--line); overflow: hidden; }",
        ".meter span { display: block; height: 100%; background: var(--text); }",
        ".op-list { margin-top: 8px; }",
        ".op-row, .op-proc {",
        "  display: grid; grid-template-columns: minmax(0, 1fr) auto auto; gap: 12px; align-items: center;",
        "  padding: 8px 0; border-bottom: 1px solid var(--line); font-size: 14px;",
        "}",
        ".op-proc { grid-template-columns: minmax(0, 1fr) auto auto; }",
        ".op-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }",
        ".op-pid { color: var(--muted); font-weight: 400; }",
        ".op-num { font-variant-numeric: tabular-nums; text-align: right; }",
        ".op-state { color: var(--muted); font-size: 13px; }",
        ".op-state.on { color: var(--ok); }",
        ".op-actions { display: flex; justify-content: flex-end; gap: 6px; }",
        ".op-actions button { padding: 6px 10px; font-size: 13px; }",
        ".op-actions button:disabled { opacity: 0.45; cursor: default; }",
        "@media (max-width: 720px) {",
        "  .op-grid { grid-template-columns: 1fr; }",
        "  .op-row { grid-template-columns: minmax(0, 1fr); }",
        "  .op-actions { justify-content: flex-start; }",
        "}"
    ].join("\n");
    document.head.appendChild(style);

    var names = {
        frontend: "Frontend",
        backend: "Backend",
        socket: "Socket",
        redis: "Redis",
        mongo: "Mongo"
    };
    var states = {
        running: "Running",
        exited: "Stopped",
        created: "Created",
        restarting: "Restarting",
        paused: "Paused",
        dead: "Dead",
        absent: "Not created"
    };
    var authed = false;
    var busy = false;
    var inflight = false;
    var queued = false;
    var timer = 0;

    function clear(node) {
        while (node.firstChild) node.removeChild(node.firstChild);
    }

    function el(tag, className, text) {
        var node = document.createElement(tag);
        if (className) node.className = className;
        if (text != null) node.textContent = text;
        return node;
    }

    function gb(bytes) {
        return (bytes / 1073741824).toFixed(2) + " GB";
    }

    function api(path, options) {
        var request = options || {};
        request.headers = Object.assign({ "X-Status-Request": "1" }, request.headers || {});
        request.cache = "no-store";
        return fetch("/status/api" + path, request).then(function (response) {
            return response.json().catch(function () {
                return {};
            }).then(function (data) {
                data._status = response.status;
                return data;
            });
        });
    }

    function showLogin(message) {
        authed = false;
        busy = false;
        queued = false;
        if (timer) {
            clearInterval(timer);
            timer = 0;
        }
        clear(root);
        var title = el("h2", "", "Operator");
        var lead = el("p", "op-lead", "Sign in to start, stop, and restart services, and to see disk, RAM, and processes.");
        var form = el("form", "op-form");
        form.autocomplete = "on";
        var user = field("User", "user", "text", "username");
        var password = field("Password", "password", "password", "current-password");
        var button = el("button", "", "Sign in");
        button.type = "submit";
        var error = el("p", "op-error", message || "");
        form.appendChild(user.label);
        form.appendChild(password.label);
        form.appendChild(button);
        form.appendChild(error);
        form.addEventListener("submit", function (event) {
            event.preventDefault();
            error.textContent = "";
            button.disabled = true;
            api("/login", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    user: user.input.value,
                    password: password.input.value
                })
            }).then(function (data) {
                if (data._status === 200 && data.ok) {
                    showAuthed();
                    return;
                }
                error.textContent = data.error || "Could not sign in.";
            }).catch(function () {
                error.textContent = "Operator service is not running.";
            }).then(function () {
                button.disabled = false;
            });
        });
        root.appendChild(title);
        root.appendChild(lead);
        root.appendChild(form);
    }

    function field(labelText, name, type, autocomplete) {
        var label = el("label");
        label.appendChild(document.createTextNode(labelText));
        var input = document.createElement("input");
        input.name = name;
        input.type = type;
        input.autocomplete = autocomplete;
        input.required = true;
        input.maxLength = 128;
        label.appendChild(input);
        return { label: label, input: input };
    }

    function showAuthed() {
        authed = true;
        clear(root);
        var bar = el("div", "op-toolbar");
        bar.appendChild(el("h2", "", "Operator"));
        var out = el("button", "", "Sign out");
        out.type = "button";
        out.addEventListener("click", function () {
            api("/logout", { method: "POST" }).finally(function () {
                showLogin("");
            });
        });
        bar.appendChild(out);
        var services = el("div", "op-list");
        var grid = el("div", "op-grid");
        var disk = meterBlock("Disk");
        var memory = meterBlock("RAM");
        grid.appendChild(disk.section);
        grid.appendChild(memory.section);
        var memTitle = el("h2", "", "Top memory");
        var memList = el("div", "op-list");
        var cpuTitle = el("h2", "", "Top CPU");
        var cpuNote = el("p", "", "Share of the whole machine, sampled for half a second.");
        var cpuList = el("div", "op-list");
        var error = el("p", "op-error", "");
        root.appendChild(bar);
        root.appendChild(el("h2", "", "Services"));
        root.appendChild(services);
        root.appendChild(grid);
        root.appendChild(memTitle);
        root.appendChild(memList);
        root.appendChild(cpuTitle);
        root.appendChild(cpuNote);
        root.appendChild(cpuList);
        root.appendChild(error);

        function paintServices(rows) {
            clear(services);
            rows.forEach(function (row) {
                var line = el("div", "op-row");
                line.appendChild(el("strong", "op-name", names[row.service] || row.service));
                var state = el("span", "op-state" + (row.state === "running" ? " on" : ""), states[row.state] || row.state);
                var actions = el("div", "op-actions");
                actions.appendChild(actionButton("Start", row, "start", row.state === "running"));
                actions.appendChild(actionButton("Stop", row, "stop", row.state !== "running"));
                actions.appendChild(actionButton("Restart", row, "restart", row.state === "absent"));
                line.appendChild(state);
                line.appendChild(actions);
                services.appendChild(line);
            });
        }

        function actionButton(label, row, action, disabled) {
            var button = el("button", "", label);
            button.type = "button";
            button.disabled = disabled || busy;
            button.addEventListener("click", function () {
                if (busy) return;
                busy = true;
                error.textContent = "";
                paintServices(lastRows);
                api("/services/" + row.service + "/" + action, { method: "POST" }).then(function (data) {
                    if (data._status !== 200) {
                        error.textContent = data.error || "Action failed.";
                    }
                }).catch(function () {
                    error.textContent = "Operator service is not running.";
                }).then(refresh);
            });
            return button;
        }

        var lastRows = [];

        function refresh() {
            if (!authed) return;
            if (inflight) {
                queued = true;
                return;
            }
            inflight = true;
            Promise.all([
                api("/host"),
                api("/services")
            ]).then(function (results) {
                var host = results[0];
                var list = results[1];
                if (host._status === 401 || list._status === 401) {
                    showLogin("");
                    return;
                }
                busy = false;
                if (host._status === 200) {
                    fillMeter(disk, host.disk);
                    fillMeter(memory, host.memory);
                    paintProcs(memList, host.memory_top || [], true);
                    paintProcs(cpuList, host.cpu_top || [], false);
                } else {
                    error.textContent = host.error || "Operator service is not running.";
                }
                if (list._status === 200 && list.services) {
                    lastRows = list.services;
                    paintServices(lastRows);
                } else if (host._status === 200) {
                    error.textContent = list.error || "Operator service is not running.";
                }
            }).catch(function () {
                busy = false;
                error.textContent = "Operator service is not running.";
            }).then(function () {
                inflight = false;
                if (queued && authed) {
                    queued = false;
                    refresh();
                }
            });
        }

        refresh();
        timer = setInterval(function () {
            if (!busy) refresh();
        }, 8000);
    }

    function meterBlock(title) {
        var section = el("section");
        section.appendChild(el("h2", "", title));
        var text = el("p", "op-stat", "Reading…");
        var meter = el("div", "meter");
        var fill = el("span");
        fill.style.width = "0%";
        meter.appendChild(fill);
        section.appendChild(text);
        section.appendChild(meter);
        return { section: section, text: text, fill: fill };
    }

    function fillMeter(block, stat) {
        if (!stat || !stat.total) {
            block.text.textContent = "Unavailable";
            block.fill.style.width = "0%";
            return;
        }
        var pct = Math.max(0, Math.min(100, stat.used / stat.total * 100));
        block.text.textContent = gb(stat.used) + " used · " + gb(stat.free) + " free · " + gb(stat.total) + " total";
        block.fill.style.width = pct.toFixed(1) + "%";
    }

    function paintProcs(node, rows, memory) {
        clear(node);
        if (!rows.length) {
            node.appendChild(el("p", "", memory ? "No process is using RAM." : "No measurable CPU in this sample."));
            return;
        }
        rows.forEach(function (row) {
            var line = el("div", "op-proc");
            var name = el("span", "op-name");
            name.appendChild(document.createTextNode(row.name || "?"));
            name.appendChild(el("span", "op-pid", " · " + row.pid));
            line.appendChild(name);
            if (memory) line.appendChild(el("span", "op-num", gb(row.bytes || 0)));
            else line.appendChild(el("span", "op-num", ""));
            line.appendChild(el("span", "op-num", (row.percent != null ? row.percent.toFixed(1) : "0.0") + "%"));
            node.appendChild(line);
        });
    }

    api("/session").then(function (data) {
        if (data._status === 200 && data.ok) showAuthed();
        else if (data._status === 401) showLogin("");
        else showLogin(data.error || "Operator service is not running.");
    }).catch(function () {
        showLogin("Operator service is not running.");
    });
})();
