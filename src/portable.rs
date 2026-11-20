//! The `zipPaste` experiment: a capture travels as one `.zip` file pasted into the agent's
//! composer (bb saves attachments on whichever machine runs the thread), followed by the summary
//! text. Every path inside is relative to the `<id>.scrawl/` folder the zip unpacks to, so the
//! capture opens anywhere without SSH or a shared disk.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, ensure};

use crate::model::ScrawlBundle;

/// The recording and audio go in only while together they stay under this, so a long capture
/// doesn't make a paste that is slow to upload or over an attachment limit.
pub const MEDIA_LIMIT_BYTES: u64 = 20 * 1024 * 1024;

pub struct Portable {
    /// `<bundle>/<id>.zip`, kept in the bundle so retention removes it with the capture.
    pub zip: PathBuf,
    /// What to paste after the zip: how to open it, then the summary with relative paths.
    pub text: String,
}

/// Builds `<id>.zip` from `bundle_dir`: contact sheet, keyframes, manifest, a summary whose paths
/// are relative, and the recording and audio when they fit [`MEDIA_LIMIT_BYTES`].
pub fn zip_bundle(bundle_dir: &Path, bundle: &ScrawlBundle) -> Result<Portable> {
    zip_bundle_with(bundle_dir, bundle, MEDIA_LIMIT_BYTES)
}

