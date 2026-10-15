//! Added in this fork (taehee-pd/harperSwift).
//!
//! Clarity suggestions get a dashed underline in their own color, so they read as different from
//! Harper's solid underlines without relying on color alone.

use crate::clarity::CLARITY_COLOR;

const DASH: f32 = 3.0;
const GAP: f32 = 2.0;

/// Draws the tint and dashed underline for a Clarity lint covering `bounds`.
pub fn draw(ui: &egui::Ui, bounds: egui::Rect) {
    let (r, g, b) = (CLARITY_COLOR.r, CLARITY_COLOR.g, CLARITY_COLOR.b);
    // Same tint strength and underline height as Harper's highlights.
    let fill = egui::Color32::from_rgba_unmultiplied(r, g, b, 24);
    let underline = egui::Color32::from_rgb(r, g, b);
    let height = bounds.height().min(2.0);

    ui.painter().rect_filled(bounds, 0.0, fill);

    for (start, end) in dashes(bounds.left(), bounds.right()) {
        ui.painter().rect_filled(
            egui::Rect::from_min_max(
                egui::pos2(start, bounds.bottom() - height),
                egui::pos2(end, bounds.bottom()),
            ),
            0.0,
            underline,
        );
    }
}

/// Dash positions from `left` to `right`, always ending on a (possibly short) dash so the
/// underline reaches the end of the word.
fn dashes(left: f32, right: f32) -> Vec<(f32, f32)> {
    let mut dashes = Vec::new();
    let mut start = left;

    while start < right {
        dashes.push((start, (start + DASH).min(right)));
        start += DASH + GAP;
    }
    if let Some(last) = dashes.last_mut()
        && right - last.1 > 0.0
    {
        last.1 = right;
    }

    dashes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashes_cover_the_word_with_gaps() {
        assert_eq!(dashes(0.0, 12.0), [(0.0, 3.0), (5.0, 8.0), (10.0, 12.0)]);
        assert!(dashes(5.0, 5.0).is_empty());
    }
}
