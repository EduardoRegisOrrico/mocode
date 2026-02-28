use crate::protocol::Notification;
use crate::session::{PersistedMessage, SessionStore, now_iso8601};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, mpsc};
use tracing::{error, warn};

// ---------------------------------------------------------------------------
// StreamState — replaces the bare `assistant: String` accumulator
// ---------------------------------------------------------------------------

struct PendingTool {
    name: String,
    input: Value,
}

struct StreamState {
    /// Accumulated assistant text for persistence.
    assistant: String,
    /// Set once we receive any `content_block_delta` with text — prevents the
    /// `assistant` event from duplicating the same text.
    had_text_deltas: bool,
    /// `tool_use` blocks keyed by their `id`, awaiting matching `tool_result`.
    pending_tools: HashMap<String, PendingTool>,
    /// Accumulated thinking text from `content_block_delta` thinking events.
    current_thinking: String,
    /// Number of thinking blocks already emitted (for dedup vs assistant fallback).
    thinking_blocks_emitted: usize,
    /// Tracks the type of the currently-open content block (e.g. "thinking", "text", "tool_use").
    active_block_type: Option<String>,
}

impl StreamState {
    fn new() -> Self {
        Self {
            assistant: String::new(),
            had_text_deltas: false,
            pending_tools: HashMap::new(),
            current_thinking: String::new(),
            thinking_blocks_emitted: 0,
            active_block_type: None,
        }
    }
}

// ---------------------------------------------------------------------------
// TurnManager
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct TurnManager {
    running: Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
}

impl TurnManager {
    pub fn new() -> Self {
        Self {
            running: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn interrupt(&self, thread_id: &str) -> bool {
        let child = {
            let mut guard = self.running.lock().await;
            guard.remove(thread_id)
        };

        if let Some(child) = child {
            let mut proc = child.lock().await;
            let _ = proc.kill().await;
            true
        } else {
            false
        }
    }

    pub async fn start_turn(
        &self,
        thread_id: String,
        cwd: String,
        prompt: String,
        claude_session_id: String,
        resume_existing: bool,
        model: Option<String>,
        effort: Option<String>,
        notify_tx: mpsc::UnboundedSender<Notification>,
        sessions: SessionStore,
    ) {
        let child_result = spawn_claude(
            &cwd,
            &prompt,
            &claude_session_id,
            resume_existing,
            model.as_deref(),
            effort.as_deref(),
        )
        .await;
        let mut child = match child_result {
            Ok(child) => child,
            Err(err) => {
                let _ = notify_tx.send(Notification {
                    method: "item/completed".to_string(),
                    params: json!({
                        "threadId": thread_id,
                        "item": {
                            "type": "agentMessage",
                            "text": format!("Failed to launch claude CLI: {err}")
                        }
                    }),
                });
                let _ = notify_tx.send(Notification {
                    method: "turn/completed".to_string(),
                    params: json!({
                        "threadId": thread_id,
                        "turn": {"status": "failed"}
                    }),
                });
                return;
            }
        };

        let stdout = child.stdout.take();
        let Some(stdout) = stdout else {
            let _ = notify_tx.send(Notification {
                method: "turn/completed".to_string(),
                params: json!({
                    "threadId": thread_id,
                    "turn": {"status": "failed"}
                }),
            });
            return;
        };
        let stderr = child.stderr.take();
        let stderr_task = stderr.map(|stream| {
            tokio::spawn(async move {
                let mut reader = BufReader::new(stream);
                let mut text = String::new();
                let _ = reader.read_to_string(&mut text).await;
                text
            })
        });

        let child_arc = Arc::new(Mutex::new(child));
        {
            let mut guard = self.running.lock().await;
            guard.insert(thread_id.clone(), child_arc.clone());
        }

        let mut state = StreamState::new();
        let mut reader = BufReader::new(stdout).lines();

        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    if let Ok(value) = serde_json::from_str::<Value>(&line) {
                        process_stream_event(&value, &thread_id, &notify_tx, &mut state);
                    }
                }
                Ok(None) => break,
                Err(err) => {
                    warn!("error reading claude stream: {err}");
                    break;
                }
            }
        }

