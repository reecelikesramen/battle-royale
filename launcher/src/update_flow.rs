use anyhow::{Context, Result};
use std::path::PathBuf;
use std::sync::mpsc::Sender;

use crate::manifest::{self, Component, Manifest, PlatformEntry};
use crate::platform::{install_dir, installed_version, platform_key};
use crate::updater::{self, ComponentAction, DownloadProgress};

const MANIFEST_URL_BASE: &str =
    "https://storage.googleapis.com/erudite-cycle-480104-game-builds";

#[derive(Debug, Clone)]
pub enum UpdateMessage {
    Status(String),
    Progress(f32),
    Done,
    Error(String),
}

pub fn run(tx: Sender<UpdateMessage>) -> Result<()> {
    // Consume any leftover restart sentinel from a previous session. If the
    // server kicked clients via Sprint 7's RestartListener, the game wrote
    // this file before quitting; its presence tells us a re-update is
    // expected. We always run the manifest check, but this is a useful
    // diagnostic for logs.
    if let Ok(install) = crate::platform::install_dir() {
        let sentinel = crate::platform::restart_sentinel_path(&install);
        if sentinel.exists() {
            eprintln!("found restart sentinel at {} — running update flow", sentinel.display());
            let _ = std::fs::remove_file(&sentinel);
        }
    }

    let _ = tx.send(UpdateMessage::Status("Fetching manifest...".into()));

    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("battle-royale-launcher/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .context("build http client")?;

    let bust = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let manifest_url = format!("{MANIFEST_URL_BASE}/versions-v2.json?t={bust}");
    let sig_url = format!("{MANIFEST_URL_BASE}/versions-v2.json.sig?t={bust}");

    let manifest_bytes = client
        .get(&manifest_url)
        .send()
        .with_context(|| format!("GET {manifest_url}"))?
        .error_for_status()?
        .bytes()
        .context("read manifest body")?
        .to_vec();

    let sig_bytes = client
        .get(&sig_url)
        .send()
        .with_context(|| format!("GET {sig_url}"))?
        .error_for_status()?
        .bytes()
        .context("read signature body")?
        .to_vec();

    let _ = tx.send(UpdateMessage::Status("Verifying signature...".into()));
    manifest::verify_signature(&manifest_bytes, &sig_bytes)?;

    let manifest = manifest::parse(&manifest_bytes)?;
    apply_updates(&client, &manifest, &tx)?;

    let _ = tx.send(UpdateMessage::Done);
    Ok(())
}

fn apply_updates(
    client: &reqwest::blocking::Client,
    manifest: &Manifest,
    tx: &Sender<UpdateMessage>,
) -> Result<()> {
    let plat_key = platform_key();
    let install = install_dir()?;
    let current = installed_version(&install);
    let target_plat: &PlatformEntry = manifest::target_platform(manifest, plat_key)?;

    if current == manifest.latest {
        let _ = tx.send(UpdateMessage::Status("Up to date.".into()));
        let _ = tx.send(UpdateMessage::Progress(1.0));
        return Ok(());
    }

    // Components we install. Order matters only insofar as a partial failure
    // mid-list shouldn't brick the install — each install is atomic-rename so
    // even an interrupted update leaves us with a coherent (older) install.
    //
    // The launcher component is skipped here in Sprint 4 — the launcher
    // can't safely replace its own binary while running on Windows; Sprint 8
    // adds a separate `launcher-updater` bootstrap for that.
    let components = [
        ("game_binary", target_plat.game_binary.as_ref()),
        ("rust_lib", target_plat.rust_lib.as_ref()),
        ("pck_base", target_plat.pck_base.as_ref()),
        ("pck_patch", target_plat.pck_patch.as_ref()),
    ];

    let total = components.iter().filter(|(_, c)| c.is_some()).count() as f32;
    let mut idx = 0.0_f32;

    for (label, maybe_component) in components {
        let Some(component) = maybe_component else {
            continue;
        };
        idx += 1.0;
        let base_progress = (idx - 1.0) / total;

        let target_path = component_target_path(&install, label, component);
        let _ = tx.send(UpdateMessage::Status(format!(
            "Updating {label}..."
        )));

        let tx_for_progress = tx.clone();
        let action = updater::install_component(
            client,
            component,
            &target_path,
            &current,
            |DownloadProgress {
                 bytes_done,
                 bytes_total,
             }| {
                if bytes_total > 0 {
                    let frac = (bytes_done as f32 / bytes_total as f32).clamp(0.0, 1.0);
                    let _ = tx_for_progress.send(UpdateMessage::Progress(
                        base_progress + frac / total,
                    ));
                }
            },
        )?;

        let suffix = match action {
            ComponentAction::Skipped => "already up to date",
            ComponentAction::AppliedDelta => "patched (delta)",
            ComponentAction::DownloadedFull => "downloaded",
        };
        let _ = tx.send(UpdateMessage::Status(format!("{label}: {suffix}")));
    }

    // Stamp the new version into VERSION.txt durably.
    updater::write_atomic(&install.join("VERSION.txt"), manifest.latest.as_bytes())
        .context("write VERSION.txt")?;

    let _ = tx.send(UpdateMessage::Status(format!(
        "Installed {}",
        manifest.latest
    )));
    let _ = tx.send(UpdateMessage::Progress(1.0));
    Ok(())
}

/// Resolve where a component's file lives in the install dir. Uses
/// `installed_name` from the manifest if present, otherwise picks a sensible
/// default per component name.
fn component_target_path(install: &std::path::Path, label: &str, component: &Component) -> PathBuf {
    if let Some(name) = &component.installed_name {
        return install.join(name);
    }
    let fallback = match label {
        "game_binary" => crate::platform::game_exe_name(),
        "rust_lib" => crate::platform::rust_lib_name(),
        _ => "unknown.bin",
    };
    install.join(fallback)
}
