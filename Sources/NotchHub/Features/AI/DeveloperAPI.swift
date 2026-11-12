import AppKit
import Network
import SwiftUI

// MARK: - Agent center: approvals, activity, shell & build islands

struct AgentEvent: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let date = Date()
}

final class AgentCenter: ObservableObject {
    static let shared = AgentCenter()
    @Published var events: [AgentEvent] = []
    @Published var lastTurnCost: Double?
    private var shellStarts: [String: (String, Date)] = [:]

    func log(_ e: AgentEvent) { events.insert(e, at: 0); if events.count > 100 { events.removeLast() } }

    /// Claude Code PreToolUse hook → Allow / Deny island. Completion receives the hook JSON response.
    func permissionRequest(_ body: [String: Any], respond: @escaping ([String: Any]) -> Void) {
        let event = body["hook_event_name"] as? String ?? "PreToolUse"
        // Approvals disabled → no decision, Claude Code shows its own prompt as usual.
        guard Prefs.bool(Prefs.Key.notchApprovals) else { respond([:]); return }
        let tool = body["tool_name"] as? String ?? "Tool"
        let input = body["tool_input"] as? [String: Any] ?? [:]
        let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["url"] as? String) ?? input.keys.joined(separator: ", ")
        var answered = false
        let reply: (String, String?) -> Void = { decision, reason in
            guard !answered else { return }
            answered = true
            if decision == "ask" { respond([:]); return }      // no decision → normal Claude Code prompt
            if event == "PermissionRequest" {
                var d: [String: Any] = ["behavior": decision]
                if let reason, decision == "deny" { d["message"] = reason }
                respond(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]])
            } else {
                var out: [String: Any] = ["hookEventName": "PreToolUse", "permissionDecision": decision]
                if let reason { out["permissionDecisionReason"] = reason }
                respond(["hookSpecificOutput": out])
            }
        }

        // Questions from Claude Code (AskUserQuestion) can be answered right from the notch.
        if tool == "AskUserQuestion", let qs = input["questions"] as? [[String: Any]], let q = qs.first {
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }.prefix(3)
            let actions = options.map { opt in IslandAction(title: opt) { reply("deny", "The user answered from NotchHub: \(opt)") } }
            AppState.shared.show(Island(kind: .approval, icon: "questionmark.bubble.fill", title: q["question"] as? String ?? "Question",
                                        subtitle: "Claude Code", tint: .purple, actions: Array(actions), duration: 110))
        } else if event == "PreToolUse" {
            // Old installs routed every tool call here; never block those — let Claude Code decide.
            respond([:]); return
        } else {
            AppState.shared.show(Island(kind: .approval, icon: "hand.raised.fill", title: "Claude Code wants to use \(tool)", subtitle: summary, tint: .orange,
                                        actions: [IslandAction(title: L("Allow")) { reply("allow", "Approved in NotchHub") },
                                                  IslandAction(title: L("Deny"), role: .destructive) { reply("deny", "Denied in NotchHub") }],
                                        duration: 55))
        }
        log(AgentEvent(icon: "hand.raised", title: "Permission: \(tool)", detail: summary))
        // Fall back to Claude Code's own prompt if nobody answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 58) {
            if !answered, AppState.shared.island?.kind == .approval { AppState.shared.dismissIsland() }
            reply("ask", nil)
        }
    }

    func agentEvent(_ b: [String: Any]) {
        let agent = b["agent"] as? String ?? "claude"
        let event = b["hook_event_name"] as? String ?? b["event"] as? String ?? b["type"] as? String ?? "event"
        switch event {
        case "UserPromptSubmit":
            let p = b["prompt"] as? String ?? ""
            AppState.shared.setActivity(LiveActivity(id: "6-agent", icon: "sparkles", text: "\(agent.capitalized) working", tint: .purple))
            log(AgentEvent(icon: "text.bubble", title: "\(agent.capitalized) prompt", detail: p))
        case "Stop", "agent-turn-complete":
            AppState.shared.clearActivity("6-agent")
            var cost: Double?
            if let t = b["transcript_path"] as? String { cost = AICost.lastTurnCost(transcript: t); lastTurnCost = cost }
            let msg = b["last-assistant-message"] as? String ?? ""
            AppState.shared.show(Island(kind: .agent, icon: "checkmark.seal.fill", title: "\(agent.capitalized) finished",
                                        subtitle: cost.map { String(format: "Turn cost ≈ $%.3f", $0) } ?? msg, tint: .purple, duration: 4))
            log(AgentEvent(icon: "checkmark.seal", title: "\(agent.capitalized) turn done", detail: cost.map { String(format: "$%.3f", $0) } ?? msg))
        case "Notification":
            let m = b["message"] as? String ?? ""
            AppState.shared.show(Island(kind: .agent, icon: "bell.fill", title: "\(agent.capitalized)", subtitle: m, tint: .purple, duration: 5))
            log(AgentEvent(icon: "bell", title: "Notification", detail: m))
        default:
            log(AgentEvent(icon: "circle", title: "\(agent) \(event)", detail: ""))
        }
    }

    func shellStart(id: String, cmd: String) {
        shellStarts[id] = (cmd, Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let s = self.shellStarts[id] else { return }
            AppState.shared.setActivity(LiveActivity(id: "7-shell-\(id)", icon: "terminal", text: String(s.0.prefix(18)), tint: .cyan))
        }
    }

    func shellEnd(id: String, status: Int) {
        guard let s = shellStarts.removeValue(forKey: id) else { return }
        AppState.shared.clearActivity("7-shell-\(id)")
        let dur = Date().timeIntervalSince(s.1)
        guard dur > 10 else { return }
        AppState.shared.show(Island(kind: .shell, icon: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                    title: status == 0 ? "Command finished" : "Command failed (\(status))",
                                    subtitle: "\(s.0) — \(formatDuration(dur))", tint: status == 0 ? .green : .red, duration: 5))
    }

    func build(_ b: [String: Any]) {
        let phase = b["phase"] as? String ?? "end"
        let name = b["name"] as? String ?? "Build"
        if phase == "start" {
            AppState.shared.setActivity(LiveActivity(id: "8-build", icon: "hammer.fill", text: name, tint: .blue))
            buildStart = Date()
            buildTimer?.invalidate()
            buildTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let s = self?.buildStart else { return }
                AppState.shared.setActivity(LiveActivity(id: "8-build", icon: "hammer.fill", text: "\(name) \(formatDuration(Date().timeIntervalSince(s)))", tint: .blue))
            }
        } else {
            buildTimer?.invalidate()
            AppState.shared.clearActivity("8-build")
            let w = b["warnings"] as? Int ?? Int(b["warnings"] as? String ?? "") ?? 0
            let e = b["errors"] as? Int ?? Int(b["errors"] as? String ?? "") ?? 0
            let ok = (b["status"] as? Int ?? Int(b["status"] as? String ?? "0") ?? 0) == 0 && e == 0
            AppState.shared.show(Island(kind: .build, icon: ok ? "hammer.circle.fill" : "exclamationmark.octagon.fill", title: ok ? "\(name) succeeded" : "\(name) failed",
                                        subtitle: "\(e) errors · \(w) warnings · \(formatDuration(Date().timeIntervalSince(buildStart ?? Date())))", tint: ok ? .green : .red, duration: 6))
        }
    }
    private var buildStart: Date?
    private var buildTimer: Timer?
}

