use anyhow::{Context, Result};
use clap::Parser;
use std::time::{Duration, Instant};

mod idle;
mod metadata;
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

    // Spawn the release watcher on its own thread; the idle loop runs in main.
    {
        let md = metadata::Metadata::fetch().context("metadata for release watcher")?;
        std::thread::spawn(move || {
            let client = reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()
                .expect("build http client");
            let mut token = metadata::AccessToken::default();
            if let Err(e) = release::watch_loop(&client, &md, &mut token) {
                eprintln!("release-watcher exited: {e:#}");
            }
        });
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
    // Drain the game process first via systemctl. The systemd unit's
    // TimeoutStopSec gives it 60s; the game receives SIGTERM and exits.
    let _ = std::process::Command::new("systemctl")
        .args(["stop", "battle-royale-server.service"])
        .status();

    let url = format!(
        "https://compute.googleapis.com/compute/v1/projects/{}/zones/{}/instances/{}/stop",
        md.project_id, md.zone, md.instance_name
    );
    let resp = client
        .post(&url)
        .bearer_auth(token.value())
        .send()
        .context("instances.stop")?;
    if !resp.status().is_success() {
        anyhow::bail!("instances.stop returned {}", resp.status());
    }
    Ok(())
}
