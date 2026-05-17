use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// String used in the manifest's `platforms` map. Mirrors `init.gd`'s
/// `get_os_prefix()` so existing GCS layout works unchanged. When
/// `server_variant` is true and we're on Linux, returns "linux-server" —
/// the dedicated-server preset's manifest entry, which ships an
/// embedded-pck binary and no `pck_base` component.
pub fn platform_key(server_variant: bool) -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "linux") {
        if server_variant { "linux-server" } else { "linux" }
    } else if cfg!(target_os = "macos") {
        "mac"
    } else {
        "linux"
    }
}

/// The directory the game binary lives in — also where PCK patches go and
/// where VERSION.txt is read from. By default this is next to the launcher
/// executable; can be overridden with BR_INSTALL_DIR for testing.
pub fn install_dir() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("BR_INSTALL_DIR") {
        return Ok(PathBuf::from(p));
    }
    let exe = std::env::current_exe().context("current_exe")?;
    Ok(exe
        .parent()
        .context("launcher has no parent dir")?
        .to_path_buf())
}

/// Read the installed VERSION.txt next to the launcher. Returns "v0.0.0"
/// on any error so the launcher always treats us as out-of-date in that case.
pub fn installed_version(install: &Path) -> String {
    let path = install.join("VERSION.txt");
    std::fs::read_to_string(&path)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "v0.0.0".to_string())
}

/// Name of the game executable inside the install dir.
pub fn game_exe_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "battle-royale.exe"
    } else if cfg!(target_os = "macos") {
        "battle-royale"
    } else {
        "battle-royale.x86_64"
    }
}

/// File name of the Rust gdextension cdylib that ships next to the game
/// binary. Manifests should set `installed_name` to override; this is the
/// fallback.
/// Path to the "restart requested" sentinel file the game writes when the
/// server pushes a release-restart notice (Sprint 7's RestartListener).
/// The launcher checks for this on startup; if present, it re-runs the
/// update flow before launching the game and removes the file.
pub fn restart_sentinel_path(install: &std::path::Path) -> std::path::PathBuf {
    install.join(".restart_requested")
}

pub fn rust_lib_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "rust.dll"
    } else if cfg!(target_os = "macos") {
        "librust.dylib"
    } else {
        "librust.so"
    }
}

pub fn launcher_exe_name() -> &'static str {
    if cfg!(target_os = "windows") { "launcher.exe" } else { "launcher" }
}

pub fn launcher_updater_exe_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "launcher-updater.exe"
    } else {
        "launcher-updater"
    }
}