// MARK: - Local Developer API (127.0.0.1:9999, per-install token, off by default)

final class DeveloperAPI {
    static let shared = DeveloperAPI()
    static let port: UInt16 = 9999
    private var listener: NWListener?

    static var token: String {
        if let t = Keychain.get("devToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        Keychain.set(t, for: "devToken")
        return t
    }

    func update() {
        if Prefs.bool(Prefs.Key.developerAPI) { start() } else { listener?.cancel(); listener = nil }
    }

    private func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: .main)
        listener = l
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {
                self.route(req) { status, json in self.reply(c, status, json) }
            } else if done || err != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status == 0 { head = "" }
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ r: HTTPRequest, respond: @escaping (Int, [String: Any]) -> Void) {
        guard r.headers["authorization"] == "Bearer \(Self.token)" || r.query["token"] == Self.token else {
            respond(401, ["error": "invalid token"]); return
        }
        let b = r.body
        switch (r.method, r.path) {
        case ("GET", "/v1/status"):
            let m = MediaService.shared
            respond(200, ["app": "NotchHub", "expanded": AppState.shared.isExpanded, "tab": AppState.shared.tab.rawValue,
                          "nowPlaying": ["title": m.title, "artist": m.artist, "playing": m.isPlaying],
                          "timer": ["running": TimerService.shared.isRunning, "display": TimerService.shared.display],
                          "keepAwake": KeepAwake.shared.active])
        case ("POST", "/v1/island"):
            AppState.shared.show(Island(kind: .info, icon: b["icon"] as? String ?? "bell.fill", title: b["title"] as? String ?? "", subtitle: b["subtitle"] as? String ?? "",
                                        duration: b["duration"] as? Double ?? 3))
            respond(200, ["ok": true])
        case ("POST", "/v1/activity"):
            let id = "z-" + (b["id"] as? String ?? "api")
            if b["clear"] as? Bool == true { AppState.shared.clearActivity(id) }
            else { AppState.shared.setActivity(LiveActivity(id: id, icon: b["icon"] as? String ?? "circle.fill", text: b["text"] as? String ?? "")) }
            respond(200, ["ok": true])
        case ("POST", "/v1/open"):
            AppState.shared.open(NotchTab(rawValue: b["tab"] as? String ?? "") ?? nil)
            respond(200, ["ok": true])
        case ("POST", "/v1/claude/pretool"), ("POST", "/v1/claude/permission"):
            AgentCenter.shared.permissionRequest(b) { respond(200, $0) }
        case ("POST", "/v1/claude/event"), ("POST", "/v1/agent/event"):
            var e = b
            if e["agent"] == nil { e["agent"] = r.query["agent"] ?? (r.path.contains("claude") ? "claude" : "codex") }
            AgentCenter.shared.agentEvent(e); respond(200, [:])
        case ("POST", "/v1/shell/start"):
            AgentCenter.shared.shellStart(id: b["id"] as? String ?? "0", cmd: b["cmd"] as? String ?? ""); respond(200, [:])
        case ("POST", "/v1/shell/end"):
            AgentCenter.shared.shellEnd(id: b["id"] as? String ?? "0", status: Int(b["status"] as? String ?? "") ?? (b["status"] as? Int ?? 0)); respond(200, [:])
        case ("POST", "/v1/build"):
            AgentCenter.shared.build(b); respond(200, [:])
        case ("POST", "/v1/keepawake"):
            if b["on"] as? Bool == false { KeepAwake.shared.stop() } else { KeepAwake.shared.start(until: (b["minutes"] as? Double).map { Date().addingTimeInterval($0 * 60) }) }
            respond(200, ["ok": true])
        case ("POST", "/v1/timer"):
            TimerService.shared.setCountdown(minutes: b["minutes"] as? Double ?? 5); respond(200, ["ok": true])
        default:
            respond(404, ["error": "not found"])
        }
    }

    /// MCP configuration for AI apps (stdio bridge script shipped in scripts/).
    static func mcpConfiguration(scriptPath: String) -> String {
        """
        {
          "mcpServers": {
            "notchhub": {
              "command": "python3",
              "args": ["\(scriptPath)"],
              "env": { "NOTCHHUB_TOKEN": "\(token)", "NOTCHHUB_URL": "http://127.0.0.1:\(port)" }
            }
          }
        }
        """
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: [String: Any]

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(h["content-length"] ?? "0") ?? 0
        let bodyData = data[sep.upperBound...]
        guard bodyData.count >= len else { return nil }
        let raw = Data(bodyData.prefix(len))
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        method = String(first[0])
        path = comps?.path ?? target
        query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        headers = h
        if let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            body = j
        } else if let s = String(data: raw, encoding: .utf8), !s.isEmpty {
            // application/x-www-form-urlencoded (used by the zsh hook)
            var form: [String: Any] = [:]
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
                if kv.count == 2 { form[kv[0]] = kv[1] }
            }
            body = form
        } else { body = [:] }
    }
}

