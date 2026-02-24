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

        let mut assistant = String::new();
        let mut reader = BufReader::new(stdout).lines();

        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    if let Ok(value) = serde_json::from_str::<Value>(&line) {
                        process_stream_event(&value, &thread_id, &notify_tx, &mut assistant);
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

        if !assistant.trim().is_empty() {
            sessions
                .update_thread(&thread_id, |entry| {
                    entry.messages.push(PersistedMessage {
                        role: "assistant".to_string(),
                        text: assistant.clone(),
                        created_at: now_iso8601(),
                    });
                    entry.updated_at = now_iso8601();
                    if entry.title.trim().is_empty() {
                        entry.title = assistant.chars().take(80).collect();
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

fn process_stream_event(
    value: &Value,
    thread_id: &str,
    notify_tx: &mpsc::UnboundedSender<Notification>,
    assistant: &mut String,
) {
    let event_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    if event_type == "assistant" {
        if let Some(text) = extract_assistant_text(value) {
            assistant.push_str(&text);
            let _ = notify_tx.send(Notification {
                method: "item/agentMessage/delta".to_string(),
                params: json!({"threadId": thread_id, "delta": text}),
            });
        }
        return;
    }

    if event_type == "content_block_delta" {
        if let Some(delta) = value
            .get("delta")
            .and_then(Value::as_object)
            .and_then(|d| d.get("text"))
            .and_then(Value::as_str)
            .or_else(|| {
                value
                    .get("delta")
                    .and_then(Value::as_object)
                    .and_then(|d| d.get("text_delta"))
                    .and_then(Value::as_str)
            })
        {
            if !delta.is_empty() {
                assistant.push_str(delta);
                let _ = notify_tx.send(Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params: json!({"threadId": thread_id, "delta": delta}),
                });
            }
        }
        return;
    }

    if event_type == "content_block_start" {
        if let Some(tool_name) = value
            .get("content_block")
            .and_then(Value::as_object)
            .and_then(|b| b.get("name"))
            .and_then(Value::as_str)
        {
            let normalized = tool_name.to_ascii_lowercase();
            let mapped = if normalized.contains("bash") || normalized.contains("command") {
                "commandExecution"
            } else if normalized.contains("edit") || normalized.contains("write") {
                "fileChange"
            } else {
                "mcpToolCall"
            };
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
        return;
    }

    if event_type == "tool_result" {
        let is_bash = value
            .get("tool_name")
            .and_then(Value::as_str)
            .map(|n| n.eq_ignore_ascii_case("bash"))
            .unwrap_or(false);

        if is_bash {
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
        return;
    }

    if event_type == "result" {
        if assistant.trim().is_empty()
            && let Some(text) = value.get("result").and_then(Value::as_str)
        {
            if !text.is_empty() {
                assistant.push_str(text);
                let _ = notify_tx.send(Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params: json!({"threadId": thread_id, "delta": text}),
                });
            }
        }
    }
}

fn extract_assistant_text(value: &Value) -> Option<String> {
    let content = value
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)?;

    let mut text = String::new();
    for item in content {
        if item.get("type").and_then(Value::as_str) == Some("text")
            && let Some(chunk) = item.get("text").and_then(Value::as_str)
        {
            text.push_str(chunk);
        }
    }

    if text.is_empty() { None } else { Some(text) }
}
