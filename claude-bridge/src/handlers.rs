use crate::claude_runner::TurnManager;
use crate::protocol::{Notification, Request, Response};
use crate::session::{PersistedMessage, SessionStore, ThreadEntry, now_iso8601, now_unix_seconds};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::{Duration, timeout};
use tracing::warn;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub sessions: SessionStore,
    pub turns: TurnManager,
    pub logins: LoginManager,
    pub notify_tx: mpsc::UnboundedSender<Notification>,
}

impl AppState {
    pub fn new(sessions: SessionStore, notify_tx: mpsc::UnboundedSender<Notification>) -> Self {
        Self {
            sessions,
            turns: TurnManager::new(),
            logins: LoginManager::new(),
            notify_tx,
        }
    }
}

#[derive(Clone)]
pub struct LoginManager {
    running: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
}

impl LoginManager {
    pub fn new() -> Self {
        Self {
            running: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn register(&self, login_id: String, cancel_tx: oneshot::Sender<()>) {
        let mut guard = self.running.lock().await;
        guard.insert(login_id, cancel_tx);
    }

    pub async fn take_cancel(&self, login_id: &str) -> Option<oneshot::Sender<()>> {
        let mut guard = self.running.lock().await;
        guard.remove(login_id)
    }

    pub async fn remove(&self, login_id: &str) {
        let mut guard = self.running.lock().await;
        guard.remove(login_id);
    }
}

pub async fn handle_request(state: Arc<AppState>, request: Request) -> Option<Response> {
    let Some(id) = request.id else {
        return None;
    };

    let result = match request.method.as_str() {
        "initialize" => Ok(json!({ "userAgent": "claude-app-server/0.1" })),
        "account/read" => handle_account_read().await,
        "account/login/start" => handle_account_login_start(state.clone(), request.params).await,
        "account/login/cancel" => handle_account_login_cancel(state.clone(), request.params).await,
        "account/logout" => handle_account_logout(state.clone()).await,
        "model/list" => Ok(model_list_response()),
        "mcpServerStatus/list" => handle_mcp_server_status_list(request.params).await,
        "mcpServer/oauth/login" => handle_mcp_server_oauth_login(request.params).await,
        "config/mcpServer/reload" => Ok(json!({})),
        "skills/list" => handle_skills_list(request.params).await,
        "thread/list" => handle_thread_list(state.clone(), request.params).await,
        "thread/start" => handle_thread_start(state.clone(), request.params).await,
        "thread/resume" => handle_thread_resume(state.clone(), request.params).await,
        "turn/start" => handle_turn_start(state.clone(), request.params).await,
        "turn/interrupt" => handle_turn_interrupt(state.clone(), request.params).await,
        "command/exec" => handle_command_exec(request.params).await,
        method => Err((-32601, format!("method not found: {method}"))),
    };

    Some(match result {
        Ok(value) => Response::success(id, value),
        Err((code, message)) => Response::error(id, code, message),
    })
}

async fn handle_account_read() -> Result<Value, (i64, String)> {
    let status = read_claude_auth_status().await;
    let account = status
        .as_ref()
        .filter(|s| s.logged_in)
        .map(|s| {
            json!({
                "type": "claude",
                "email": s.email,
                "planType": s.subscription_type
            })
        })
        .unwrap_or(Value::Null);

    Ok(json!({
        "account": account,
        "requiresOpenaiAuth": false
    }))
}

async fn handle_account_login_start(
    state: Arc<AppState>,
    params: Value,
) -> Result<Value, (i64, String)> {
    let login_type = params
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("claude");
    if login_type != "claude" {
        return Err((
            -32602,
            "claude-app-server only supports type=claude".to_string(),
        ));
    }

    if !claude_cli_available().await {
        return Err((-32001, "`claude` CLI not found in PATH".to_string()));
    }

    if let Some(status) = read_claude_auth_status().await {
        if status.logged_in {
            let _ = state.notify_tx.send(Notification {
                method: "account/login/completed".to_string(),
                params: json!({
                    "loginId": null,
                    "success": true,
                    "error": null
                }),
            });
            let _ = state.notify_tx.send(Notification {
                method: "account/updated".to_string(),
                params: json!({}),
            });
            return Ok(json!({
                "type": "claude",
                "loginId": null,
                "authUrl": null
            }));
        }
    }

    let login_id = format!("claude_{}", Uuid::new_v4().simple());
    let email = params
        .get("email")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);

    let (auth_url_tx, auth_url_rx) = oneshot::channel::<Option<String>>();
    let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
    state.logins.register(login_id.clone(), cancel_tx).await;

    let notify_tx = state.notify_tx.clone();
    let logins = state.logins.clone();
    let login_id_for_task = login_id.clone();
    tokio::spawn(async move {
        run_claude_login(
            login_id_for_task,
            email,
            notify_tx,
            logins,
            auth_url_tx,
            cancel_rx,
        )
        .await;
    });

    let auth_url = match timeout(Duration::from_secs(12), auth_url_rx).await {
        Ok(Ok(url)) => url,
        _ => None,
    };

    Ok(json!({
        "type": "claude",
        "loginId": login_id,
        "authUrl": auth_url
    }))
}

async fn handle_account_login_cancel(
    state: Arc<AppState>,
    params: Value,
) -> Result<Value, (i64, String)> {
    let login_id = params
        .get("loginId")
        .and_then(Value::as_str)
        .ok_or((-32602, "loginId is required".to_string()))?;

    let cancelled = if let Some(cancel) = state.logins.take_cancel(login_id).await {
        cancel.send(()).is_ok()
    } else {
        false
    };

    Ok(json!({ "cancelled": cancelled }))
}

async fn handle_account_logout(state: Arc<AppState>) -> Result<Value, (i64, String)> {
    if !claude_cli_available().await {
        return Ok(json!({}));
    }

    let output = Command::new("claude")
        .arg("auth")
        .arg("logout")
        .output()
        .await
        .map_err(|e| (-32001, format!("failed to execute claude logout: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let message = if stderr.is_empty() {
            format!("claude auth logout failed with {}", output.status)
        } else {
            stderr
        };
        return Err((-32001, message));
    }

    let _ = state.notify_tx.send(Notification {
        method: "account/updated".to_string(),
        params: json!({}),
    });

    Ok(json!({}))
}

async fn run_claude_login(
    login_id: String,
    email: Option<String>,
    notify_tx: mpsc::UnboundedSender<Notification>,
    logins: LoginManager,
    auth_url_tx: oneshot::Sender<Option<String>>,
    mut cancel_rx: oneshot::Receiver<()>,
) {
    let mut auth_url_tx = Some(auth_url_tx);

    let mut cmd = Command::new("claude");
    cmd.arg("auth").arg("login");
    if let Some(email) = email {
        cmd.arg("--email").arg(email);
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(err) => {
            if let Some(tx) = auth_url_tx.take() {
                let _ = tx.send(None);
            }
            let _ = notify_tx.send(Notification {
                method: "account/login/completed".to_string(),
                params: json!({
                    "loginId": login_id,
                    "success": false,
                    "error": format!("Failed to launch claude auth login: {err}")
                }),
            });
            let _ = notify_tx.send(Notification {
                method: "account/updated".to_string(),
                params: json!({}),
            });
            logins.remove(&login_id).await;
            return;
        }
    };

    let mut stdout_done = false;
    let mut stderr_done = false;
    let mut auth_url: Option<String> = None;
    let mut error_lines: Vec<String> = Vec::new();
    let mut stdout_lines = child.stdout.take().map(|s| BufReader::new(s).lines());
    let mut stderr_lines = child.stderr.take().map(|s| BufReader::new(s).lines());
    let mut cancelled = false;

    while !stdout_done || !stderr_done {
        tokio::select! {
            _ = &mut cancel_rx => {
                cancelled = true;
                let _ = child.kill().await;
                break;
            }

            line = async {
                if let Some(lines) = stdout_lines.as_mut() {
                    lines.next_line().await
                } else {
                    Ok(None)
                }
            }, if !stdout_done => {
                match line {
                    Ok(Some(line)) => {
                        if auth_url.is_none() {
                            auth_url = extract_auth_url(&line);
                        }
                    }
                    Ok(None) => {
                        stdout_done = true;
                    }
                    Err(err) => {
                        error_lines.push(format!("failed reading claude login stdout: {err}"));
                        stdout_done = true;
                    }
                }
            }

            line = async {
                if let Some(lines) = stderr_lines.as_mut() {
                    lines.next_line().await
                } else {
                    Ok(None)
                }
            }, if !stderr_done => {
                match line {
                    Ok(Some(line)) => {
                        if auth_url.is_none() {
                            auth_url = extract_auth_url(&line);
                        }
                        if !line.trim().is_empty() {
                            error_lines.push(line);
                        }
                    }
                    Ok(None) => {
                        stderr_done = true;
                    }
                    Err(err) => {
                        error_lines.push(format!("failed reading claude login stderr: {err}"));
                        stderr_done = true;
                    }
                }
            }
        }

        if auth_url.is_some() {
            if let Some(tx) = auth_url_tx.take() {
                let _ = tx.send(auth_url.clone());
            }
        }
    }

    if let Some(tx) = auth_url_tx.take() {
        let _ = tx.send(auth_url.clone());
    }

    let status = child.wait().await.ok();
    let auth = read_claude_auth_status().await;
    let success = auth.as_ref().map(|s| s.logged_in).unwrap_or(false);
    let error = if success {
        None
    } else if cancelled {
        Some("Login cancelled".to_string())
    } else if !error_lines.is_empty() {
        Some(error_lines.join("\n"))
    } else if let Some(status) = status {
        Some(format!("Claude login exited with {status}"))
    } else {
        Some("Claude login failed".to_string())
    };

    let _ = notify_tx.send(Notification {
        method: "account/login/completed".to_string(),
        params: json!({
            "loginId": login_id,
            "success": success,
            "error": error
        }),
    });
    let _ = notify_tx.send(Notification {
        method: "account/updated".to_string(),
        params: json!({}),
    });

    logins.remove(&login_id).await;
}

async fn claude_cli_available() -> bool {
    Command::new("claude")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[derive(Debug, Deserialize)]
struct ClaudeAuthStatus {
    #[serde(rename = "loggedIn")]
    logged_in: bool,
    email: Option<String>,
    #[serde(rename = "subscriptionType")]
    subscription_type: Option<String>,
}

async fn read_claude_auth_status() -> Option<ClaudeAuthStatus> {
    let output = Command::new("claude")
        .arg("auth")
        .arg("status")
        .arg("--json")
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice::<ClaudeAuthStatus>(&output.stdout).ok()
}

fn extract_auth_url(line: &str) -> Option<String> {
    let start = line.find("https://").or_else(|| line.find("http://"))?;
    let tail = &line[start..];
    let end = tail.find(char::is_whitespace).unwrap_or(tail.len());
    let trimmed = tail[..end].trim_end_matches([')', ',', '.']);
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn model_list_response() -> Value {
    let mk = |id: &str, display: &str, default: bool| {
        json!({
            "id": id,
            "model": id,
            "upgrade": Value::Null,
            "displayName": display,
            "description": format!("{} via claude CLI", display),
            "hidden": false,
            "supportedReasoningEfforts": [
                { "reasoningEffort": "low", "description": "Faster responses" },
                { "reasoningEffort": "medium", "description": "Balanced" },
                { "reasoningEffort": "high", "description": "More reasoning" }
            ],
            "defaultReasoningEffort": "medium",
            "inputModalities": ["text"],
            "supportsPersonality": false,
            "isDefault": default
        })
    };

    json!({
        "data": [
            mk("claude-sonnet-4-6", "Claude Sonnet 4.6", true),
            mk("claude-opus-4-6", "Claude Opus 4.6", false),
            mk("claude-haiku-4-5", "Claude Haiku 4.5", false)
        ],
        "nextCursor": Value::Null
    })
}

async fn handle_mcp_server_status_list(params: Value) -> Result<Value, (i64, String)> {
    let cwds = config_lookup_cwds(&params);
    let servers = collect_mcp_servers(&cwds);

    let mut server_names: Vec<String> = servers.keys().cloned().collect();
    server_names.sort();

    let total = server_names.len();
    let limit = params
        .get("limit")
        .and_then(Value::as_u64)
        .map(|raw| raw.max(1) as usize)
        .unwrap_or(total.max(1));
    let start = match params.get("cursor").and_then(Value::as_str) {
        Some(cursor) => cursor
            .parse::<usize>()
            .map_err(|_| (-32602, format!("invalid cursor: {cursor}")))?,
        None => 0,
    };

    if start > total {
        return Err((
            -32602,
            format!("cursor {start} exceeds total MCP servers {total}"),
        ));
    }

    let end = start.saturating_add(limit).min(total);
    let data: Vec<Value> = server_names[start..end]
        .iter()
        .map(|name| {
            let config = servers.get(name).cloned().unwrap_or(Value::Null);
            json!({
                "name": name,
                "tools": {},
                "resources": [],
                "resourceTemplates": [],
                "authStatus": infer_mcp_auth_status(&config),
            })
        })
        .collect();

    let next_cursor = if end < total {
        Some(end.to_string())
    } else {
        None
    };

    Ok(json!({
        "data": data,
        "nextCursor": next_cursor,
    }))
}

async fn handle_mcp_server_oauth_login(params: Value) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or((-32602, "name is required".to_string()))?;

    let cwds = config_lookup_cwds(&params);
    let servers = collect_mcp_servers(&cwds);
    let config = servers
        .get(name)
        .ok_or((-32004, format!("MCP server not found: {name}")))?;

    if let Some(url) = extract_authorization_url(config) {
        return Ok(json!({ "authorizationUrl": url }));
    }

    Err((
        -32001,
        format!(
            "OAuth login URL is not available for `{name}`. Authenticate this MCP server directly via Claude CLI."
        ),
    ))
}

async fn handle_skills_list(params: Value) -> Result<Value, (i64, String)> {
    let cwds = config_lookup_cwds(&params);
    let mut data: Vec<Value> = Vec::new();

    for cwd in cwds {
        let (mut skills, errors) = collect_skills_for_cwd(&cwd);
        skills.sort_by_key(skill_sort_key);
        data.push(json!({
            "cwd": cwd.to_string_lossy(),
            "errors": errors,
            "skills": skills,
        }));
    }

    Ok(json!({ "data": data }))
}

fn config_lookup_cwds(params: &Value) -> Vec<PathBuf> {
    let mut cwds: Vec<PathBuf> = Vec::new();

    if let Some(raw) = params.get("cwd").and_then(Value::as_str)
        && let Some(path) = normalize_path(raw)
    {
        cwds.push(path);
    }

    if let Some(raw_cwds) = params.get("cwds").and_then(Value::as_array) {
        for raw in raw_cwds.iter().filter_map(Value::as_str) {
            if let Some(path) = normalize_path(raw) {
                cwds.push(path);
            }
        }
    }

    if cwds.is_empty()
        && let Ok(cwd) = std::env::current_dir()
    {
        cwds.push(cwd);
    }

    dedupe_paths(cwds)
}

fn normalize_path(raw: &str) -> Option<PathBuf> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let mut path = PathBuf::from(trimmed);
    if !path.is_absolute()
        && let Ok(cwd) = std::env::current_dir()
    {
        path = cwd.join(path);
    }
    Some(path)
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut unique = Vec::new();
    for path in paths {
        let key = canonical_key(&path);
        if seen.insert(key) {
            unique.push(path);
        }
    }
    unique
}

fn collect_mcp_servers(cwds: &[PathBuf]) -> HashMap<String, Value> {
    let mut servers: HashMap<String, Value> = HashMap::new();
    let mut paths = Vec::new();

    if let Ok(home) = std::env::var("HOME") {
        paths.push(PathBuf::from(home).join(".claude.json"));
    }
    for cwd in cwds {
        paths.push(cwd.join(".mcp.json"));
        paths.push(cwd.join(".claude.json"));
    }

    for path in dedupe_paths(paths) {
        merge_mcp_servers_from_path(&path, &mut servers);
    }

    servers
}

fn merge_mcp_servers_from_path(path: &Path, out: &mut HashMap<String, Value>) {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return,
    };

    let root = match serde_json::from_str::<Value>(&raw) {
        Ok(root) => root,
        Err(err) => {
            warn!("failed parsing MCP config {}: {err}", path.display());
            return;
        }
    };

    let Some(mcp_servers) = root.get("mcpServers").and_then(Value::as_object) else {
        return;
    };

    for (name, config) in mcp_servers {
        out.insert(name.clone(), config.clone());
    }
}

fn infer_mcp_auth_status(config: &Value) -> &'static str {
    if let Some(explicit) = config
        .get("authStatus")
        .and_then(Value::as_str)
        .and_then(normalize_mcp_auth_status)
    {
        return explicit;
    }

