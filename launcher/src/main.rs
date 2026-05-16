mod keys;
mod launch;
mod manifest;
mod platform;
mod update_flow;
mod updater;

use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::mpsc;
use std::thread;

/// Handle to the currently-supervised game child so we can SIGTERM it if the
/// user closes the launcher window.
static SUPERVISED_CHILD: OnceLock<Mutex<Option<u32>>> = OnceLock::new();

fn record_child(pid: u32) {
    let slot = SUPERVISED_CHILD.get_or_init(|| Mutex::new(None));
    *slot.lock().unwrap() = Some(pid);
}

fn kill_supervised_child() {
    if let Some(slot) = SUPERVISED_CHILD.get() {
        if let Some(pid) = slot.lock().unwrap().take() {
            #[cfg(unix)]
            unsafe {
                // SIGTERM the game so it can exit cleanly.
                libc::kill(pid as i32, libc::SIGTERM);
            }
            #[cfg(windows)]
            {
                let _ = std::process::Command::new("taskkill")
                    .args(["/PID", &pid.to_string(), "/T", "/F"])
                    .status();
            }
        }
    }
}

#[cfg(feature = "gui")]
slint::include_modules!();

fn main() -> anyhow::Result<()> {
    #[cfg(feature = "gui")]
    {
        return run_gui();
    }
    #[cfg(not(feature = "gui"))]
    {
        run_headless()
    }
}

#[cfg(feature = "gui")]
fn run_gui() -> anyhow::Result<()> {
    let window = LauncherWindow::new()?;

    let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();

    let worker_tx = tx.clone();
    thread::spawn(move || {
        if let Err(e) = update_flow::run(worker_tx.clone()) {
            let _ = worker_tx.send(update_flow::UpdateMessage::Error(format!("{e:#}")));
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
                            win.set_status_text("Ready to launch.".into());
                            win.set_progress(1.0);
                            win.set_launch_enabled(true);
                        }
                        update_flow::UpdateMessage::Error(e) => {
                            win.set_error_text(e.into());
                            win.set_show_error(true);
                            win.set_launch_enabled(true); // allow launch with current install
                        }
                    }
                }
            })
            .ok();
        }
    });

    let win_weak = window.as_weak();
    window.on_launch(move || {
        let Some(win) = win_weak.upgrade() else {
            return;
        };
        let install = match platform::install_dir() {
            Ok(p) => p,
            Err(e) => {
                win.set_error_text(format!("install_dir: {e:#}").into());
                win.set_show_error(true);
                return;
            }
        };
        // Supervise the game process: when it exits, check for the
        // Sprint 7 restart sentinel and re-run the update flow if present.
        // Launcher stays alive throughout.
        let win_weak = win.as_weak();
        std::thread::spawn(move || loop {
            let child = match launch::spawn_game(&install) {
                Ok(c) => {
                    record_child(c.id());
                    c
                }
                Err(e) => {
                    let win_weak = win_weak.clone();
                    let err = format!("{e:#}");
                    slint::invoke_from_event_loop(move || {
                        if let Some(w) = win_weak.upgrade() {
                            w.set_error_text(err.into());
                            w.set_show_error(true);
                        }
                    })
                    .ok();
                    return;
                }
            };
            let exit_status = wait_for_child(child);
            eprintln!("game exited: {exit_status:?}");
            let sentinel = platform::restart_sentinel_path(&install);
            if !sentinel.exists() {
                slint::quit_event_loop().ok();
                return;
            }
            eprintln!("restart sentinel present; re-running update flow");
            let _ = std::fs::remove_file(&sentinel);
            let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();
            let worker_tx = tx.clone();
            let h = std::thread::spawn(move || update_flow::run(worker_tx));
            // Drain progress into stderr while we wait for update to finish.
            while let Ok(msg) = rx.recv() {
                eprintln!("re-update: {msg:?}");
            }
            let _ = h.join();
        });
    });

    window.on_retry(move || {
        // Sprint 3: just exit and let the user restart the launcher.
        // Sprint 4 will re-run the update flow in place.
        slint::quit_event_loop().ok();
    });

    window.run()?;
    // User closed the launcher window. Make sure the game child gets SIGTERM
    // so we don't orphan it.
    kill_supervised_child();
    Ok(())
}

fn wait_for_child(mut child: std::process::Child) -> std::io::Result<std::process::ExitStatus> {
    child.wait()
}

#[cfg(not(feature = "gui"))]
fn run_headless() -> anyhow::Result<()> {
    let (tx, rx) = mpsc::channel::<update_flow::UpdateMessage>();
    let worker_tx = tx.clone();
    let handle = thread::spawn(move || update_flow::run(worker_tx));
    while let Ok(msg) = rx.recv() {
        match msg {
            update_flow::UpdateMessage::Status(s) => println!("[status] {s}"),
            update_flow::UpdateMessage::Progress(p) => println!("[progress] {:.1}%", p * 100.0),
            update_flow::UpdateMessage::Done => println!("[done]"),
            update_flow::UpdateMessage::Error(e) => eprintln!("[error] {e}"),
        }
    }
    handle.join().unwrap()?;
    let install = platform::install_dir()?;
    launch::spawn_game(&install)?;
    Ok(())
}
