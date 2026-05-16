use anyhow::{Context, Result};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde::Deserialize;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::metadata::{AccessToken, Metadata};

const SUBSCRIPTION: &str = "battle-royale-server-release";
const ADMIN_LOCALHOST_PORT: u16 = 45877;
const DRAIN_SECS: u32 = 30;

/// Long-poll the release pub/sub subscription. On message: tell the local
/// game to drain + quit, ack the message, then return to the caller (who
/// loops). systemd respawns the game; the new process pulls the latest
/// version via refresh.sh.
pub fn watch_loop(
    client: &reqwest::blocking::Client,
    md: &Metadata,
    token: &mut AccessToken,
) -> Result<()> {
    loop {
        token.refresh_if_needed(client).ok();
        match pull_one(client, md, token) {
            Ok(Some(PullMessage { ack_id, payload })) => {
                eprintln!("release-watcher: received {payload}");
                // Ack first so a crash during drain/restart doesn't cause
                // Pub/Sub to redeliver the same release and trigger a double
                // restart loop.
                if let Err(e) = ack(client, md, token, &ack_id) {
                    eprintln!("release-watcher: ack failed: {e:#}");
                }
                if let Err(e) = drain_local_game(&payload, DRAIN_SECS) {
                    eprintln!("release-watcher: drain RPC failed: {e:#} — forcing restart anyway");
                }
                std::thread::sleep(Duration::from_secs(u64::from(DRAIN_SECS) + 5));
                let _ = std::process::Command::new("systemctl")
                    .args(["restart", "battle-royale-server.service"])
                    .status();
            }
            Ok(None) => {
                // pull returned no messages within timeout; loop and try again
            }
            Err(e) => {
                eprintln!("release-watcher: pull error: {e:#}");
                std::thread::sleep(Duration::from_secs(15));
            }
        }
    }
}

#[derive(Debug)]
struct PullMessage {
    ack_id: String,
    payload: String,
}

#[derive(Deserialize)]
struct PullResponse {
    #[serde(default)]
    received_messages: Vec<ReceivedMessage>,
}

#[derive(Deserialize)]
struct ReceivedMessage {
    #[serde(rename = "ackId")]
    ack_id: String,
    message: PubsubMessage,
}

#[derive(Deserialize)]
struct PubsubMessage {
    #[serde(default)]
    data: String,
}

fn pull_one(
    client: &reqwest::blocking::Client,
    md: &Metadata,
    token: &AccessToken,
) -> Result<Option<PullMessage>> {
    let url = format!(
        "https://pubsub.googleapis.com/v1/projects/{}/subscriptions/{}:pull",
        md.project_id, SUBSCRIPTION
    );
    let resp = client
        .post(&url)
        .bearer_auth(token.value())
        .json(&serde_json::json!({"maxMessages": 1, "returnImmediately": false}))
        .timeout(Duration::from_secs(40))
        .send()
        .context("pubsub.pull")?;
    if !resp.status().is_success() {
        anyhow::bail!("pull returned {}", resp.status());
    }
    let body: PullResponse = resp.json().context("parse pull response")?;
    let Some(rm) = body.received_messages.into_iter().next() else {
        return Ok(None);
    };
    let payload_bytes = B64
        .decode(rm.message.data.as_bytes())
        .context("decode pubsub message data (base64)")?;
    let payload = String::from_utf8(payload_bytes).context("message data not utf-8")?;
    Ok(Some(PullMessage {
        ack_id: rm.ack_id,
        payload,
    }))
}

fn ack(
    client: &reqwest::blocking::Client,
    md: &Metadata,
    token: &AccessToken,
    ack_id: &str,
) -> Result<()> {
    let url = format!(
        "https://pubsub.googleapis.com/v1/projects/{}/subscriptions/{}:acknowledge",
        md.project_id, SUBSCRIPTION
    );
    let resp = client
        .post(&url)
        .bearer_auth(token.value())
        .json(&serde_json::json!({"ackIds": [ack_id]}))
        .send()
        .context("pubsub.ack")?;
    if !resp.status().is_success() {
        anyhow::bail!("ack returned {}", resp.status());
    }
    Ok(())
}

/// Open a TCP connection to the in-process AdminListener on localhost and
/// ask the game to drain players and quit cleanly. Errors are propagated;
/// the caller decides whether to force restart anyway.
fn drain_local_game(target_version: &str, drain_secs: u32) -> Result<()> {
    let payload = serde_json::json!({
        "cmd": "shutdown_for_update",
        "drain_s": drain_secs,
        "target_version": target_version,
    });
    let mut sock = TcpStream::connect(("127.0.0.1", ADMIN_LOCALHOST_PORT))
        .with_context(|| format!("connect localhost:{ADMIN_LOCALHOST_PORT}"))?;
    sock.set_write_timeout(Some(Duration::from_secs(5))).ok();
    sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
    let line = format!("{}\n", payload);
    sock.write_all(line.as_bytes()).context("write admin cmd")?;
    sock.flush().ok();
    let mut ack_buf = [0u8; 64];
    let _ = sock.read(&mut ack_buf);
    Ok(())
}