        let status = {
            let mut guard = child_arc.lock().await;
            match guard.wait().await {
                Ok(s) => s,
                Err(err) => {
                    error!("failed waiting for claude process: {err}");
                    let _ = notify_tx.send(Notification {
                        method: "turn/completed".to_string(),
                        params: json!({
                            "threadId": thread_id,
                            "turn": {"status": "failed"}
                        }),
                    });
                    cleanup_running(&self.running, &thread_id).await;
                    return;
                }
            }
        };

        cleanup_running(&self.running, &thread_id).await;
        let stderr_output = if let Some(task) = stderr_task {
            task.await.unwrap_or_default()
        } else {
            String::new()
        };

        let assistant = &state.assistant;
        if !assistant.trim().is_empty() {
            let text = assistant.clone();
            sessions
                .update_thread(&thread_id, |entry| {
                    entry.messages.push(PersistedMessage {
                        role: "assistant".to_string(),
                        text: text.clone(),
                        created_at: now_iso8601(),
                    });
                    entry.updated_at = now_iso8601();
                    if entry.title.trim().is_empty() {
                        entry.title = text.chars().take(80).collect();
                    }
                })
                .await;
        } else if !status.success() {
            // If a turn fails before producing assistant output, allow a fresh
            // session attempt on the next turn instead of forcing --resume.
            sessions
                .update_thread(&thread_id, |entry| {
                    entry.started = false;
                    entry.updated_at = now_iso8601();
                })
                .await;
        }
        let _ = sessions.flush().await;

        let final_status = if status.success() {
            "completed"
        } else {
            "failed"
        };

        if !assistant.trim().is_empty() {
            let _ = notify_tx.send(Notification {
                method: "item/completed".to_string(),
                params: json!({
                    "threadId": thread_id,
                    "item": {
                        "type": "agentMessage",
                        "text": assistant
                    }
                }),
            });
        } else if !status.success() {
            let message = if stderr_output.trim().is_empty() {
                format!("Claude CLI exited with status {status}")
            } else {
                stderr_output.trim().to_string()
            };
            let _ = notify_tx.send(Notification {
                method: "item/completed".to_string(),
                params: json!({
                    "threadId": thread_id,
                    "item": {
                        "type": "agentMessage",
                        "text": message
                    }
                }),
            });
        }

        let _ = notify_tx.send(Notification {
            method: "turn/completed".to_string(),
            params: json!({
                "threadId": thread_id,
                "turn": {"status": final_status}
            }),
        });
    }
}

async fn cleanup_running(
    running: &Arc<Mutex<HashMap<String, Arc<Mutex<Child>>>>>,
    thread_id: &str,
) {
    let mut guard = running.lock().await;
    guard.remove(thread_id);
}

