use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};

use crate::manifest::{Component, Delta};

/// Write `bytes` to `target` durably and atomically: write to a `.part` next
/// to it, fsync, rename into place.
pub fn write_atomic(target: &Path, bytes: &[u8]) -> Result<()> {
    let staging = staging_path(target);
    let _ = fs::remove_file(&staging);
    {
        let mut f = fs::File::create(&staging)
            .with_context(|| format!("create {}", staging.display()))?;
        f.write_all(bytes).context("write atomic file body")?;
        f.sync_all().context("fsync atomic file")?;
    }
    atomic_rename(&staging, target)
}


pub struct DownloadProgress {
    pub bytes_done: u64,
    pub bytes_total: u64,
}

pub fn sha256_of_file(path: &Path) -> Result<String> {
    let mut f = fs::File::open(path)
        .with_context(|| format!("open {} for hashing", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Download `component` to a staging file next to `target`, verify sha256,
/// then atomically rename into place. Returns Ok if the file was downloaded
/// and applied; Err on hash mismatch or I/O failure (caller decides whether
/// to retry).
pub fn download_and_install(
    client: &reqwest::blocking::Client,
    component: &Component,
    target: &Path,
    mut on_progress: impl FnMut(DownloadProgress),
) -> Result<()> {
    let staging = staging_path(target);
    // Clean any prior partial download.
    let _ = fs::remove_file(&staging);

    let resp = client
        .get(&component.url)
        .send()
        .with_context(|| format!("GET {}", component.url))?
        .error_for_status()
        .with_context(|| format!("server returned error for {}", component.url))?;

    let total = component.size;
    let mut hasher = Sha256::new();
    let mut written: u64 = 0;
    let mut f = fs::File::create(&staging)
        .with_context(|| format!("create staging file {}", staging.display()))?;

    // reqwest blocking response implements Read.
    let mut src = resp;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = src.read(&mut buf).context("read response body")?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        f.write_all(&buf[..n]).context("write staging file")?;
        written += n as u64;
        on_progress(DownloadProgress {
            bytes_done: written,
            bytes_total: total,
        });
    }
    f.sync_all().context("fsync staging file")?;
    drop(f);

    let got_sha = hex(&hasher.finalize());
    if got_sha != component.sha256.to_ascii_lowercase() {
        let _ = fs::remove_file(&staging);
        bail!(
            "sha256 mismatch for {}: expected {}, got {}",
            component.url,
            component.sha256,
            got_sha
        );
    }
    if written != total && total != 0 {
        eprintln!(
            "warning: downloaded {} bytes but manifest claimed {}",
            written, total
        );
    }

    atomic_rename(&staging, target)?;
    Ok(())
}

pub(crate) fn staging_path(target: &Path) -> PathBuf {
    let mut p = target.to_path_buf();
    let mut ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_string();
    if !ext.is_empty() {
        ext.push('.');
    }
    ext.push_str("part");
    p.set_extension(ext);
    p
}

pub(crate) fn atomic_rename(src: &Path, dst: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        fs::rename(src, dst).with_context(|| {
            format!("atomic rename {} -> {}", src.display(), dst.display())
        })?;
    }
    #[cfg(windows)]
    {
        windows_atomic_rename(src, dst)?;
    }
    Ok(())
}

#[cfg(windows)]
fn windows_atomic_rename(src: &Path, dst: &Path) -> Result<()> {
    // MoveFileExW with MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH gives
    // us an atomic in-place replacement on the same volume. The cost is one
    // extra syscall vs std::fs::rename, but we get correct semantics: even
    // if the process is killed mid-call, the filesystem ends up with either
    // the old or new content (never empty).
    use std::os::windows::ffi::OsStrExt;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x8;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(src: *const u16, dst: *const u16, flags: u32) -> i32;
        fn GetLastError() -> u32;
    }

    fn to_wide(p: &Path) -> Vec<u16> {
        p.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
    }

    let s = to_wide(src);
    let d = to_wide(dst);
    let ok = unsafe {
        MoveFileExW(
            s.as_ptr(),
            d.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        let err = unsafe { GetLastError() };
        bail!(
            "MoveFileExW failed: {} -> {} (GetLastError={})",
            src.display(),
            dst.display(),
            err
        );
    }
    Ok(())
}

/// Apply a zstd patch (`zstd --patch-from prev new -o patch.zpatch`) by
/// streaming the patch through a Decoder with the previous file content as
/// the dictionary. Output is written atomically to `target`.
pub fn apply_zstd_patch(prev: &Path, patch_file: &Path, target: &Path) -> Result<()> {
    let dict = fs::read(prev).with_context(|| format!("read prev {}", prev.display()))?;
    let patch = BufReader::new(
        fs::File::open(patch_file)
            .with_context(|| format!("open patch {}", patch_file.display()))?,
    );

    let staging = staging_path(target);
    let _ = fs::remove_file(&staging);

    // `--patch-from` produces a zstd frame that uses the previous file as a
    // raw content "prefix" rather than a trained dictionary, so we use
    // `with_prepared_dictionary` and feed the bytes directly. We also lift
    // window_log_max to 31 because `--patch-from` defaults to long-range
    // mode (--long=27) on the encoder side; the decoder must allow at
    // least that to materialize the patch in memory.
    let prepared = zstd::dict::DecoderDictionary::copy(&dict);
    let mut decoder = zstd::stream::Decoder::with_prepared_dictionary(patch, &prepared)
        .context("zstd decoder with prev as prefix")?;
    decoder
        .window_log_max(31)
        .context("set window_log_max")?;

    let mut out = fs::File::create(&staging)
        .with_context(|| format!("create staging {}", staging.display()))?;
    std::io::copy(&mut decoder, &mut out).context("zstd decompress streaming")?;
    out.sync_all().context("fsync delta output")?;
    drop(out);

    atomic_rename(&staging, target)
}

/// Apply or download a component, picking the cheapest viable path:
/// (1) sha256 already matches → no-op
/// (2) delta available and applies cleanly → patch from prev file
/// (3) otherwise → full download.
pub fn install_component(
    client: &reqwest::blocking::Client,
    component: &Component,
    target: &Path,
    installed_version: &str,
    mut on_progress: impl FnMut(DownloadProgress),
) -> Result<ComponentAction> {
    if target.exists() {
        let current_sha = sha256_of_file(target)?;
        if current_sha == component.sha256.to_ascii_lowercase() {
            return Ok(ComponentAction::Skipped);
        }
    }

    if let Some(delta) = &component.delta {
        if delta.from == installed_version && target.exists() {
            match try_delta(client, delta, target, &mut on_progress) {
                Ok(()) => {
                    let after = sha256_of_file(target)?;
                    if after == component.sha256.to_ascii_lowercase() {
                        return Ok(ComponentAction::AppliedDelta);
                    }
                    eprintln!(
                        "warning: delta produced sha {}, expected {}; falling back to full download",
                        after, component.sha256
                    );
                }
                Err(e) => {
                    eprintln!("warning: delta apply failed ({}); falling back to full download", e);
                }
            }
        }
    }

    download_and_install(client, component, target, on_progress)?;
    Ok(ComponentAction::DownloadedFull)
}

pub enum ComponentAction {
    Skipped,
    AppliedDelta,
    DownloadedFull,
}

fn try_delta(
    client: &reqwest::blocking::Client,
    delta: &Delta,
    target: &Path,
    on_progress: &mut impl FnMut(DownloadProgress),
) -> Result<()> {
    let patch_staging = staging_path(&target.with_extension("zpatch"));
    let _ = fs::remove_file(&patch_staging);

    let resp = client
        .get(&delta.url)
        .send()
        .with_context(|| format!("GET delta {}", delta.url))?
        .error_for_status()?;

    let total = delta.size;
    let mut hasher = Sha256::new();
    let mut written: u64 = 0;
    let mut f = fs::File::create(&patch_staging)
        .with_context(|| format!("create delta staging {}", patch_staging.display()))?;
    let mut src = resp;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = src.read(&mut buf).context("read delta body")?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        f.write_all(&buf[..n]).context("write delta staging")?;
        written += n as u64;
        on_progress(DownloadProgress {
            bytes_done: written,
            bytes_total: total,
        });
    }
    f.sync_all().ok();
    drop(f);

    let got = hex(&hasher.finalize());
    if got != delta.sha256.to_ascii_lowercase() {
        let _ = fs::remove_file(&patch_staging);
        bail!("delta sha256 mismatch: expected {}, got {}", delta.sha256, got);
    }

    apply_zstd_patch(target, &patch_staging, target)?;
    let _ = fs::remove_file(&patch_staging);
    Ok(())
}
