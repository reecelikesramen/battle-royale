// Tiny bootstrap that swaps the launcher binary while it's not running.
//
// Invoked by the launcher when its own binary needs updating. Flow:
//   1. launcher downloads new launcher to <current>.new and verifies sha256.
//   2. launcher spawns: launcher-updater <pid> <new_path> <current_path>
//   3. launcher exits.
//   4. updater polls until <pid> is gone, then atomically renames
//      <current_path> -> <current_path>.old and <new_path> -> <current_path>.
//   5. updater spawns the new launcher and exits.
//
// On Unix you *could* in-place replace a running binary because the OS keeps
// the running process's inode open, but doing it the same way on all platforms
// keeps behavior consistent and avoids a permissions surprise on some FSes.

use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        bail!(
            "usage: {} <parent_pid> <new_launcher> <current_launcher>",
            args.first().map(String::as_str).unwrap_or("launcher-updater")
        );
    }
    let pid: u32 = args[1].parse().context("parse parent pid")?;
    let new_path = PathBuf::from(&args[2]);
    let current_path = PathBuf::from(&args[3]);

    if !new_path.is_file() {
        bail!("new launcher missing: {}", new_path.display());
    }

    wait_for_exit(pid, Duration::from_secs(30))?;

    swap(&new_path, &current_path)?;

    // Detach so we don't block the new launcher.
    std::process::Command::new(&current_path)
        .spawn()
        .with_context(|| format!("spawn {}", current_path.display()))?;
    Ok(())
}

fn swap(new_path: &std::path::Path, current_path: &std::path::Path) -> Result<()> {
    let backup = current_path.with_extension("old");
    let _ = std::fs::remove_file(&backup);
    if current_path.exists() {
        std::fs::rename(current_path, &backup)
            .with_context(|| format!("rename {} -> {}", current_path.display(), backup.display()))?;
    }
    std::fs::rename(new_path, current_path)
        .with_context(|| format!("rename {} -> {}", new_path.display(), current_path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(current_path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(current_path, perms)?;
    }
    Ok(())
}

fn wait_for_exit(pid: u32, timeout: Duration) -> Result<()> {
    let start = Instant::now();
    while is_alive(pid) {
        if start.elapsed() > timeout {
            bail!("timed out waiting for pid {pid} to exit");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

#[cfg(unix)]
fn is_alive(pid: u32) -> bool {
    // kill(pid, 0) returns 0 if the process exists, -1 + ESRCH if not.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[cfg(windows)]
fn is_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    const STILL_ACTIVE: u32 = 259;
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return false;
        }
        let mut code: u32 = 0;
        let ok = GetExitCodeProcess(handle, &mut code);
        CloseHandle(handle);
        ok != 0 && code == STILL_ACTIVE
    }
}