    if has_bearer_token(config) {
        return "bearerToken";
    }

    if extract_authorization_url(config).is_some() {
        return "notLoggedIn";
    }

    "unsupported"
}

fn normalize_mcp_auth_status(raw: &str) -> Option<&'static str> {
    match raw.to_ascii_lowercase().replace(['_', '-'], "").as_str() {
        "unsupported" => Some("unsupported"),
        "notloggedin" => Some("notLoggedIn"),
        "bearertoken" => Some("bearerToken"),
        "oauth" | "oauth2" => Some("oAuth"),
        _ => None,
    }
}

fn has_bearer_token(config: &Value) -> bool {
    let top_level = ["bearerToken", "accessToken", "token"];
    for key in top_level {
        if config
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|v| !v.trim().is_empty())
        {
            return true;
        }
    }

    let nested = ["auth", "oauth"];
    for key in nested {
        if let Some(obj) = config.get(key).and_then(Value::as_object) {
            for token_key in ["bearerToken", "accessToken", "token"] {
                if obj
                    .get(token_key)
                    .and_then(Value::as_str)
                    .is_some_and(|v| !v.trim().is_empty())
                {
                    return true;
                }
            }
        }
    }

    false
}

fn extract_authorization_url(config: &Value) -> Option<String> {
    let top_level = ["authorizationUrl", "oauthUrl", "authUrl", "url"];
    for key in top_level {
        if let Some(url) = config
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| s.starts_with("http://") || s.starts_with("https://"))
        {
            return Some(url.to_string());
        }
    }

    let nested = ["oauth", "auth"];
    for container in nested {
        if let Some(obj) = config.get(container).and_then(Value::as_object) {
            for key in ["authorizationUrl", "oauthUrl", "authUrl", "url"] {
                if let Some(url) = obj
                    .get(key)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| s.starts_with("http://") || s.starts_with("https://"))
                {
                    return Some(url.to_string());
                }
            }
        }
    }

    None
}