async fn spawn_claude(
    cwd: &str,
    prompt: &str,
    session_id: &str,
    resume_existing: bool,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<Child, String> {
    let mut cmd = Command::new("claude");
    cmd.arg("-p")
        .arg(prompt)
        .arg("--output-format")
        .arg("stream-json");

    if resume_existing {
        cmd.arg("--resume").arg(session_id);
    } else {
        cmd.arg("--session-id").arg(session_id);
    }

    if let Some(model) = model.map(str::trim).filter(|m| !m.is_empty()) {
        cmd.arg("--model").arg(model);
    }
    if let Some(effort) = effort.map(str::trim).filter(|e| !e.is_empty()) {
        cmd.arg("--effort").arg(effort);
    }

    cmd.arg("--verbose")
        // Keep both flags for compatibility across Claude CLI releases.
        .arg("--allow-dangerously-skip-permissions")
        .arg("--dangerously-skip-permissions")
        .arg("--max-turns")
        .arg("50")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .current_dir(cwd);

    cmd.spawn()
        .map_err(|e| format!("failed to spawn claude: {e}"))
}

// ---------------------------------------------------------------------------
// Stream event processing
// ---------------------------------------------------------------------------

fn process_stream_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let event_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    match event_type {
        "assistant" => handle_assistant_event(value, thread_id, notify_tx, state),
        "content_block_start" => handle_content_block_start(value, thread_id, notify_tx, state),
        "content_block_delta" => handle_content_block_delta(value, thread_id, notify_tx, state),
        "content_block_stop" => handle_content_block_stop(thread_id, notify_tx, state),
        "tool_result" => handle_tool_result_event(value, thread_id, notify_tx, state),
        "user" => handle_user_event(value, thread_id, notify_tx, state),
        "result" => handle_result_event(value, thread_id, notify_tx, state),
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// assistant — full message with all content blocks
// ---------------------------------------------------------------------------

fn handle_assistant_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let content = match value
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)
    {
        Some(c) => c,
        None => return,
    };

    for block in content {
        let block_type = block.get("type").and_then(Value::as_str).unwrap_or_default();

        match block_type {
            "text" => {
                // Only use text from the assistant event if we never got
                // content_block_delta text events (prevents duplication).
                if !state.had_text_deltas {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        if !text.is_empty() {
                            state.assistant.push_str(text);
                            let _ = notify_tx.send(Notification {
                                method: "item/agentMessage/delta".to_string(),
                                params: json!({"threadId": thread_id, "delta": text}),
                            });
                        }
                    }
                }
            }
            "thinking" => {
                // Emit thinking blocks that weren't already streamed via
                // content_block_delta → content_block_stop.
                if let Some(thinking) = block.get("thinking").and_then(Value::as_str) {
                    if !thinking.is_empty() && state.thinking_blocks_emitted == 0 {
                        let _ = notify_tx.send(Notification {
                            method: "item/completed".to_string(),
                            params: json!({
                                "threadId": thread_id,
                                "item": {
                                    "type": "reasoning",
                                    "text": thinking
                                }
                            }),
                        });
                    }
                }
            }
            "tool_use" => {
                // Register tool_use blocks so we can look them up when the
                // matching tool_result arrives.
                if let Some(id) = block.get("id").and_then(Value::as_str) {
                    let name = block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    let input = block.get("input").cloned().unwrap_or(Value::Null);
                    state.pending_tools.insert(
                        id.to_string(),
                        PendingTool { name, input },
                    );
                }
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------------------
// content_block_start — tool invocations + block type tracking
// ---------------------------------------------------------------------------

fn handle_content_block_start(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let block = match value.get("content_block").and_then(Value::as_object) {
        Some(b) => b,
        None => return,
    };

    let block_type = block
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    state.active_block_type = Some(block_type.to_string());

    if block_type == "tool_use" {
        // Register the pending tool early (input may be empty here and filled
        // via deltas, but we capture name + id).
        if let Some(id) = block.get("id").and_then(Value::as_str) {
            let name = block
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let input = block.get("input").cloned().unwrap_or(Value::Null);
            state
                .pending_tools
                .entry(id.to_string())
                .or_insert(PendingTool { name: name.clone(), input });

            let normalized = name.to_ascii_lowercase();
            let mapped = map_tool_type(&normalized);
            let _ = notify_tx.send(Notification {
                method: "item/started".to_string(),
                params: json!({
                    "threadId": thread_id,
                    "item": {
                        "type": mapped,
                        "status": "inProgress"
                    }
                }),
            });
        }
    }
}

// ---------------------------------------------------------------------------
// content_block_delta — text + thinking streaming
// ---------------------------------------------------------------------------

fn handle_content_block_delta(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let delta = match value.get("delta").and_then(Value::as_object) {
        Some(d) => d,
        None => return,
    };

    let delta_type = delta
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    match delta_type {
        "text_delta" | "text" => {
            let text = delta
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !text.is_empty() {
                state.had_text_deltas = true;
                state.assistant.push_str(text);
                let _ = notify_tx.send(Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params: json!({"threadId": thread_id, "delta": text}),
                });
            }
        }
        "thinking_delta" | "thinking" => {
            let thinking = delta
                .get("thinking")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !thinking.is_empty() {
                state.current_thinking.push_str(thinking);
            }
        }
        _ => {
            // Fallback: check for bare text/text_delta keys regardless of
            // delta type, for forward compatibility.
            if let Some(text) = delta.get("text").and_then(Value::as_str) {
                if !text.is_empty() {
                    state.had_text_deltas = true;
                    state.assistant.push_str(text);
                    let _ = notify_tx.send(Notification {
                        method: "item/agentMessage/delta".to_string(),
                        params: json!({"threadId": thread_id, "delta": text}),
                    });
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// content_block_stop — flush accumulated thinking
// ---------------------------------------------------------------------------

fn handle_content_block_stop(
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    // If the block that just ended was a thinking block, emit it.
    let was_thinking = state
        .active_block_type
        .as_deref()
        .map(|t| t == "thinking")
        .unwrap_or(false);

    if was_thinking && !state.current_thinking.is_empty() {
        let text = std::mem::take(&mut state.current_thinking);
        state.thinking_blocks_emitted += 1;
        let _ = notify_tx.send(Notification {
            method: "item/completed".to_string(),
            params: json!({
                "threadId": thread_id,
                "item": {
                    "type": "reasoning",
                    "text": text
                }
            }),
        });
    }

    state.active_block_type = None;
}

// ---------------------------------------------------------------------------
// tool_result — top-level event from Claude CLI
// ---------------------------------------------------------------------------

fn handle_tool_result_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let tool_name = value
        .get("tool_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let tool_use_id = value
        .get("tool_use_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    dispatch_tool_result(&tool_name, &tool_use_id, value, thread_id, notify_tx, state);
}

// ---------------------------------------------------------------------------
// user — may contain tool_result blocks in message.content[]
// ---------------------------------------------------------------------------

fn handle_user_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let content = match value
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)
    {
        Some(c) => c,
        None => return,
    };

    for block in content {
        let block_type = block.get("type").and_then(Value::as_str).unwrap_or_default();
        if block_type == "tool_result" {
            let tool_use_id = block
                .get("tool_use_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();

            // Extract the text content from the tool_result block.
            let result_text = extract_tool_result_content(block);

            // Look up the pending tool to get the name.
            let tool_name = state
                .pending_tools
                .get(&tool_use_id)
                .map(|p| p.name.clone())
                .unwrap_or_default();

            // Build a synthetic value with the fields dispatch_tool_result expects.
            let synthetic = json!({
                "tool_name": tool_name,
                "tool_use_id": tool_use_id,
                "content": result_text,
            });

            dispatch_tool_result(
                &tool_name,
                &tool_use_id,
                &synthetic,
                thread_id,
                notify_tx,
                state,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// result — fallback final text
// ---------------------------------------------------------------------------

fn handle_result_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    if state.assistant.trim().is_empty() {
        if let Some(text) = value.get("result").and_then(Value::as_str) {
            if !text.is_empty() {
                state.assistant.push_str(text);
                let _ = notify_tx.send(Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params: json!({"threadId": thread_id, "delta": text}),
                });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tool result dispatching — routes all tool results by tool name
// ---------------------------------------------------------------------------

fn dispatch_tool_result(
    tool_name: &str,
    tool_use_id: &str,
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let normalized = tool_name.to_ascii_lowercase();

    if normalized.contains("bash") || normalized.contains("command") {
        emit_command_execution(value, thread_id, notify_tx);
    } else if normalized.contains("edit") {
        emit_file_change_edit(tool_use_id, value, thread_id, notify_tx, state);
    } else if normalized.contains("write") {
        emit_file_change_write(tool_use_id, value, thread_id, notify_tx, state);
    } else if normalized.contains("websearch") || normalized.contains("web_search") {
        emit_web_search(tool_use_id, value, thread_id, notify_tx, state);
    } else if !normalized.is_empty() {
        emit_mcp_tool_call(tool_name, value, thread_id, notify_tx);
    }
}

// ---------------------------------------------------------------------------
// Emitters for each tool type
// ---------------------------------------------------------------------------

fn emit_command_execution(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
) {
    let output = value
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let exit_code = value.get("exit_code").and_then(Value::as_i64).unwrap_or(0);
    let _ = notify_tx.send(Notification {
        method: "item/completed".to_string(),
        params: json!({
            "threadId": thread_id,
            "item": {
                "type": "commandExecution",
                "command": value.get("command").and_then(Value::as_str).unwrap_or(""),
                "cwd": value.get("cwd").and_then(Value::as_str).unwrap_or(""),
                "status": if exit_code == 0 { "completed" } else { "failed" },
                "aggregatedOutput": output,
                "exitCode": exit_code as i32
            }
        }),
    });
}

fn emit_file_change_edit(
    tool_use_id: &str,
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let pending = state.pending_tools.remove(tool_use_id);
    let (file_path, diff) = if let Some(ref tool) = pending {
        let fp = tool
            .input
            .get("file_path")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let old = tool
            .input
            .get("old_string")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let new = tool
            .input
            .get("new_string")
            .and_then(Value::as_str)
            .unwrap_or_default();
        (fp.to_string(), generate_unified_diff(fp, old, new))
    } else {
        ("unknown".to_string(), String::new())
    };

    let content = value
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let _ = notify_tx.send(Notification {
        method: "item/completed".to_string(),
        params: json!({
            "threadId": thread_id,
            "item": {
                "type": "fileChange",
                "filePath": file_path,
                "kind": "edit",
                "status": "completed",
                "diff": diff,
                "content": content
            }
        }),
    });
}

fn emit_file_change_write(
    tool_use_id: &str,
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let pending = state.pending_tools.remove(tool_use_id);
    let (file_path, diff) = if let Some(ref tool) = pending {
        let fp = tool
            .input
            .get("file_path")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let file_content = tool
            .input
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let preview: String = file_content
            .lines()
            .take(20)
            .map(|l| format!("+{l}"))
            .collect::<Vec<_>>()
            .join("\n");
        let diff = format!("--- /dev/null\n+++ b/{fp}\n@@ @@\n{preview}");
        (fp.to_string(), diff)
    } else {
        ("unknown".to_string(), String::new())
    };

    let content = value
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();

    let _ = notify_tx.send(Notification {
        method: "item/completed".to_string(),
        params: json!({
            "threadId": thread_id,
            "item": {
                "type": "fileChange",
                "filePath": file_path,
                "kind": "create",
                "status": "completed",
                "diff": diff,
                "content": content
            }
        }),
    });
}

fn emit_web_search(
    tool_use_id: &str,
    _value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    state: &mut StreamState,
) {
    let pending = state.pending_tools.remove(tool_use_id);
    let query = pending
        .as_ref()
        .and_then(|p| p.input.get("query").and_then(Value::as_str))
        .unwrap_or("web search")
        .to_string();

    let _ = notify_tx.send(Notification {
        method: "item/completed".to_string(),
        params: json!({
            "threadId": thread_id,
            "item": {
                "type": "webSearch",
                "query": query,
                "status": "completed"
            }
        }),
    });
}

fn emit_mcp_tool_call(
    tool_name: &str,
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
) {
    let content = value
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();

    // Truncate very long tool results for the notification.
    let truncated = if content.len() > 2000 {
        format!("{}...\n(truncated)", &content[..2000])
    } else {
        content.to_string()
    };

    let _ = notify_tx.send(Notification {
        method: "item/completed".to_string(),
        params: json!({
            "threadId": thread_id,
            "item": {
                "type": "mcpToolCall",
                "toolName": tool_name,
                "status": "completed",
                "content": truncated
            }
        }),
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Map a lowercase tool name to the client item type.
fn map_tool_type(normalized: &str) -> &'static str {
    if normalized.contains("bash") || normalized.contains("command") {
        "commandExecution"
    } else if normalized.contains("edit") || normalized.contains("write") {
        "fileChange"
    } else if normalized.contains("websearch") || normalized.contains("web_search") {
        "webSearch"
    } else {
        "mcpToolCall"
    }
}

/// Generate a minimal unified diff from old_string → new_string.
fn generate_unified_diff(file_path: &str, old: &str, new: &str) -> String {
    let old_lines: Vec<&str> = old.lines().collect();
    let new_lines: Vec<&str> = new.lines().collect();

    let mut diff = format!("--- a/{file_path}\n+++ b/{file_path}\n@@ @@\n");
    for line in &old_lines {
        diff.push('-');
        diff.push_str(line);
        diff.push('\n');
    }
    for line in &new_lines {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
    }
    diff
}

/// Extract text content from a tool_result block's content array or string.
fn extract_tool_result_content(block: &Value) -> String {
    // content can be a string or an array of {type: "text", text: "..."}
    if let Some(s) = block.get("content").and_then(Value::as_str) {
        return s.to_string();
    }
    if let Some(arr) = block.get("content").and_then(Value::as_array) {
        let mut text = String::new();
        for item in arr {
            if item.get("type").and_then(Value::as_str) == Some("text") {
                if let Some(t) = item.get("text").and_then(Value::as_str) {
                    text.push_str(t);
                }
            }
        }
        return text;
    }
    String::new()
}
