//! Scrawl Remote, this fork, installs next to the official Scrawl.app (`dev.kitlangton.scrawl`),
//! so it keeps its own bundle id, settings, captures and logs. `scripts/install-app.sh` writes
//! the same bundle id and name into the app it builds.

/// `CFBundleIdentifier` of the installed app, and the GPUI window `app_id`.
pub const BUNDLE_ID: &str = "com.scowalt.scrawl-remote";

/// The folder name under `~/.config` and `~/Library/Application Support` (`%LOCALAPPDATA%`).
pub const DATA_NAME: &str = "scrawl-remote";

/// The folder name under `~/Library/Logs`.
pub const LOG_NAME: &str = "Scrawl Remote";
