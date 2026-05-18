use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;

use crate::platform::game_exe_name;

/// Spawn the game process. Caller decides whether to wait or return.
/// Returns the spawned `Child` so callers can supervise (Sprint 4).
pub fn spawn_game(install: &Path) -> Result<std::process::Child> {
    let exe = install.join(game_exe_name());
    if !exe.exists() {
        anyhow::bail!("game executable not found at {}", exe.display());
    }
    Command::new(&exe)
        .current_dir(install)
        .spawn()
        .with_context(|| format!("spawn {}", exe.display()))
}
