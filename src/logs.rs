//! Log tailing for the SSE endpoint.
//!
//! On every new SSE subscriber we open the log file fresh, return the
//! last ~N kB of context so the user has something to read immediately,
//! then poll for newly-appended bytes until the client disconnects.
//! We strip ANSI escape codes on the way out so colorized tracing
//! output renders cleanly in the browser.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Result;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio::sync::mpsc;

/// How much trailing context to ship at subscribe time.
const HISTORY_BYTES: u64 = 32 * 1024;

/// Poll the file for new bytes at this cadence.
const POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Start a tail task. The receiver yields one entry per newline-bounded
/// log line, with ANSI escape sequences stripped. The task ends when
/// the receiver is dropped (subscriber disconnect).
pub fn spawn(path: impl AsRef<Path>) -> mpsc::Receiver<String> {
    let path = path.as_ref().to_path_buf();
    let (tx, rx) = mpsc::channel::<String>(256);
    tokio::spawn(async move {
        if let Err(e) = run(path, tx).await {
            tracing::warn!(error = %e, "log tail exited");
        }
    });
    rx
}

async fn run(path: PathBuf, tx: mpsc::Sender<String>) -> Result<()> {
    let mut file = open_for_tail(&path).await?;
    let mut buf = String::new();

    // Send historical context first.
    let len = file.metadata().await?.len();
    let start = len.saturating_sub(HISTORY_BYTES);
    file.seek(SeekFrom::Start(start)).await?;
    let mut head_bytes = vec![0u8; (len - start) as usize];
    file.read_exact(&mut head_bytes).await.ok();
    // If we landed mid-line on the history seek, drop the prefix up to
    // the first newline -- otherwise the UI shows a partial line first.
    let head_str = String::from_utf8_lossy(&head_bytes);
    let history_view: &str = if start > 0 {
        match head_str.find('\n') {
            Some(i) => &head_str[i + 1..],
            None => &head_str,
        }
    } else {
        &head_str
    };
    for line in history_view.lines() {
        if tx.send(strip_ansi(line)).await.is_err() {
            return Ok(());
        }
    }

    // Live tail.
    let mut pos = file.metadata().await?.len();
    loop {
        tokio::time::sleep(POLL_INTERVAL).await;
        if tx.is_closed() {
            return Ok(());
        }
        let cur_len = match file.metadata().await {
            Ok(m) => m.len(),
            Err(_) => {
                // File may have rotated -- re-open and rewind.
                file = open_for_tail(&path).await?;
                pos = 0;
                continue;
            }
        };
        if cur_len < pos {
            // Truncation or rotation. Re-open.
            file = open_for_tail(&path).await?;
            pos = 0;
            continue;
        }
        if cur_len == pos {
            continue;
        }
        file.seek(SeekFrom::Start(pos)).await?;
        let mut chunk = String::new();
        file.read_to_string(&mut chunk).await.ok();
        // Concatenate to anything left over from a prior partial line.
        buf.push_str(&chunk);
        pos = cur_len;
        while let Some(i) = buf.find('\n') {
            let line: String = buf.drain(..=i).collect();
            let trimmed = line.trim_end_matches(['\n', '\r']);
            if tx.send(strip_ansi(trimmed)).await.is_err() {
                return Ok(());
            }
        }
    }
}

async fn open_for_tail(path: &Path) -> Result<File> {
    Ok(File::open(path).await?)
}

/// Strip ANSI CSI sequences (color codes mostly) so the UI can render
/// the line as plain text.
pub fn strip_ansi(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            i += 2;
            while i < bytes.len() {
                let b = bytes[i];
                i += 1;
                if (0x40..=0x7e).contains(&b) {
                    break;
                }
            }
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_color_codes() {
        // Real tracing-subscriber line snippet.
        let line = "\x1b[32m INFO\x1b[0m daemon: Started.";
        assert_eq!(strip_ansi(line), " INFO daemon: Started.");
    }

    #[test]
    fn leaves_plain_text_alone() {
        let line = "no escape sequences here";
        assert_eq!(strip_ansi(line), line);
    }

    #[test]
    fn strips_multiple_codes() {
        let line = "\x1b[2m2026-06-08T01:23:45Z\x1b[0m \x1b[32mINFO\x1b[0m hello";
        assert_eq!(strip_ansi(line), "2026-06-08T01:23:45Z INFO hello");
    }
}
