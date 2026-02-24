mod claude_runner;
mod handlers;
mod protocol;
mod session;
mod transport;

use clap::Parser;
use handlers::AppState;
use session::SessionStore;
use std::net::SocketAddr;
use tokio::sync::mpsc;

#[derive(Debug, Parser)]
#[command(
    name = "claude-app-server",
    version,
    about = "WebSocket JSON-RPC adapter for Claude CLI"
)]
struct Args {
    #[arg(long, default_value = "ws://0.0.0.0:8390")]
    listen: String,
}

#[tokio::main]
async fn main() {
    setup_logging();

    let args = Args::parse();
    let addr = match parse_listen_addr(&args.listen) {
        Ok(addr) => addr,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(2);
        }
    };

    let sessions = match SessionStore::load_default().await {
        Ok(store) => store,
        Err(err) => {
            eprintln!("failed loading sessions: {err}");
            std::process::exit(2);
        }
    };

    let (notify_tx, _notify_rx_unused) = mpsc::unbounded_channel();
    let app = AppState::new(sessions, notify_tx);

    if let Err(err) = transport::serve(addr, app).await {
        eprintln!("server error: {err}");
        std::process::exit(1);
    }
}

fn setup_logging() {
    let _ = tracing_subscriber::fmt().try_init();
}

fn parse_listen_addr(url: &str) -> Result<SocketAddr, String> {
    let without_scheme = url
        .strip_prefix("ws://")
        .ok_or_else(|| "--listen must start with ws://".to_string())?;

    // Allow ws://[::]:PORT and ws://HOST:PORT
    without_scheme
        .parse::<SocketAddr>()
        .map_err(|e| format!("invalid listen addr `{url}`: {e}"))
}
