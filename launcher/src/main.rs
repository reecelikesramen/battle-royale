mod keys;
mod launch;
mod manifest;
mod platform;
mod update_flow;
mod updater;

use std::sync::mpsc;
use std::thread;

#[cfg(feature = "gui")]
slint::include_modules!();

fn main() -> anyhow::Result<()> {
    // --update-only: run the update flow then exit without spawning the game.
    // Used by the dedicated-server systemd unit as ExecStartPre so the same
    // launcher binary that handles client updates also drives server updates
    // (delta + sig verify + atomic swap), and systemd owns the game lifecycle.
    //
    // --server (only meaningful alongside --update-only on Linux): pull the
    // dedicated-server manifest entry (`linux-server`), which ships an
    // embedded-pck binary and no separate pck_base. Avoids the OOM-prone
    // 1.2 GB client pck on the server.
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--update-only") {
        let server_variant = args.iter().any(|a| a == "--server");
        return run_update_only(server_variant);
    }

    #[cfg(feature = "gui")]
    {
        return run_gui();
    }
    #[cfg(not(feature = "gui"))]
    {
        run_headless()
    }
}

/// One-shot headless update. Exits 0 on success (update applied OR no work
/// needed). Exits non-zero on manifest fetch / signature / download failure
/// so systemd surfaces the failure instead of starting the game on a
/// half-installed bundle.
fn run_update_only(server_variant: bool) -> anyhow::Result<()> {
    let client = update_flow::http_client()?;
    let manifest = update_flow::fetch_manifest(&client)?;
    if update_flow::is_up_to_date(&manifest) {
        eprintln!("launcher --update-only: already on {}", manifest.latest);
        return Ok(());
    }
    let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();
    let worker_tx = tx.clone();
    let opts = update_flow::RunOpts {
        skip_launcher_self_update: true,
        server_variant,
    };
    let handle = thread::spawn(move || update_flow::run_with_opts(worker_tx, manifest, opts));
    while let Ok(msg) = rx.recv() {
        match msg {
            update_flow::UpdateMessage::Status(s) => eprintln!("[update] {s}"),
            update_flow::UpdateMessage::Progress(_) => {}
            update_flow::UpdateMessage::Done => eprintln!("[update] done"),
            update_flow::UpdateMessage::Error(e) => eprintln!("[update] ERROR {e}"),
        }
    }
    handle.join().unwrap()?;
    Ok(())
}