fn collect_skills_for_cwd(cwd: &Path) -> (Vec<Value>, Vec<Value>) {
    let mut skills: Vec<Value> = Vec::new();
    let mut errors: Vec<Value> = Vec::new();
    let mut seen = HashSet::new();

    if let Ok(home) = std::env::var("HOME") {
        let home_root = PathBuf::from(home);
        let home_claude = home_root.join(".claude");

        scan_skill_tree(
            &home_claude.join("skills"),
            "user",
            SkillFileKind::Skill,
            &mut seen,
            &mut skills,
            &mut errors,
        );
        scan_skill_tree(
            &home_claude.join("commands"),
            "user",
            SkillFileKind::Command,
            &mut seen,
            &mut skills,
            &mut errors,
        );

        for plugin_root in collect_claude_plugin_skill_roots(&home_root) {
            scan_skill_tree(
                &plugin_root,
                "user",
                SkillFileKind::Skill,
                &mut seen,
                &mut skills,
                &mut errors,
            );
        }
    }

    let mut repo_roots: Vec<PathBuf> = Vec::new();
    let mut current = Some(cwd.to_path_buf());
    while let Some(path) = current {
        let dot_claude = path.join(".claude");
        if dot_claude.is_dir() {
            repo_roots.push(dot_claude);
        }
        current = path.parent().map(Path::to_path_buf);
    }
    repo_roots = dedupe_paths(repo_roots);

    for repo_root in repo_roots {
        scan_skill_tree(
            &repo_root.join("skills"),
            "repo",
            SkillFileKind::Skill,
            &mut seen,
            &mut skills,
            &mut errors,
        );
        scan_skill_tree(
            &repo_root.join("commands"),
            "repo",
            SkillFileKind::Command,
            &mut seen,
            &mut skills,
            &mut errors,
        );
    }

    (skills, errors)
}

