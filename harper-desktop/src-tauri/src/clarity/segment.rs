//! Added in this fork (taehee-pd/harperSwift).
//!
//! Splits text into paragraphs and sentences for Clarity checks. Offsets are char indices, like
//! Harper's spans.

use std::ops::Range;

use super::{SentenceKey, stable_hash};

/// Sentences with fewer words than this are skipped: too little to rewrite.
pub const MIN_WORDS: usize = 5;

/// Abbreviations whose period does not end a sentence. Compared in lowercase, without the period.
const ABBREVIATIONS: &[&str] = &[
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "a.m", "p.m",
    "cf", "approx", "no", "fig", "inc", "ltd", "co", "jan", "feb", "mar", "apr", "jun", "jul",
    "aug", "sep", "sept", "oct", "nov", "dec",
];

/// One sentence worth checking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sentence {
    /// Char range in the full text.
    pub span: Range<usize>,
    /// Index of the paragraph that holds the sentence; paragraphs are separated by blank lines.
    pub paragraph: usize,
    pub text: String,
    pub key: SentenceKey,
}

/// Finds the sentences in `text` that Clarity should check, in document order.
///
/// Sentences never cross a line break. Fenced code blocks, sentences with URLs or inline code,
/// and sentences under [`MIN_WORDS`] words are left out.
pub fn sentences(text: &str) -> Vec<Sentence> {
    let chars = text.chars().collect::<Vec<_>>();
    let mut sentences = Vec::new();
    let mut paragraph = 0;
    let mut previous_line_blank = true;
    let mut in_fence = false;
    let mut line_start = 0;

    while line_start <= chars.len() {
        let line_end = chars[line_start..]
            .iter()
            .position(|&c| c == '\n')
            .map_or(chars.len(), |offset| line_start + offset);
        let line = &chars[line_start..line_end];
        let trimmed = line.iter().collect::<String>();
        let trimmed = trimmed.trim();

        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
        } else if trimmed.is_empty() {
            if !previous_line_blank {
                paragraph += 1;
            }
            previous_line_blank = true;
        } else {
            previous_line_blank = false;

            if !in_fence {
                for range in sentence_ranges(line) {
                    let span = line_start + range.start..line_start + range.end;
                    let sentence = chars[span.clone()].iter().collect::<String>();

                    if is_checkable(&sentence) {
                        sentences.push(Sentence {
                            key: stable_hash(&sentence),
                            span,
                            paragraph,
                            text: sentence,
                        });
                    }
                }
            }
        }

        line_start = line_end + 1;
    }

    sentences
}

/// Char ranges of the sentences in one line, trimmed of surrounding whitespace and leading list
/// or quote markers.
fn sentence_ranges(line: &[char]) -> Vec<Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0;
    let mut index = 0;

    while index < line.len() {
        if matches!(line[index], '.' | '!' | '?' | '…') && !is_abbreviation(line, index) {
            // Keep closing quotes and brackets with the sentence they end.
            let mut end = index + 1;
            while end < line.len() && matches!(line[end], '"' | '\'' | ')' | ']' | '”' | '’') {
                end += 1;
            }

            if end == line.len() || line[end].is_whitespace() {
                ranges.push(start..end);
                start = end;
                index = end;
                continue;
            }
        }
        index += 1;
    }
    ranges.push(start..line.len());

    ranges
        .into_iter()
        .filter_map(|range| trim(line, range))
        .collect()
}

/// Whether the period at `index` belongs to an abbreviation or an initial ("J. Smith").
fn is_abbreviation(line: &[char], index: usize) -> bool {
    if line[index] != '.' {
        return false;
    }

    let word_start = line[..index]
        .iter()
        .rposition(|c| c.is_whitespace() || *c == '(')
        .map_or(0, |position| position + 1);
    let word = line[word_start..index]
        .iter()
        .collect::<String>()
        .to_lowercase();

    let is_initial = word.chars().count() == 1 && word.chars().all(char::is_alphabetic);
    is_initial || ABBREVIATIONS.contains(&word.as_str())
}

fn trim(line: &[char], range: Range<usize>) -> Option<Range<usize>> {
    let mut start = range.start;
    let mut end = range.end;

    loop {
        while start < end && line[start].is_whitespace() {
            start += 1;
        }
        // List and quote markers: "- ", "* ", "+ ", "> ".
        if start + 1 < end
            && matches!(line[start], '-' | '*' | '+' | '>')
            && line[start + 1].is_whitespace()
        {
            start += 2;
            continue;
        }
        break;
    }
    while end > start && line[end - 1].is_whitespace() {
        end -= 1;
    }

    (start < end).then_some(start..end)
}

fn is_checkable(sentence: &str) -> bool {
    let has_url = sentence.contains("://") || sentence.contains("www.");
    let has_code = sentence.contains('`');
    let words = sentence
        .split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .count();

    !has_url && !has_code && words >= MIN_WORDS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(text: &str) -> Vec<String> {
        sentences(text).into_iter().map(|s| s.text).collect()
    }

    #[test]
    fn splits_sentences_and_keeps_char_offsets() {
        let text = "Héllo there, this is the first one. And here is the second sentence!";
        let found = sentences(text);
        let chars = text.chars().collect::<Vec<_>>();

        assert_eq!(found.len(), 2);
        for sentence in &found {
            assert_eq!(
                chars[sentence.span.clone()].iter().collect::<String>(),
                sentence.text
            );
        }
        assert_eq!(found[1].text, "And here is the second sentence!");
    }

    #[test]
    fn ignores_abbreviations_initials_and_decimals() {
        assert_eq!(
            texts(
                "Dr. Smith met J. Doe at 3.15 p.m. on Friday, e.g. after lunch. Then they all went home together."
            ),
            [
                "Dr. Smith met J. Doe at 3.15 p.m. on Friday, e.g. after lunch.",
                "Then they all went home together."
            ]
        );
    }

    #[test]
    fn keeps_closing_quotes_with_their_sentence() {
        assert_eq!(
            texts("She said \"we should leave right now.\" Nobody in the room moved at all."),
            [
                "She said \"we should leave right now.\"",
                "Nobody in the room moved at all."
            ]
        );
    }

    #[test]
    fn numbers_paragraphs_by_blank_lines_and_never_crosses_lines() {
        let found = sentences(
            "The first paragraph starts on this line\nand this line is still the same paragraph.\n\n\nA second paragraph begins right here today.",
        );

        assert_eq!(
            found.iter().map(|s| s.paragraph).collect::<Vec<_>>(),
            [0, 0, 1]
        );
        assert_eq!(found[0].text, "The first paragraph starts on this line");
    }

    #[test]
    fn skips_code_urls_and_short_sentences() {
        let text = "Too short here.\n```\nlet value = compute_the_result(input, options);\n```\nRead the docs at https://example.com for more detail.\nCall `parse` before you use the value here.\nThis sentence is long enough to check.";

        assert_eq!(texts(text), ["This sentence is long enough to check."]);
    }

    #[test]
    fn strips_list_and_quote_markers() {
        assert_eq!(
            texts(
                "- Buy milk and eggs on the way home.\n> Quoted text should also be checked here."
            ),
            [
                "Buy milk and eggs on the way home.",
                "Quoted text should also be checked here."
            ]
        );
    }

    #[test]
    fn identical_sentences_share_a_key() {
        let found = sentences("We will meet again very soon. We will meet again very soon.");

        assert_eq!(found[0].key, found[1].key);
        assert_ne!(found[0].span, found[1].span);
    }
}
