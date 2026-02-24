use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{Duration, sleep};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThreadEntry {
    #[serde(rename = "claudeSessionId")]
    pub claude_session_id: String,
    pub cwd: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
    pub title: String,
    #[serde(rename = "updatedAt")]
    pub updated_at: String,
    #[serde(default)]
    pub started: bool,
    #[serde(default)]
    pub messages: Vec<PersistedMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistedMessage {
    pub role: String,
    pub text: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionFile {
    pub threads: HashMap<String, ThreadEntry>,
}

#[derive(Clone)]
pub struct SessionStore {
    path: Arc<PathBuf>,
    state: Arc<RwLock<SessionFile>>,
}

impl SessionStore {
    pub async fn load_default() -> Result<Self, String> {
        let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
        let base = Path::new(&home).join(".claude-app-server");
        tokio::fs::create_dir_all(&base)
            .await
            .map_err(|e| format!("failed to create state dir: {e}"))?;
        let path = base.join("sessions.json");
        let file = if path.exists() {
            match tokio::fs::read_to_string(&path).await {
                Ok(raw) => serde_json::from_str::<SessionFile>(&raw).unwrap_or_default(),
                Err(_) => SessionFile::default(),
            }
        } else {
            SessionFile::default()
        };

        let store = Self {
            path: Arc::new(path),
            state: Arc::new(RwLock::new(file)),
        };

        // Avoid blocking on each write burst; periodic flush still keeps metadata durable.
        let cloned = store.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_secs(4)).await;
                let _ = cloned.flush().await;
            }
        });

        Ok(store)
    }

    pub async fn flush(&self) -> Result<(), String> {
        let snapshot = self.state.read().await.clone();
        let data = serde_json::to_vec_pretty(&snapshot)
            .map_err(|e| format!("failed to encode session file: {e}"))?;
        tokio::fs::write(&*self.path, data)
            .await
            .map_err(|e| format!("failed to write session file: {e}"))
    }

    pub async fn list_threads(&self) -> Vec<(String, ThreadEntry)> {
        let guard = self.state.read().await;
        let mut threads: Vec<_> = guard
            .threads
            .iter()
            .map(|(id, entry)| (id.clone(), entry.clone()))
            .collect();
        threads.sort_by(|a, b| b.1.updated_at.cmp(&a.1.updated_at));
        threads
    }

    pub async fn get_thread(&self, thread_id: &str) -> Option<ThreadEntry> {
        self.state.read().await.threads.get(thread_id).cloned()
    }

    pub async fn upsert_thread(&self, thread_id: String, entry: ThreadEntry) {
        self.state.write().await.threads.insert(thread_id, entry);
    }

    pub async fn update_thread<F>(&self, thread_id: &str, update: F)
    where
        F: FnOnce(&mut ThreadEntry),
    {
        if let Some(entry) = self.state.write().await.threads.get_mut(thread_id) {
            update(entry);
        }
    }
}

pub fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    // Minimal RFC3339-like UTC formatting without extra dependencies.
    let dt = chrono_like_utc(ts);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second
    )
}

pub fn now_unix_seconds() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Debug, Clone, Copy)]
struct UtcDateTime {
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
}

fn chrono_like_utc(mut unix: i64) -> UtcDateTime {
    let second = (unix % 60) as u32;
    unix /= 60;
    let minute = (unix % 60) as u32;
    unix /= 60;
    let hour = (unix % 24) as u32;
    let mut days = unix / 24;

    let mut year: i32 = 1970;
    loop {
        let leap = is_leap(year);
        let d = if leap { 366 } else { 365 };
        if days >= d {
            days -= d;
            year += 1;
        } else {
            break;
        }
    }

    let month_lengths = if is_leap(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    let mut month = 1u32;
    for len in month_lengths {
        if days >= i64::from(len) {
            days -= i64::from(len);
            month += 1;
        } else {
            break;
        }
    }

    UtcDateTime {
        year,
        month,
        day: (days + 1) as u32,
        hour,
        minute,
        second,
    }
}

fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}
