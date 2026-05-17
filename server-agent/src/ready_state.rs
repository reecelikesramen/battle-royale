use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::metadata::{AccessToken, Metadata};

const ADMIN_LOCALHOST_PORT: u16 = 45877;
const POLL_INTERVAL_S: u64 = 15;
const STATE_OBJECT: &str = "server-state.json";

#[derive(Serialize, Default)]
struct State {
    ready: bool,
    version: String,
    sha: String,
    ts: u64,
}

#[derive(Deserialize, Default)]
struct PingReply {
    #[serde(default)]
    ok: bool,
    #[serde(default)]
    ready: bool,
    #[serde(default)]
    version: String,
    #[serde(default)]
    sha: String,
}

/// Long-running thread. Every POLL_INTERVAL_S seconds, asks the local game
/// process (via admin_listener.gd's ping cmd) whether it's bound and ready
/// to accept clients, then mirrors the result to gs://$bucket/server-state.json.
///
/// The wake function reads that object to decide whether to flip the menu
/// Wake button to "Server online". Without this, the button goes green as
/// soon as the VM is RUNNING (~5s after wake) — but the game takes another
/// 30-60s to bind UDP 45876, so users were getting failed connects despite
/// the "online" indicator.
pub fn watch_loop(
    client: &reqwest::blocking::Client,
    _md: &Metadata,
    token: &mut AccessToken,
    bucket: &str,
) -> Result<()> {
    loop {
        // Pre-warm the token — first GCS write would otherwise stall under it.
        token.refresh_if_needed(client).ok();

        let state = match ping_admin() {
            Ok(reply) if reply.ok => State {
                ready: reply.ready,
                version: reply.version,
                sha: reply.sha,
                ts: now_unix(),
            },
            Ok(_) => {
                // Admin spoke but reported failure (malformed cmd, etc). Not ready.
                State {
                    ts: now_unix(),
                    ..Default::default()
                }
            }
            Err(e) => {
                // TCP refused — game process not up yet, or admin listener crashed.
                // Wake-fn will see stale-and-not-ready ⇒ "starting".
                eprintln!("ready_state: ping failed: {e:#}");
                State {
                    ts: now_unix(),
                    ..Default::default()
                }
            }
        };

        if let Err(e) = write_state(client, token, bucket, &state) {
            eprintln!("ready_state: GCS write failed: {e:#}");
        }

        std::thread::sleep(Duration::from_secs(POLL_INTERVAL_S));
    }
}

fn ping_admin() -> Result<PingReply> {
    let mut sock = TcpStream::connect(("127.0.0.1", ADMIN_LOCALHOST_PORT))
        .with_context(|| format!("connect localhost:{ADMIN_LOCALHOST_PORT}"))?;
    sock.set_write_timeout(Some(Duration::from_secs(3))).ok();
    sock.set_read_timeout(Some(Duration::from_secs(3))).ok();
    sock.write_all(b"{\"cmd\":\"ping\"}\n")
        .context("write ping")?;
    sock.flush().ok();
    // admin_listener replies one line then closes the connection, so a
    // blocking read_to_string completes naturally on EOF.
    let mut buf = String::new();
    sock.read_to_string(&mut buf).ok();
    let line = buf.lines().next().unwrap_or("");
    if line.is_empty() {
        anyhow::bail!("empty ping reply");
    }
    serde_json::from_str(line).with_context(|| format!("parse ping reply: {line:?}"))
}

fn write_state(
    client: &reqwest::blocking::Client,
    token: &AccessToken,
    bucket: &str,
    state: &State,
) -> Result<()> {
    // Multipart upload so we can set the object's *metadata* cacheControl —
    // setting it as a request header (prior approach) only affected the
    // upload PUT's cache behaviour, not the object's. The bucket grants
    // allUsers objectViewer, so GCS defaults the object's cacheControl to
    // `public, max-age=3600` and the GFE happily serves wake-fn a 30+ min
    // stale generation, defeating the whole freshness check. With
    // metadata.cacheControl = no-cache the CDN won't cache anywhere.
    let url = format!(
        "https://storage.googleapis.com/upload/storage/v1/b/{}/o?uploadType=multipart",
        bucket
    );
    let body_json = serde_json::to_vec(state).context("serialize state")?;
    let metadata = serde_json::json!({
        "name": STATE_OBJECT,
        "cacheControl": "no-cache, no-store, max-age=0",
        "contentType": "application/json",
    });
    let boundary = "br-server-state-boundary";
    let mut multipart: Vec<u8> = Vec::with_capacity(body_json.len() + 512);
    use std::io::Write as _;
    write!(
        &mut multipart,
        "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n"
    )
    .unwrap();
    multipart.extend_from_slice(&serde_json::to_vec(&metadata).unwrap());
    write!(
        &mut multipart,
        "\r\n--{boundary}\r\nContent-Type: application/json\r\n\r\n"
    )
    .unwrap();
    multipart.extend_from_slice(&body_json);
    write!(&mut multipart, "\r\n--{boundary}--\r\n").unwrap();
    let resp = client
        .post(&url)
        .bearer_auth(token.value())
        .header(
            "Content-Type",
            format!("multipart/related; boundary={boundary}"),
        )
        .body(multipart)
        .send()
        .context("storage.objects.insert (multipart)")?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().unwrap_or_default();
        anyhow::bail!("storage.objects.insert returned {status}: {body}");
    }
    Ok(())
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