pub fn zip_bundle_with(
    bundle_dir: &Path,
    bundle: &ScrawlBundle,
    media_limit: u64,
) -> Result<Portable> {
    let name = bundle_dir
        .file_name()
        .context("Bundle has no name")?
        .to_string_lossy()
        .into_owned();
    let stem = name.strip_suffix(".scrawl").unwrap_or(&name).to_owned();
    let zip_name = format!("{stem}.zip");

    // Unique per call: a finished capture's copy and ⌥⇧V can zip the same bundle at once.
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let call = format!(
        "{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let staging_root = std::env::temp_dir().join(format!("scrawl-zip-{stem}-{call}"));
    let _ = fs::remove_dir_all(&staging_root);
    let _cleanup = RemoveOnDrop(staging_root.clone());
    let staging = staging_root.join(&name);
    fs::create_dir_all(staging.join("frames"))?;

    for rel in [bundle.contact_sheet.as_str(), "scrawl.json"] {
        fs::copy(bundle_dir.join(rel), staging.join(rel))
            .with_context(|| format!("Could not copy {rel}"))?;
    }
    for frame in &bundle.keyframes {
        fs::copy(bundle_dir.join(&frame.file), staging.join(&frame.file))
            .with_context(|| format!("Could not copy {}", frame.file))?;
    }

    let media: Vec<&str> = [bundle.video.as_deref(), bundle.audio.as_deref()]
        .into_iter()
        .flatten()
        .filter(|rel| bundle_dir.join(rel).is_file())
        .collect();
    let media_bytes: u64 = media
        .iter()
        .filter_map(|rel| fs::metadata(bundle_dir.join(rel)).ok())
        .map(|meta| meta.len())
        .sum();
    let media_fits = media_bytes <= media_limit;
    if media_fits {
        for rel in &media {
            let (from, to) = (bundle_dir.join(rel), staging.join(rel));
            if fs::hard_link(&from, &to).is_err() {
                fs::copy(&from, &to).with_context(|| format!("Could not copy {rel}"))?;
            }
        }
    }

    let summary = crate::sketch::summary_markdown_with(
        bundle,
        Path::new(&name),
        crate::handoff::experiment(crate::handoff::AGENT_CONTEXT),
    );
    fs::write(staging.join("summary.md"), &summary)?;

    let zip = bundle_dir.join(&zip_name);
    let partial = bundle_dir.join(format!(".{zip_name}.{call}.partial"));
    let _ = fs::remove_file(&partial);
    let output = Command::new("/usr/bin/ditto")
        .args([
            "-c",
            "-k",
            "--norsrc",
            "--noextattr",
            "--noacl",
            "--keepParent",
        ])
        .arg(&staging)
        .arg(&partial)
        .output()
        .context("Could not start ditto")?;
    ensure!(
        output.status.success(),
        "Zipping the capture failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    fs::rename(&partial, &zip)?;

    let mut text = format!(
        "Scrawl capture attached as {zip_name}. Unzip it (`unzip {zip_name}`); the paths below \
         are inside the {name}/ folder it makes, and its summary.md is this text."
    );
    if !media.is_empty() && !media_fits {
        text.push_str(&format!(
            " The recording ({} MB) was left out to keep the zip small, so `scrawl zoom` can't \
             look closer.",
            media_bytes.div_ceil(1024 * 1024)
        ));
    }
    text.push_str("\n\n");
    text.push_str(&summary);
    Ok(Portable { zip, text })
}

struct RemoveOnDrop(PathBuf);

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Puts `file` on the clipboard as a file (what Finder's Copy does), with `text` on the same
/// item for apps that only take text.
#[cfg(target_os = "macos")]
pub fn copy_file_to_clipboard(file: &Path, text: Option<&str>) -> Result<()> {
    use objc2_app_kit::{NSPasteboard, NSPasteboardTypeFileURL, NSPasteboardTypeString};
    use objc2_foundation::{NSArray, NSString};

    let uri = NSString::from_str(&crate::handoff::file_uri(file));
    let pasteboard = NSPasteboard::generalPasteboard();
    unsafe {
        let types = match text {
            Some(_) => NSArray::from_slice(&[NSPasteboardTypeFileURL, NSPasteboardTypeString]),
            None => NSArray::from_slice(&[NSPasteboardTypeFileURL]),
        };
        pasteboard.clearContents();
        pasteboard.declareTypes_owner(&types, None);
        ensure!(
            pasteboard.setString_forType(&uri, NSPasteboardTypeFileURL),
            "Could not copy the zip to the clipboard"
        );
        if let Some(text) = text {
            ensure!(
                pasteboard.setString_forType(&NSString::from_str(text), NSPasteboardTypeString),
                "Could not copy text to clipboard"
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "scrawl-portable-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&root);
        let out = root.join("scrawl-zip-demo.scrawl");
        let (dir, _, _) = crate::generate_demo_bundle(Some(out)).unwrap();
        (root, dir)
    }

    fn unzip(zip: &Path, into: &Path) {
        let status = Command::new("/usr/bin/ditto")
            .args(["-x", "-k"])
            .arg(zip)
            .arg(into)
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    fn the_zip_unpacks_to_a_bundle_with_relative_paths_and_small_media() {
        let (root, dir) = fixture();
        fs::write(dir.join("recording.mp4"), vec![7_u8; 4096]).unwrap();
        fs::write(dir.join("audio.wav"), vec![1_u8; 1024]).unwrap();
        fs::create_dir_all(dir.join("frames-full")).unwrap();
        fs::write(dir.join(".remote.json"), "{}").unwrap();
        let (_, mut bundle) = crate::handoff::load_bundle(&dir).unwrap();
        bundle.video = Some("recording.mp4".into());
        bundle.audio = Some("audio.wav".into());

        let portable = zip_bundle_with(&dir, &bundle, 1 << 20).unwrap();
        assert_eq!(portable.zip, dir.join("scrawl-zip-demo.zip"));

        let unpacked = root.join("elsewhere");
        unzip(&portable.zip, &unpacked);
        let opened = unpacked.join("scrawl-zip-demo.scrawl");
        let mut files: Vec<String> = walk(&opened);
        files.sort();
        let mut expected = vec![
            "audio.wav".to_owned(),
            "contact-sheet.png".to_owned(),
            "recording.mp4".to_owned(),
            "scrawl.json".to_owned(),
            "summary.md".to_owned(),
        ];
        expected.extend(bundle.keyframes.iter().map(|k| k.file.clone()));
        expected.sort();
        assert_eq!(files, expected);

        let summary = fs::read_to_string(opened.join("summary.md")).unwrap();
        assert!(summary.contains("· scrawl-zip-demo.scrawl]"), "{summary}");
        assert!(!summary.contains(&root.display().to_string()), "{summary}");
        assert!(
            portable
                .text
                .starts_with("Scrawl capture attached as scrawl-zip-demo.zip.")
        );
        assert!(portable.text.ends_with(&summary));
        assert!(!portable.text.contains("left out"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn media_over_the_limit_is_left_out_and_said_so() {
        let (root, dir) = fixture();
        fs::write(dir.join("recording.mp4"), vec![7_u8; 3 * 1024 * 1024]).unwrap();
        let (_, mut bundle) = crate::handoff::load_bundle(&dir).unwrap();
        bundle.video = Some("recording.mp4".into());

        let portable = zip_bundle_with(&dir, &bundle, 1024 * 1024).unwrap();
        let unpacked = root.join("elsewhere");
        unzip(&portable.zip, &unpacked);
        let opened = unpacked.join("scrawl-zip-demo.scrawl");
        assert!(opened.join("contact-sheet.png").is_file());
        assert!(!opened.join("recording.mp4").exists());
        assert!(
            portable.text.contains("recording (3 MB) was left out"),
            "{}",
            portable.text
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_same_bundle_zips_from_several_threads_at_once() {
        let (root, dir) = fixture();
        let (_, bundle) = crate::handoff::load_bundle(&dir).unwrap();
        let results: Vec<Result<Portable>> = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| scope.spawn(|| zip_bundle_with(&dir, &bundle, 0)))
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        for result in results {
            assert!(result.is_ok(), "{:#}", result.err().unwrap());
        }
        let unpacked = root.join("elsewhere");
        unzip(&dir.join("scrawl-zip-demo.zip"), &unpacked);
        assert!(unpacked.join("scrawl-zip-demo.scrawl/summary.md").is_file());
        let _ = fs::remove_dir_all(&root);
    }

    fn walk(dir: &Path) -> Vec<String> {
        let mut out = Vec::new();
        for entry in fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if path.is_dir() {
                out.extend(walk(&path).into_iter().map(|rel| format!("{name}/{rel}")));
            } else {
                out.push(name);
            }
        }
        out
    }
}