fn collect_claude_plugin_skill_roots(home_root: &Path) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let installed_plugins = home_root.join(".claude/plugins/installed_plugins.json");
    let raw = match std::fs::read_to_string(&installed_plugins) {
        Ok(raw) => raw,
        Err(_) => return roots,
    };
    let parsed: Value = match serde_json::from_str(&raw) {
        Ok(parsed) => parsed,
        Err(_) => return roots,
    };

    let Some(plugins) = parsed.get("plugins").and_then(Value::as_object) else {
        return roots;
    };

    for records in plugins.values() {
        let Some(records) = records.as_array() else {
            continue;
        };
        for record in records {
            let Some(install_path) = record.get("installPath").and_then(Value::as_str) else {
                continue;
            };
            let root = PathBuf::from(install_path).join("skills");
            if root.is_dir() {
                roots.push(root);
            }
        }
    }

    dedupe_paths(roots)
}

#[derive(Clone, Copy)]
enum SkillFileKind {
    Skill,
    Command,
}

fn scan_skill_tree(
    root: &Path,
    scope: &str,
    file_kind: SkillFileKind,
    seen: &mut HashSet<String>,
    skills: &mut Vec<Value>,
    errors: &mut Vec<Value>,
) {
    if !root.exists() {
        return;
    }

    let mut files = Vec::new();
    collect_skill_candidate_files(root, file_kind, &mut files);
    files.sort();

    for file in files {
        let key = canonical_key(&file);
        if !seen.insert(key) {
            continue;
        }

        match parse_skill_file(&file, scope) {
            Ok(skill) => skills.push(skill),
            Err(message) => errors.push(json!({
                "path": file.to_string_lossy(),
                "message": message,
            })),
        }
    }
}

