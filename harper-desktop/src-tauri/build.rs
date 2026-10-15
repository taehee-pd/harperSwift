// Modified in this fork (taehee-pd/harperSwift): also builds the native macOS popup.

mod build_swift;

fn main() {
    build_swift::build();
    tauri_build::build()
}
