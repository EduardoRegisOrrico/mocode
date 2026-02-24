use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    String(String),
    Number(i64),
}

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: Option<RequestId>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: RequestId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorBody>,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct Notification {
    pub method: String,
    pub params: Value,
}

impl Response {
    pub fn success(id: RequestId, result: Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: RequestId, code: i64, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(ErrorBody {
                code,
                message: message.into(),
            }),
        }
    }
}