fn collect_skill_candidate_files(root: &Path, file_kind: SkillFileKind, out: &mut Vec<PathBuf>) {
    let mut visited_dirs = HashSet::new();
    collect_skill_candidate_files_recursive(root, file_kind, out, &mut visited_dirs);
}

fn collect_skill_candidate_files_recursive(
    root: &Path,
    file_kind: SkillFileKind,
    out: &mut Vec<PathBuf>,
    visited_dirs: &mut HashSet<String>,
) {
    let root_key = canonical_key(root);
    if !visited_dirs.insert(root_key) {
        return;
    }

    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };

        if file_type.is_dir() {
            collect_skill_candidate_files_recursive(&path, file_kind, out, visited_dirs);
            continue;
        }
        if file_type.is_symlink() {
            let metadata = match std::fs::metadata(&path) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if metadata.is_dir() {
                collect_skill_candidate_files_recursive(&path, file_kind, out, visited_dirs);
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
        } else if !file_type.is_file() {
            continue;
        }

        match file_kind {
            SkillFileKind::Skill => {
                if path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.eq_ignore_ascii_case("SKILL.md"))
                {
                    out.push(path);
                }
            }
            SkillFileKind::Command => {
                if path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("md"))
                {
                    out.push(path);
                }
            }
        }
    }
}

