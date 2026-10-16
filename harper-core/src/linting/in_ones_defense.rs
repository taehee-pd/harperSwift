use crate::{
    CharStringExt, Lint, Token,
    expr::{Expr, SequenceExpr},
    linting::{
        ExprLinter, LintKind, Suggestion,
        expr_linter::{Chunk, preceded_by_word},
    },
};

// Modified in this fork (taehee-pd/harperSwift): flags `to my defense` only where it introduces a
// justification (at the start of a clause, or after a conjunction or a verb of saying). The
// upstream rule skipped a fixed list of motion verbs, so `ran to my defense` and `came running to
// my defense` were changed to `in`.

/// Words after which `to my defense` introduces a justification (`And to my defense, ...`, `all I
/// can say to my defense`). After other words, such as verbs of motion (`ran to my defense`), `to`
/// is correct.
const JUSTIFICATION_LEAD_INS: &[&str] = &[
    "and", "but", "so", "yet", "or", "though", "although", "well", "also", "plus", "now", "say",
    "says", "said", "saying",
];

pub struct InOnesDefense {
    expr: SequenceExpr,
}

impl Default for InOnesDefense {
    fn default() -> Self {
        Self {
            expr: SequenceExpr::aco("to")
                .t_ws()
                .then_word_set(["my", "your", "his", "her", "its", "our", "their", "one's"])
                .t_ws()
                .then_word_set(["defense", "defence"]),
        }
    }
}

impl ExprLinter for InOnesDefense {
    type Unit = Chunk;

    fn match_to_lint_with_context(
        &self,
        toks: &[Token],
        src: &[char],
        ctx: Option<(&[Token], &[Token])>,
    ) -> Option<Lint> {
        // Nothing but punctuation before `to`: the start of a sentence, or after a comma or bracket.
        let starts_clause = ctx.is_none_or(|(before, _)| {
            before
                .iter()
                .rev()
                .find(|t| !t.kind.is_whitespace())
                .is_none_or(|t| t.kind.is_punctuation())
        });
        let follows_lead_in = preceded_by_word(ctx, |t| {
            t.get_ch(src)
                .eq_any_ignore_ascii_case_str(JUSTIFICATION_LEAD_INS)
        });

        if !starts_clause && !follows_lead_in {
            return None;
        }

        let span = toks[0].span;

        Some(Lint {
            span,
            lint_kind: LintKind::Usage,
            suggestions: vec![Suggestion::replace_with_match_case_str(
                "in",
                span.get_content(src),
            )],
            message:
                "When giving a justification, the idiom is `in my defense`, not `to my defense`."
                    .to_owned(),
            ..Default::default()
        })
    }

    fn description(&self) -> &str {
        "Corrects `to my defense` to `in my defense` when it introduces a justification, but not after verbs such as `came to my defense`."
    }

    fn expr(&self) -> &dyn Expr {
        &self.expr
    }
}

#[cfg(test)]
mod tests {
    use crate::linting::tests::{assert_no_lints, assert_suggestion_result};

    use super::InOnesDefense;

    #[test]
    fn fix_to_my_defense_from_issue() {
        assert_suggestion_result(
            "I did try to drive this thing. And to my defense, um, I bought this before I had other financial and time responsibilities.",
            InOnesDefense::default(),
            "I did try to drive this thing. And in my defense, um, I bought this before I had other financial and time responsibilities.",
        );
    }

    #[test]
    fn fix_sentence_initial_to_their_defence() {
        assert_suggestion_result(
            "To their defence, the docs never mentioned it.",
            InOnesDefense::default(),
            "In their defence, the docs never mentioned it.",
        );
    }

    #[test]
    fn fix_to_ones_defense() {
        assert_suggestion_result(
            "Everyone has something to say to one's defense.",
            InOnesDefense::default(),
            "Everyone has something to say in one's defense.",
        );
    }

    #[test]
    fn allows_rushed_to_my_defense() {
        assert_no_lints(
            "My friends rushed to my defense when the reviewer complained.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_came_to_her_defence() {
        assert_no_lints(
            "Nobody came to her defence after the outage.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_in_my_defense() {
        assert_no_lints(
            "In my defense, the tests were already failing.",
            InOnesDefense::default(),
        );
    }
    #[test]
    fn fix_but_to_my_defense() {
        assert_suggestion_result(
            "But to my defense, nobody told me about the deadline.",
            InOnesDefense::default(),
            "But in my defense, nobody told me about the deadline.",
        );
    }

    #[test]
    fn fix_after_comma() {
        assert_suggestion_result(
            "Well, to your defense, the docs were wrong.",
            InOnesDefense::default(),
            "Well, in your defense, the docs were wrong.",
        );
    }

    #[test]
    fn fix_all_caps() {
        assert_suggestion_result(
            "TO MY DEFENSE, THE BUILD WAS GREEN.",
            InOnesDefense::default(),
            "IN MY DEFENSE, THE BUILD WAS GREEN.",
        );
    }

    #[test]
    fn fix_after_said() {
        assert_suggestion_result(
            "He said to his defense that the map was old.",
            InOnesDefense::default(),
            "He said in his defense that the map was old.",
        );
    }

    #[test]
    fn fix_so_to_our_defence() {
        assert_suggestion_result(
            "So to our defence, we did test it twice.",
            InOnesDefense::default(),
            "So in our defence, we did test it twice.",
        );
    }

    #[test]
    fn fix_inside_parentheses() {
        assert_suggestion_result(
            "The page was slow (to my defense, it was a demo).",
            InOnesDefense::default(),
            "The page was slow (in my defense, it was a demo).",
        );
    }

    #[test]
    fn allows_ran_to_my_defense() {
        assert_no_lints("She ran to my defense.", InOnesDefense::default());
    }

    #[test]
    fn allows_went_to_her_defence() {
        assert_no_lints(
            "They went to her defence when the vote came.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_came_running_to_my_defense() {
        assert_no_lints("He came running to my defense.", InOnesDefense::default());
    }

    #[test]
    fn allows_adverb_before_to() {
        assert_no_lints(
            "My sister came quickly to my defense.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_rallied_to_their_defense() {
        assert_no_lints(
            "The union rallied to their defense.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_flew_to_its_defense() {
        assert_no_lints("Every ally flew to its defense.", InOnesDefense::default());
    }

    #[test]
    fn allows_in_her_defence() {
        assert_no_lints(
            "In her defence, the sign was hidden.",
            InOnesDefense::default(),
        );
    }

    #[test]
    fn allows_to_the_defense() {
        assert_no_lints(
            "To the defense, the evidence looked thin.",
            InOnesDefense::default(),
        );
    }
}
