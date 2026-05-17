use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

const POLL_INTERVAL_S: u64 = 60;
const ADMIN_LOCALHOST_PORT: u16 = 45877;
const DRAIN_SECS: u32 = 30;
const VERSION_FILE: &str = "/opt/battle-royale/VERSION.txt";

/// Manifest poller: replaces the prior Pub/Sub subscriber. The synchronous-pull
/// API silently returned Ok(None) on the server-agent's threads even when
/// messages were sitting in the subscription (~10 min of debugging confirmed:
/// manual long-polls from the same VM with the same SA *did* receive
/// messages; the agent's reqwest blocking calls did not). Rather than chase
/// the StreamingPull gRPC port, we poll versions.json directly — it's already
/// the source of truth, the client launcher already uses it, signature is
/// verified at consume time by both client and (now) server.
///
/// Trade-off: ~60s polling latency vs Pub/Sub's ~1s push. For "release just
/// landed, restart the dedicated server", 60s is fine. Also drops Pub/Sub
/// topic + subscription + IAM binding from terraform (cleanup separate).
#[derive(Deserialize)]
struct Manifest {
    #[serde(default)]
    latest: String,
}

pub fn watch_loop(client: &reqwest::blocking::Client, bucket: &str) -> Result<()> {
    let manifest_url = format!("https://storage.googleapis.com/{bucket}/versions.json");
    eprintln!(
        "release-watcher (manifest-poll): url={manifest_url} interval={POLL_INTERVAL_S}s"
    );
    loop {
        match check_once(client, &manifest_url) {
            Ok(None) => {}
            Ok(Some(target)) => {
                eprintln!(
                    "release-watcher: installed != latest; target={target} — draining"
                );
                if let Err(e) = drain_local_game(&target, DRAIN_SECS) {
                    eprintln!(
                        "release-watcher: drain RPC failed: {e:#} — forcing restart anyway"
                    );
                }
                std::thread::sleep(Duration::from_secs(u64::from(DRAIN_SECS) + 5));
                let status = std::process::Command::new("systemctl")
                    .args(["restart", "battle-royale-server.service"])
                    .status();
                eprintln!("release-watcher: systemctl restart status={status:?}");
                // Sleep before next check so the freshly-restarted game has
                // time to install the new version (refresh.sh + launcher
                // --update-only run via ExecStartPre, can take ~30-90s for
                // delta apply). Without this, the next poll could re-fire
                // drain on a still-old VERSION.txt.
                std::thread::sleep(Duration::from_secs(120));
            }
            Err(e) => {
                eprintln!("release-watcher: check failed: {e:#}");
            }
        }
        std::thread::sleep(Duration::from_secs(POLL_INTERVAL_S));
    }
}

fn check_once(client: &reqwest::blocking::Client, url: &str) -> Result<Option<String>> {
    let resp = client
        .get(url)
        .timeout(Duration::from_secs(15))
        .send()
        .context("GET manifest")?;
    if !resp.status().is_success() {
        anyhow::bail!("manifest GET returned {}", resp.status());
    }
    let manifest: Manifest = resp.json().context("parse manifest JSON")?;
    if manifest.latest.is_empty() {
        anyhow::bail!("manifest missing `latest`");
    }
    let installed = std::fs::read_to_string(VERSION_FILE)
        .with_context(|| format!("read {VERSION_FILE}"))?
        .trim()
        .to_string();
    if installed == manifest.latest {
        Ok(None)
    } else {
        Ok(Some(manifest.latest))
    }
}

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