fn parse_skill_file(path: &Path, scope: &str) -> Result<Value, String> {
    let markdown = std::fs::read_to_string(path)
        .map_err(|err| format!("failed reading skill file {}: {err}", path.display()))?;
    let frontmatter = parse_frontmatter(&markdown);

    let name =
        frontmatter_value(&frontmatter, &["name"]).unwrap_or_else(|| derive_skill_name(path));
    let description = frontmatter_value(&frontmatter, &["description"]).unwrap_or_default();
    let short_description = frontmatter_value(
        &frontmatter,
        &["shortdescription", "short-description", "short_description"],
    )
    .or_else(|| {
        if description.is_empty() {
            None
        } else {
            Some(description.clone())
        }
    });

    let display_name = frontmatter_value(
        &frontmatter,
        &["displayname", "display-name", "display_name"],
    );
    let brand_color =
        frontmatter_value(&frontmatter, &["brandcolor", "brand-color", "brand_color"]);
    let icon_small = frontmatter_value(&frontmatter, &["iconsmall", "icon-small", "icon_small"]);
    let default_prompt = frontmatter_value(
        &frontmatter,
        &["defaultprompt", "default-prompt", "default_prompt"],
    );

    let user_invocable = frontmatter_bool(
        &frontmatter,
        &["userinvocable", "user-invocable", "user_invocable"],
    )
    .unwrap_or(true);
    let disable_model_invocation = frontmatter_bool(
        &frontmatter,
        &[
            "disablemodelinvocation",
            "disable-model-invocation",
            "disable_model_invocation",
        ],
    )
    .unwrap_or(false);

    let enabled = user_invocable && !disable_model_invocation;
    let interface = if display_name.is_some()
        || short_description.is_some()
        || brand_color.is_some()
        || icon_small.is_some()
        || default_prompt.is_some()
    {
        Some(json!({
            "displayName": display_name,
            "shortDescription": short_description,
            "brandColor": brand_color,
            "iconSmall": icon_small,
            "defaultPrompt": default_prompt,
        }))
    } else {
        None
    };

    Ok(json!({
        "name": name,
        "path": path.to_string_lossy(),
        "description": description,
        "enabled": enabled,
        "scope": scope,
        "interface": interface,
        "shortDescription": short_description,
    }))
}

fn parse_frontmatter(markdown: &str) -> HashMap<String, String> {
    let mut fields = HashMap::new();
    let mut lines = markdown.lines();
    if !matches!(lines.next(), Some(line) if line.trim() == "---") {
        return fields;
    }

    for line in lines {
        let trimmed = line.trim();
        if trimmed == "---" {
            break;
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let Some(colon) = trimmed.find(':') else {
            continue;
        };

        let key = trimmed[..colon].trim().to_ascii_lowercase();
        let value = trimmed[colon + 1..].trim();
        if key.is_empty() || value.is_empty() {
            continue;
        }

        fields.insert(key, unquote(value));
    }

    fields
}

fn unquote(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 2
        && ((trimmed.starts_with('"') && trimmed.ends_with('"'))
            || (trimmed.starts_with('\'') && trimmed.ends_with('\'')))
    {
        trimmed[1..trimmed.len() - 1].to_string()
    } else {
        trimmed.to_string()
    }
}

fn frontmatter_value(fields: &HashMap<String, String>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = fields.get(*key) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn frontmatter_bool(fields: &HashMap<String, String>, keys: &[&str]) -> Option<bool> {
    let value = frontmatter_value(fields, keys)?;
    match value.to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" => Some(false),
        _ => None,
    }
}

fn derive_skill_name(path: &Path) -> String {
    let is_skill_markdown = path
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.eq_ignore_ascii_case("SKILL.md"));

    if is_skill_markdown {
        return path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| "skill".to_string());
    }

    path.file_stem()
        .and_then(|name| name.to_str())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "skill".to_string())
}