/// Spawn the game then exit the launcher. The launcher is intentionally NOT a
/// long-lived supervisor — once the game is up, we get out of the way so we
/// don't sit in the user's process list / Dock / taskbar.
fn spawn_game_and_exit() -> ! {
    match platform::install_dir().and_then(|d| launch::spawn_game(&d).map_err(Into::into)) {
        Ok(_) => std::process::exit(0),
        Err(e) => {
            eprintln!("launcher: failed to spawn game: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(feature = "gui")]
fn run_gui() -> anyhow::Result<()> {
    // Fast path: try to silent-launch when the install already matches the
    // latest published manifest. Failure to reach the manifest (offline, GCS
    // hiccup) falls through to the GUI so the user gets a visible "Launch
    // anyway" affordance rather than a silent no-op.
    match update_flow::http_client().and_then(|c| update_flow::fetch_manifest(&c)) {
        Ok(manifest) => {
            if update_flow::is_up_to_date(&manifest) {
                spawn_game_and_exit();
            }
            run_window_with_manifest(Some(manifest))
        }
        Err(e) => {
            eprintln!("launcher: manifest prefetch failed: {e:#}");
            run_window_with_manifest(None)
        }
    }
}

#[cfg(feature = "gui")]
fn run_window_with_manifest(manifest: Option<manifest::Manifest>) -> anyhow::Result<()> {
    let window = LauncherWindow::new()?;

    let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();

    // Worker: either run the update flow with the pre-fetched manifest, or —
    // if prefetch failed — push a single Error event so the user sees what
    // happened and can launch with the current install.
    let worker_tx = tx.clone();
    thread::spawn(move || match manifest {
        Some(m) => {
            if let Err(e) = update_flow::run(worker_tx.clone(), m) {
                let _ = worker_tx.send(update_flow::UpdateMessage::Error(format!("{e:#}")));
            }
        }
        None => {
            let _ = worker_tx.send(update_flow::UpdateMessage::Error(
                "Couldn't reach the update server. You can launch with the current install."
                    .into(),
            ));
        }
    });

    let win_weak = window.as_weak();
    thread::spawn(move || {
        while let Ok(msg) = rx.recv() {
            let win_weak = win_weak.clone();
            slint::invoke_from_event_loop(move || {
                if let Some(win) = win_weak.upgrade() {
                    match msg {
                        update_flow::UpdateMessage::Status(s) => win.set_status_text(s.into()),
                        update_flow::UpdateMessage::Progress(p) => {
                            win.set_progress(p.clamp(0.0, 1.0));
                        }
                        update_flow::UpdateMessage::Done => {
                            // Update finished cleanly → spawn game and tear
                            // down the window. The slint event loop returns
                            // from window.run() and main exits, so the
                            // launcher process is gone before the game window
                            // appears.
                            win.set_status_text("Launching game...".into());
                            win.set_progress(1.0);
                            spawn_game_or_record_error(&win);
                            slint::quit_event_loop().ok();
                        }
                        update_flow::UpdateMessage::Error(e) => {
                            win.set_error_text(e.into());
                            win.set_show_error(true);
                            // Error path keeps the "Launch" button so the user
                            // can still try with whatever is on disk.
                            win.set_launch_enabled(true);
                        }
                    }
                }
            })
            .ok();
        }
    });

    // The Launch button is only reachable on the error path now (the success
    // path auto-spawns on Done). Spawning here then quitting the event loop
    // gives the same end-state: launcher gone, game running.
    let win_weak = window.as_weak();
    window.on_launch(move || {
        if let Some(win) = win_weak.upgrade() {
            spawn_game_or_record_error(&win);
            slint::quit_event_loop().ok();
        }
    });

    let win_weak = window.as_weak();
    window.on_retry(move || {
        // Sprint 3 placeholder: dismissing the error just closes the launcher.
        let _ = win_weak.upgrade();
        slint::quit_event_loop().ok();
    });

    window.run()?;
    Ok(())
}

#[cfg(feature = "gui")]
fn spawn_game_or_record_error(win: &LauncherWindow) {
    match platform::install_dir().and_then(|d| launch::spawn_game(&d).map_err(Into::into)) {
        Ok(_) => {}
        Err(e) => {
            win.set_error_text(format!("Failed to launch game: {e:#}").into());
            win.set_show_error(true);
        }
    }
}

#[cfg(not(feature = "gui"))]
fn run_headless() -> anyhow::Result<()> {
    // Mirror the GUI fast path: try silent launch when manifest matches.
    if let Ok(client) = update_flow::http_client() {
        if let Ok(manifest) = update_flow::fetch_manifest(&client) {
            if update_flow::is_up_to_date(&manifest) {
                spawn_game_and_exit();
            }
            let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();
            let worker_tx = tx.clone();
            let handle = thread::spawn(move || update_flow::run(worker_tx, manifest));
            while let Ok(msg) = rx.recv() {
                match msg {
                    update_flow::UpdateMessage::Status(s) => println!("[status] {s}"),
                    update_flow::UpdateMessage::Progress(p) => {
                        println!("[progress] {:.1}%", p * 100.0)
                    }
                    update_flow::UpdateMessage::Done => println!("[done]"),
                    update_flow::UpdateMessage::Error(e) => eprintln!("[error] {e}"),
                }
            }
            handle.join().unwrap()?;
        }
    }
    spawn_game_and_exit();
}
