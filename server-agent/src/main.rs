use anyhow::{Context, Result};
use clap::Parser;
use std::time::{Duration, Instant};

mod idle;
mod metadata;
mod ready_state;
mod release;

#[derive(Parser, Debug)]
#[command(about = "Battle Royale dedicated-server companion agent")]
struct Args {
    /// Idle threshold in seconds before stopping the VM.
    #[arg(long, default_value_t = 600)]
    idle_secs: u64,

    /// Metric polling interval in seconds.
    #[arg(long, default_value_t = 60)]
    poll_secs: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();

    eprintln!(
        "server-agent starting (idle_secs={}, poll_secs={})",
        args.idle_secs, args.poll_secs
    );

    let md = metadata::Metadata::fetch().context("read GCE metadata; agent must run on a GCE VM")?;
    eprintln!(
        "metadata ok: project={} zone={} instance_name={} instance_id={}",
        md.project_id, md.zone, md.instance_name, md.instance_id
    );

    let mut idle = idle::IdleTracker::new(Duration::from_secs(args.idle_secs));

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;
    let mut token = metadata::AccessToken::default();

    // Spawn the release watcher: polls versions.json every 60s, triggers drain
    // + systemd restart on installed != latest. Used to be a Pub/Sub
    // subscriber but synchronous-pull on reqwest blocking turned out to
    // silently miss messages (see release.rs preamble).
    match std::env::var("BUCKET") {
        Ok(bucket) if !bucket.is_empty() => {
            std::thread::spawn(move || {
                let client = reqwest::blocking::Client::builder()
                    .timeout(Duration::from_secs(30))
                    .build()
                    .expect("build http client");
                if let Err(e) = release::watch_loop(&client, &bucket) {
                    eprintln!("release-watcher exited: {e:#}");
                }
            });
        }
        _ => eprintln!("release-watcher: BUCKET env unset; not polling manifest"),
    }

    // Spawn the ready-state thread. It pings the game over the loopback
    // admin socket and mirrors readiness + version into a GCS object the
    // wake function reads. BUCKET comes in via EnvironmentFile from the
    // systemd unit (battle-royale-agent.service → /etc/battle-royale/meta.env).
    match std::env::var("BUCKET") {
        Ok(bucket) if !bucket.is_empty() => {
            let md = metadata::Metadata::fetch().context("metadata for ready-state watcher")?;
            std::thread::spawn(move || {
                let client = reqwest::blocking::Client::builder()
                    .timeout(Duration::from_secs(15))
                    .build()
                    .expect("build http client");
                let mut token = metadata::AccessToken::default();
                if let Err(e) = ready_state::watch_loop(&client, &md, &mut token, &bucket) {
                    eprintln!("ready-state watcher exited: {e:#}");
                }
            });
        }
        _ => eprintln!("ready-state: BUCKET env var unset; not publishing readiness"),
    }

    loop {
        if let Err(e) = token.refresh_if_needed(&client) {
            eprintln!("token refresh failed: {e:#}");
            std::thread::sleep(Duration::from_secs(args.poll_secs));
            continue;
        }

        let now = Instant::now();
        match idle::current_players(&client, &md, &token) {
            Ok(players) => {
                if players > 0 {
                    idle.note_active(now);
                } else {
                    idle.note_idle(now);
                }
                if let Some(idle_for) = idle.idle_for(now) {
                    eprintln!("idle for {idle_for:?}");
                }
                if idle.should_shutdown(now) {
                    eprintln!("idle threshold reached; stopping VM");
                    if let Err(e) = stop_self(&client, &md, &token) {
                        eprintln!("stop_self failed: {e:#}");
                    } else {
                        // After stop request, just wait for the VM to actually go down.
                        std::thread::sleep(Duration::from_secs(60));
                    }
                }
            }
            Err(e) => {
                // Metric query failure isn't fatal; treat as "unknown" and don't
                // accumulate idle time, so a network blip can't trigger shutdown.
                eprintln!("metric query failed: {e:#}");
                idle.note_active(now);
            }
        }

        std::thread::sleep(Duration::from_secs(args.poll_secs));
    }
}

fn stop_self(
    client: &reqwest::blocking::Client,
    md: &metadata::Metadata,
    token: &metadata::AccessToken,
) -> Result<()> {
    // No explicit `systemctl stop` first: the agent runs as `gameserver`,
    // which can't talk to systemd's privileged bus and used to fail with
    // "Interactive authentication required". `instances.stop` triggers an
    // ACPI shutdown; systemd then drives the normal stop sequence and the
    // game gets SIGTERM with the unit's TimeoutStopSec grace window.
    let url = format!(
        "https://compute.googleapis.com/compute/v1/projects/{}/zones/{}/instances/{}/stop",
        md.project_id, md.zone, md.instance_name
    );
    // Empty body needs an explicit Content-Length: 0 or the compute API
    // rejects with 411 (reqwest omits the header when there's no body).
    let resp = client
        .post(&url)
        .bearer_auth(token.value())
        .header(reqwest::header::CONTENT_LENGTH, "0")
        .body("")
        .send()
        .context("instances.stop")?;
    if !resp.status().is_success() {
        anyhow::bail!("instances.stop returned {}", resp.status());
    }
    Ok(())
}