fn skill_sort_key(value: &Value) -> String {
    value
        .get("interface")
        .and_then(|interface| interface.get("displayName"))
        .and_then(Value::as_str)
        .or_else(|| value.get("name").and_then(Value::as_str))
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn canonical_key(path: &Path) -> String {
    std::fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .to_string()
}

async fn handle_thread_list(state: Arc<AppState>, _params: Value) -> Result<Value, (i64, String)> {
    let data: Vec<Value> = state
        .sessions
        .list_threads()
        .await
        .into_iter()
        .map(|(thread_id, entry)| {
            let preview = entry
                .messages
                .iter()
                .rev()
                .find(|m| m.role == "assistant")
                .map(|m| m.text.clone())
                .or_else(|| entry.messages.last().map(|m| m.text.clone()))
                .unwrap_or_default();
            json!({
                "id": thread_id,
                "preview": preview,
                "modelProvider": "anthropic",
                "createdAt": parse_iso_to_unix_or_now(&entry.created_at),
                "updatedAt": parse_iso_to_unix_or_now(&entry.updated_at),
                "cwd": entry.cwd,
                "cliVersion": "claude-app-server/0.1"
            })
        })
        .collect();

    Ok(json!({ "data": data, "nextCursor": Value::Null }))
}

async fn handle_thread_start(state: Arc<AppState>, params: Value) -> Result<Value, (i64, String)> {
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or("/")
        .to_string();
    let model = params
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or("claude-sonnet-4-6")
        .to_string();

    let thread_id = format!("thr_{}", Uuid::new_v4().simple());
    let session_id = Uuid::new_v4().to_string();
    let now = now_iso8601();

    state
        .sessions
        .upsert_thread(
            thread_id.clone(),
            ThreadEntry {
                claude_session_id: session_id,
                cwd: cwd.clone(),
                created_at: now.clone(),
                title: "New Claude Session".to_string(),
                updated_at: now,
                started: false,
                messages: vec![],
            },
        )
        .await;
    let _ = state.sessions.flush().await;

    Ok(json!({
        "thread": { "id": thread_id },
        "model": model,
        "cwd": cwd
    }))
}

async fn handle_thread_resume(state: Arc<AppState>, params: Value) -> Result<Value, (i64, String)> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or((-32602, "threadId is required".to_string()))?;

    let entry = state
        .sessions
        .get_thread(thread_id)
        .await
        .ok_or((-32004, "thread not found".to_string()))?;

    let mut turn_items: Vec<Value> = Vec::new();
    for msg in &entry.messages {
        if msg.role == "user" {
            turn_items.push(json!({
                "type": "userMessage",
                "content": [{"type":"text", "text": msg.text}]
            }));
        } else {
            turn_items.push(json!({
                "type": "agentMessage",
                "text": msg.text,
                "phase": "completed"
            }));
        }
    }

    Ok(json!({
        "thread": {
            "id": thread_id,
            "turns": [
                {
                    "id": format!("turn_{}", Uuid::new_v4().simple()),
                    "items": turn_items
                }
            ]
        },
        "model": "claude-sonnet-4-6",
        "cwd": entry.cwd
    }))
}

