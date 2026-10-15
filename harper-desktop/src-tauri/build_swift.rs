//! Added in this fork (taehee-pd/harperSwift).
//!
//! Builds the SwiftUI suggestion popup in `../macos-popup` with SwiftPM and links it into the
//! highlighter. Only runs when targeting macOS; needs the Xcode command line tools.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

const PACKAGE_DIR: &str = "../macos-popup";
const LIBRARY: &str = "HarperPopup";
/// Must match `platforms` in `Package.swift` and `bundle.macOS.minimumSystemVersion` in
/// `tauri.conf.json`.
const DEPLOYMENT_TARGET: &str = "13.0";

pub fn build() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    println!("cargo:rerun-if-changed={PACKAGE_DIR}/Package.swift");
    println!("cargo:rerun-if-changed={PACKAGE_DIR}/Sources");

    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64".to_owned(),
        Ok(arch) => arch.to_owned(),
        Err(error) => panic!("CARGO_CFG_TARGET_ARCH is not set: {error}"),
    };
    let triple = format!("{arch}-apple-macosx{DEPLOYMENT_TARGET}");
    let configuration = match env::var("PROFILE").as_deref() {
        Ok("release") => "release",
        _ => "debug",
    };
    let scratch_path =
        PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set")).join("swift");

    let build_args = [
        "build",
        "--package-path",
        PACKAGE_DIR,
        "--scratch-path",
        path_str(&scratch_path),
        "--triple",
        &triple,
        "--configuration",
        configuration,
        "--product",
        LIBRARY,
    ];

    run("swift", &build_args);
    let bin_path = run(
        "swift",
        &[&build_args[..], &["--show-bin-path"][..]].concat(),
    );

    println!("cargo:rustc-link-search=native={bin_path}");
    println!("cargo:rustc-link-lib=static={LIBRARY}");

    // The Swift objects reference the Swift runtime and compatibility libraries by name; tell the
    // linker where to find them (toolchain and SDK) and where to load them from at run time.
    let target_info: serde_json::Value =
        serde_json::from_str(&run("swift", &["-print-target-info", "-target", &triple]))
            .expect("unexpected `swift -print-target-info` output");

    for path in target_info["paths"]["runtimeLibraryPaths"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|path| path.as_str())
    {
        println!("cargo:rustc-link-search=native={path}");
    }

    let sdk_path = run("xcrun", &["--sdk", "macosx", "--show-sdk-path"]);
    println!("cargo:rustc-link-search=native={sdk_path}/usr/lib/swift");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");

    // Link Rust objects for the same minimum macOS version as the Swift objects.
    println!("cargo:rustc-env=MACOSX_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}");
}

/// Runs a command and returns its trimmed stdout, failing the build with its stderr otherwise.
fn run(program: &str, args: &[&str]) -> String {
    let output = Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|error| {
            panic!(
                "failed to run `{program}` (are the Xcode command line tools installed?): {error}"
            )
        });

    if !output.status.success() {
        panic!(
            "`{program} {}` failed:\n{}{}",
            args.join(" "),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn path_str(path: &Path) -> &str {
    path.to_str().expect("OUT_DIR is not valid UTF-8")
}
