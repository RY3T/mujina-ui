//! Embeds the release version into the binary as `MUJINA_UI_VERSION`.
//!
//! The version is `git describe --tags --match 'v*' --dirty --always`:
//! `v1.1.0` for a release build, `v1.1.0-3-gabc1234` for a build
//! three commits past it, and a `-dirty` suffix when the working tree had
//! uncommitted changes. A build from a source tarball without git can set
//! `MUJINA_UI_VERSION` in the environment instead.

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

fn main() {
    let version = std::env::var("MUJINA_UI_VERSION")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| git(&["describe", "--tags", "--match", "v*", "--dirty", "--always"]))
        .unwrap_or_else(|| format!("{}-unknown", std::env::var("CARGO_PKG_VERSION").unwrap()));
    println!("cargo:rustc-env=MUJINA_UI_VERSION={version}");
    println!("cargo:rerun-if-env-changed=MUJINA_UI_VERSION");

    // Re-run when the commit, the tags, the index or any source changes, so
    // the embedded version (and its -dirty suffix) never goes stale.
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=assets");
    println!("cargo:rerun-if-changed=Cargo.toml");
    for path in ["HEAD", "index", "packed-refs", "refs/tags"] {
        if let Some(p) = git(&["rev-parse", "--git-path", path]) {
            println!("cargo:rerun-if-changed={p}");
        }
    }
    if let Some(common) = git(&["rev-parse", "--git-common-dir"]) {
        println!("cargo:rerun-if-changed={common}/packed-refs");
        println!("cargo:rerun-if-changed={common}/refs/tags");
    }
}