async fn handle_turn_start(state: Arc<AppState>, params: Value) -> Result<Value, (i64, String)> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or((-32602, "threadId is required".to_string()))?
        .to_string();

    let thread = state
        .sessions
        .get_thread(&thread_id)
        .await
        .ok_or((-32004, "thread not found".to_string()))?;

    let user_text =
        extract_input_text(&params).ok_or((-32602, "input[0].text is required".to_string()))?;
    let requested_model = params
        .get("model")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let requested_effort = params
        .get("effort")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);

    let turn_id = format!("turn_{}", Uuid::new_v4().simple());

    state
        .sessions
        .update_thread(&thread_id, |entry| {
            entry.messages.push(PersistedMessage {
                role: "user".to_string(),
                text: user_text.clone(),
                created_at: now_iso8601(),
            });
            entry.updated_at = now_iso8601();
            if entry.title == "New Claude Session" {
                entry.title = user_text.chars().take(80).collect();
            }
            entry.started = true;
        })
        .await;

    let _ = state.notify_tx.send(Notification {
        method: "turn/started".to_string(),
        params: json!({
            "threadId": thread_id,
            "turn": {"id": turn_id, "status": "inProgress"}
        }),
    });

    let runner = state.turns.clone();
    let thread_id_for_task = thread_id.clone();
    let notify_tx = state.notify_tx.clone();
    let sessions = state.sessions.clone();
    tokio::spawn(async move {
        runner
            .start_turn(
                thread_id_for_task,
                thread.cwd,
                user_text,
                thread.claude_session_id,
                thread.started,
                requested_model,
                requested_effort,
                notify_tx,
                sessions,
            )
            .await;
    });

    Ok(json!({ "turnId": turn_id }))
}

async fn handle_turn_interrupt(
    state: Arc<AppState>,
    params: Value,
) -> Result<Value, (i64, String)> {
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or((-32602, "threadId is required".to_string()))?;

    let interrupted = state.turns.interrupt(thread_id).await;
    if interrupted {
        let _ = state.notify_tx.send(Notification {
            method: "turn/completed".to_string(),
            params: json!({
                "threadId": thread_id,
                "turn": {"status": "interrupted"}
            }),
        });
    }

    Ok(json!({ "interrupted": interrupted }))
}

async fn handle_command_exec(params: Value) -> Result<Value, (i64, String)> {
    let command = params
        .get("command")
        .and_then(Value::as_array)
        .ok_or((-32602, "command is required".to_string()))?;

    let mut pieces: Vec<String> = command
        .iter()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect();
    if pieces.is_empty() {
        return Err((-32602, "command must be non-empty".to_string()));
    }

    let program = pieces.remove(0);
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);

    let mut cmd = Command::new(program);
    cmd.args(pieces);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }

    let output = cmd
        .output()
        .await
        .map_err(|e| (-32001, format!("command execution failed: {e}")))?;

    Ok(json!({
        "exitCode": output.status.code().unwrap_or(-1),
        "stdout": String::from_utf8_lossy(&output.stdout),
        "stderr": String::from_utf8_lossy(&output.stderr)
    }))
}

fn extract_input_text(params: &Value) -> Option<String> {
    let inputs = params.get("input")?.as_array()?;
    let mut merged = String::new();

    for item in inputs {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        if item_type != "text" {
            continue;
        }
        if let Some(text) = item.get("text").and_then(Value::as_str) {
            if !merged.is_empty() {
                merged.push('\n');
            }
            merged.push_str(text);
        }
    }

    if merged.trim().is_empty() {
        None
    } else {
        Some(merged)
    }
}

fn parse_iso_to_unix_or_now(value: &str) -> i64 {
    // Keep this lightweight; if parsing fails, preserve ordering using current time.
    if value.is_empty() {
        return now_unix_seconds();
    }

    if let Some(ts) = try_parse_iso(value) {
        ts
    } else {
        warn!("failed parsing stored timestamp: {value}");
        now_unix_seconds()
    }
}

fn try_parse_iso(value: &str) -> Option<i64> {
    // Very small parser for format: YYYY-MM-DDTHH:MM:SSZ
    if value.len() < 20 {
        return None;
    }
    let year: i32 = value.get(0..4)?.parse().ok()?;
    let month: u32 = value.get(5..7)?.parse().ok()?;
    let day: u32 = value.get(8..10)?.parse().ok()?;
    let hour: u32 = value.get(11..13)?.parse().ok()?;
    let minute: u32 = value.get(14..16)?.parse().ok()?;
    let second: u32 = value.get(17..19)?.parse().ok()?;
    if value.get(19..20)? != "Z" && !value.ends_with('Z') {
        return None;
    }
    datetime_to_unix(year, month, day, hour, minute, second)
}

fn datetime_to_unix(
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> Option<i64> {
    if !(1..=12).contains(&month) || day == 0 || hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let month_lengths = if is_leap(year) {
        [31u32, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31u32, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let max_day = month_lengths[(month - 1) as usize];
    if day > max_day {
        return None;
    }

    let mut days = 0i64;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    for m in 1..month {
        days += i64::from(month_lengths[(m - 1) as usize]);
    }
    days += i64::from(day - 1);

    Some(days * 86_400 + i64::from(hour) * 3_600 + i64::from(minute) * 60 + i64::from(second))
}

fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}
