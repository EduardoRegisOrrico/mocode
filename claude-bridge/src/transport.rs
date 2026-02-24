use crate::handlers::{AppState, handle_request};
use crate::protocol::{Notification, Request, Response};
use futures_util::{SinkExt, StreamExt};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::Message;
use tracing::{error, info, warn};

pub async fn serve(addr: SocketAddr, app: AppState) -> Result<(), String> {
    let listener = TcpListener::bind(addr)
        .await
        .map_err(|e| format!("failed to bind {addr}: {e}"))?;
    info!("claude-app-server listening on ws://{addr}");

    let app = Arc::new(app);

    loop {
        let (stream, peer) = listener
            .accept()
            .await
            .map_err(|e| format!("accept failed: {e}"))?;
        let app = app.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, peer, app).await {
                warn!("connection {peer} ended with error: {err}");
            }
        });
    }
}

async fn handle_connection(
    stream: TcpStream,
    peer: SocketAddr,
    app: Arc<AppState>,
) -> Result<(), String> {
    let ws = accept_async(stream)
        .await
        .map_err(|e| format!("websocket handshake failed: {e}"))?;

    let (mut writer, mut reader) = ws.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    let (notify_tx, mut notify_rx) = mpsc::unbounded_channel::<Notification>();

    let state = Arc::new(AppState {
        sessions: app.sessions.clone(),
        turns: app.turns.clone(),
        logins: app.logins.clone(),
        notify_tx: notify_tx.clone(),
    });

    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Err(err) = writer.send(msg).await {
                return Err::<(), String>(format!("send failed: {err}"));
            }
        }
        Ok(())
    });

    let out_tx_for_notifications = out_tx.clone();
    let notification_task = tokio::spawn(async move {
        while let Some(notification) = notify_rx.recv().await {
            let payload = serde_json::to_string(&notification)
                .map_err(|e| format!("serialize notification failed: {e}"))?;
            out_tx_for_notifications
                .send(Message::Text(payload))
                .map_err(|e| format!("enqueue notification failed: {e}"))?;
        }
        Ok::<(), String>(())
    });

    while let Some(next) = reader.next().await {
        match next {
            Ok(Message::Text(text)) => {
                let request: Request = match serde_json::from_str(&text) {
                    Ok(req) => req,
                    Err(err) => {
                        warn!("invalid JSON-RPC from {peer}: {err}");
                        continue;
                    }
                };
                let response = handle_request(state.clone(), request).await;
                if let Some(response) = response {
                    enqueue_response(&out_tx, response)?;
                }
            }
            Ok(Message::Ping(payload)) => {
                out_tx
                    .send(Message::Pong(payload))
                    .map_err(|e| format!("failed to enqueue pong: {e}"))?;
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(err) => {
                error!("read error from {peer}: {err}");
                break;
            }
        }
    }

    drop(out_tx);
    drop(notify_tx);
    let _ = notification_task.await;
    let _ = write_task.await;
    info!("connection closed: {peer}");
    Ok(())
}

fn enqueue_response(
    out_tx: &mpsc::UnboundedSender<Message>,
    response: Response,
) -> Result<(), String> {
    let payload =
        serde_json::to_string(&response).map_err(|e| format!("serialize response failed: {e}"))?;
    out_tx
        .send(Message::Text(payload))
        .map_err(|e| format!("enqueue response failed: {e}"))
}
