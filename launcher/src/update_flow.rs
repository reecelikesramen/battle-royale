use anyhow::{Context, Result};
use std::path::PathBuf;
use std::sync::mpsc::Sender;

use crate::manifest::{self, Component, Manifest, PlatformEntry};
use crate::platform::{
    install_dir, installed_version, launcher_exe_name, launcher_updater_exe_name, platform_key,
};
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
    let manifest_url = format!("{MANIFEST_URL_BASE}/versions.json?t={bust}");
    let sig_url = format!("{MANIFEST_URL_BASE}/versions.json.sig?t={bust}");

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

    // launcher-updater is the bootstrap helper that swaps the launcher binary
    // when it isn't running. Update it FIRST and in-place — it isn't running,
    // so a normal atomic-rename works. The launcher itself is updated last via
    // a deferred swap.
    if let Some(updater_component) = target_plat.launcher_updater.as_ref() {
        let path = install.join(launcher_updater_exe_name());
        let _ = tx.send(UpdateMessage::Status("Updating launcher-updater...".into()));
        updater::install_component(client, updater_component, &path, &current, |_| {})?;
        #[cfg(unix)]
        ensure_executable(&path)?;
    }

    // game_binary is intentionally skipped: the manifest URL points at the
    // full platform .zip (mac/linux/windows), not a single binary file. The
    // initial install delivers the binary via that zip download out-of-band;
    // in-place game-binary updates require Godot-version-bump release and
    // re-downloading the zip. PCK patches + launcher self-update cover the
    // common per-tag change set without touching the binary.
    let components = [
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

        // game_binary + rust_lib are executables/loadable libs that must be
        // chmod +x on unix. atomic-rename preserves the source file's mode
        // (0644 from the GCS download), which makes the game binary fail
        // to spawn with EACCES.
        #[cfg(unix)]
        if matches!(label, "game_binary" | "rust_lib") {
            ensure_executable(&target_path)?;
        }
    }

    // Stamp the new version into VERSION.txt durably.
    updater::write_atomic(&install.join("VERSION.txt"), manifest.latest.as_bytes())
        .context("write VERSION.txt")?;

    // Self-update last. We can't overwrite the running launcher binary, so we
    // download to <launcher>.new and hand off to the launcher-updater
    // bootstrap, which waits for us to exit, swaps the file, and relaunches.
    if let Some(launcher_component) = target_plat.launcher.as_ref() {
        if launcher_self_update_needed(&install, launcher_component)? {
            let current_launcher = std::env::current_exe().context("current_exe")?;
            let new_launcher = current_launcher.with_extension("new");
            let _ = std::fs::remove_file(&new_launcher);
            let _ = tx.send(UpdateMessage::Status("Updating launcher...".into()));
            // Force a full download to the .new path. Skip the delta path — the
            // currently-running launcher is the old version; patching the .new
            // path with a delta keyed against the installed version wouldn't be
            // meaningful, and we can't read the running binary as a patch base
            // reliably on Windows.
            updater::download_and_install(client, launcher_component, &new_launcher, |_| {})?;
            #[cfg(unix)]
            ensure_executable(&new_launcher)?;
            hand_off_to_updater(&install, &new_launcher, &current_launcher, tx)?;
            return Ok(());
        }
    }

    let _ = tx.send(UpdateMessage::Status(format!(
        "Installed {}",
        manifest.latest
    )));
    let _ = tx.send(UpdateMessage::Progress(1.0));
    Ok(())
}

fn launcher_self_update_needed(install: &std::path::Path, component: &Component) -> Result<bool> {
    let path = install.join(launcher_exe_name());
    if !path.exists() {
        return Ok(true);
    }
    let current = updater::sha256_of_file(&path)?;
    Ok(current != component.sha256.to_ascii_lowercase())
}

#[cfg(unix)]
fn ensure_executable(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(path)
        .with_context(|| format!("stat {}", path.display()))?
        .permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(path, perms)
        .with_context(|| format!("chmod {}", path.display()))?;
    Ok(())
}

fn hand_off_to_updater(
    install: &std::path::Path,
    new_launcher: &std::path::Path,
    current_launcher: &std::path::Path,
    tx: &Sender<UpdateMessage>,
) -> Result<()> {
    let updater_bin = install.join(launcher_updater_exe_name());
    if !updater_bin.is_file() {
        anyhow::bail!(
            "launcher-updater missing at {} — cannot self-update",
            updater_bin.display()
        );
    }
    let pid = std::process::id().to_string();
    let _ = tx.send(UpdateMessage::Status("Restarting to apply launcher update...".into()));
    std::process::Command::new(&updater_bin)
        .arg(&pid)
        .arg(new_launcher)
        .arg(current_launcher)
        .spawn()
        .with_context(|| format!("spawn {}", updater_bin.display()))?;
    let _ = tx.send(UpdateMessage::Done);
    // Give the UI thread a tick to flush, then exit so the updater can swap.
    std::thread::sleep(std::time::Duration::from_millis(200));
    std::process::exit(0);
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