// MARK: - Hook installers

enum HookInstaller {
    static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notchhub", isDirectory: true) }

    static func writeScripts() -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let token = DeveloperAPI.token
        let hook = """
        #!/bin/sh
        # NotchHub hook bridge. Usage: hook.sh <pretool|event> — reads hook JSON on stdin.
        curl -s --max-time 60 -X POST -H "Authorization: Bearer \(token)" -H "Content-Type: application/json" \\
          --data-binary @- "http://127.0.0.1:\(DeveloperAPI.port)/v1/claude/$1" 2>/dev/null || true
        """
        let codex = """
        #!/bin/sh
        # Codex `notify` program: receives a JSON argument.
        printf '%s' "$1" | curl -s --max-time 3 -X POST -H "Authorization: Bearer \(token)" -H "Content-Type: application/json" \\
          --data-binary @- "http://127.0.0.1:\(DeveloperAPI.port)/v1/agent/event?agent=codex" >/dev/null 2>&1 || true
        """
        let zsh = """
        # NotchHub shell activity — add `source ~/.notchhub/shell.zsh` to ~/.zshrc
        zmodload zsh/datetime
        _nh_post() { curl -s --max-time 1 -X POST -H "Authorization: Bearer \(token)" "$@" >/dev/null 2>&1 &! }
        _nh_preexec() { _NH_ID="$$-$EPOCHSECONDS"; _nh_post --data-urlencode "id=$_NH_ID" --data-urlencode "cmd=$1" http://127.0.0.1:\(DeveloperAPI.port)/v1/shell/start }
        _nh_precmd() { local s=$?; [ -n "$_NH_ID" ] && _nh_post --data-urlencode "id=$_NH_ID" --data-urlencode "status=$s" http://127.0.0.1:\(DeveloperAPI.port)/v1/shell/end; _NH_ID="" }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec _nh_preexec
        add-zsh-hook precmd _nh_precmd
        """
        let xcb = """
        #!/bin/zsh
        # nh-xcodebuild: wraps xcodebuild and reports a live build island with warning/error counts.
        _p() { curl -s --max-time 1 -X POST -H "Authorization: Bearer \(token)" -H "Content-Type: application/json" -d "$1" http://127.0.0.1:\(DeveloperAPI.port)/v1/build >/dev/null 2>&1 }
        _p '{"phase":"start","name":"Xcode build"}'
        log=$(mktemp)
        xcodebuild "$@" 2>&1 | tee "$log"
        st=${pipestatus[1]}
        w=$(grep -c "warning:" "$log"); e=$(grep -c "error:" "$log")
        _p "{\\"phase\\":\\"end\\",\\"name\\":\\"Xcode build\\",\\"status\\":$st,\\"warnings\\":$w,\\"errors\\":$e}"
        rm -f "$log"; exit $st
        """
        for (name, content, exec) in [("hook.sh", hook, true), ("codex-notify.sh", codex, true), ("shell.zsh", zsh, false), ("nh-xcodebuild", xcb, true)] {
            let u = dir.appendingPathComponent(name)
            try? content.write(to: u, atomically: true, encoding: .utf8)
            if exec { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        }
        return dir
    }

    /// Merges NotchHub hooks into ~/.claude/settings.json (backup written first).
    static func installClaudeHooks() -> String {
        _ = writeScripts()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: url) {
            try? d.write(to: url.appendingPathExtension("notchhub-backup"))
            root = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        let hook = dir.appendingPathComponent("hook.sh").path
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // PermissionRequest fires only when Claude Code would actually ask you — auto-allowed tools are untouched.
        hooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": "\(hook) permission", "timeout": 60]]]]
        // PreToolUse only for AskUserQuestion, so questions can be answered from the notch.
        hooks["PreToolUse"] = [["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": "\(hook) pretool", "timeout": 60]]]]
        for e in ["UserPromptSubmit", "Stop", "Notification"] { hooks[e] = [["hooks": [["type": "command", "command": "\(hook) event"]]]] }
        root["hooks"] = hooks
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: url)
            return "Installed into \(url.path) (backup: settings.json.notchhub-backup)"
        }
        return "Failed to write \(url.path)"
    }
}
