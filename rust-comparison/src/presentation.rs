use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Run {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub mono: bool,
    pub strike: bool,
}
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Block {
    pub kind: String,
    pub level: u8,
    pub runs: Vec<Run>,
}
impl Block {
    pub fn text(&self) -> String {
        self.runs.iter().map(|r| r.text.as_str()).collect()
    }
}
pub fn parse(source: &str) -> Vec<Block> {
    let mut blocks = Vec::new();
    let mut block = Block::default();
    let (mut bold, mut italic, mut strike, mut code) = (false, false, false, false);
    let flush = |block: &mut Block, blocks: &mut Vec<Block>| {
        if !block.runs.is_empty() || block.kind == "rule" {
            blocks.push(std::mem::take(block));
        }
    };
    for event in Parser::new_ext(
        source,
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS,
    ) {
        match event {
            Event::Start(tag) => match tag {
                Tag::Heading { level, .. } => {
                    flush(&mut block, &mut blocks);
                    block.kind = "heading".into();
                    block.level = level as u8;
                }
                Tag::Paragraph => {
                    if block.kind.is_empty() {
                        block.kind = "paragraph".into();
                    }
                }
                Tag::CodeBlock(_) => {
                    flush(&mut block, &mut blocks);
                    block.kind = "code".into();
                    code = true;
                }
                Tag::Item => {
                    flush(&mut block, &mut blocks);
                    block.kind = "list".into();
                    block.runs.push(Run {
                        text: "• ".into(),
                        ..Run::default()
                    });
                }
                Tag::TableHead | Tag::TableRow => {
                    flush(&mut block, &mut blocks);
                    block.kind = "table".into();
                }
                Tag::Strong => bold = true,
                Tag::Emphasis => italic = true,
                Tag::Strikethrough => strike = true,
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Heading(_)
                | TagEnd::Paragraph
                | TagEnd::Item
                | TagEnd::TableHead
                | TagEnd::TableRow => flush(&mut block, &mut blocks),
                TagEnd::CodeBlock => {
                    flush(&mut block, &mut blocks);
                    code = false;
                }
                TagEnd::TableCell => block.runs.push(Run {
                    text: "  |  ".into(),
                    ..Run::default()
                }),
                TagEnd::Strong => bold = false,
                TagEnd::Emphasis => italic = false,
                TagEnd::Strikethrough => strike = false,
                _ => {}
            },
            Event::Code(text) => block.runs.push(Run {
                text: text.into_string(),
                bold,
                italic,
                mono: true,
                strike,
            }),
            Event::Text(text) => {
                let mono = code;
                block.runs.push(Run {
                    text: text.into_string(),
                    bold,
                    italic,
                    mono,
                    strike,
                });
            }
            Event::SoftBreak | Event::HardBreak => block.runs.push(Run {
                text: "\n".into(),
                ..Run::default()
            }),
            Event::TaskListMarker(done) => block.runs.push(Run {
                text: if done { "☑ " } else { "☐ " }.into(),
                ..Run::default()
            }),
            Event::Rule => {
                flush(&mut block, &mut blocks);
                block.kind = "rule".into();
                flush(&mut block, &mut blocks);
            }
            // HTML and destinations are deliberately absent from the native model.
            _ => {}
        }
    }
    flush(&mut block, &mut blocks);
    blocks
}
pub fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
pub fn html(blocks: &[Block]) -> String {
    let mut out = String::new();
    for b in blocks {
        let tag = match b.kind.as_str() {
            "heading" => format!("h{}", b.level.clamp(1, 6)),
            "code" => "pre".into(),
            _ => "p".into(),
        };
        out.push_str(&format!("<{tag}>"));
        for r in &b.runs {
            let mut text = escape(&r.text);
            for (enabled, tag) in [
                (r.bold, "b"),
                (r.italic, "i"),
                (r.mono, "code"),
                (r.strike, "s"),
            ] {
                if enabled {
                    text = format!("<{tag}>{text}</{tag}>");
                }
            }
            out.push_str(&text);
        }
        out.push_str(&format!("</{tag}>"));
    }
    out
}
