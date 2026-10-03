use crate::{
    document::{Document, Error},
    presentation::{self, Block},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct Command {
    action: String,
    path: String,
    text: String,
    revision: u64,
    query: String,
    confirmed: bool,
}
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub path: String,
    pub text: String,
    pub revision: u64,
    pub dirty: bool,
    pub can_undo: bool,
    pub can_redo: bool,
    pub error: String,
    pub blocks: Vec<Block>,
    pub html: String,
    pub matches: Vec<usize>,
}
#[derive(Debug, Default)]
pub struct Session {
    doc: Option<Document>,
    pub state: State,
}
impl Session {
    pub fn dispatch(&mut self, value: Value) -> Value {
        let result = serde_json::from_value::<Command>(value)
            .map_err(|_| Error::Command("invalid command"))
            .and_then(|c| self.execute(c));
        self.state.error = result.err().map(|e| e.to_string()).unwrap_or_default();
        self.update();
        serde_json::to_value(&self.state).expect("state contains only JSON-compatible fields")
    }
    fn execute(&mut self, c: Command) -> Result<(), Error> {
        if c.action == "open" {
            if let Some(doc) = &mut self.doc {
                doc.save()?;
            }
            self.doc = Some(Document::open(Path::new(&c.path))?);
            return Ok(());
        }
        if c.action == "state" {
            return Ok(());
        }
        let doc = self
            .doc
            .as_mut()
            .ok_or(Error::Command("open a document first"))?;
        match c.action.as_str() {
            "edit" => {
                if Path::new(&c.path).canonicalize()? != doc.path {
                    return Err(Error::Stale);
                }
                doc.edit(c.text, c.revision)
            }
            "save" => doc.save(),
            "undo" => doc.history(false),
            "redo" => doc.history(true),
            "saveCopy" => doc.save_copy(Path::new(&c.path)),
            "reload" => {
                if doc.dirty() && !c.confirmed {
                    return Err(Error::Command("draft retained; confirm Reload to discard"));
                }
                doc.reload()
            }
            "search" => {
                self.state.matches = if c.query.is_empty() {
                    vec![]
                } else {
                    doc.text
                        .lines()
                        .enumerate()
                        .filter_map(|(i, l)| l.contains(&c.query).then_some(i + 1))
                        .collect()
                };
                Ok(())
            }
            _ => Err(Error::Command("unknown command")),
        }
    }
    fn update(&mut self) {
        if let Some(doc) = &self.doc {
            if self.state.text != doc.text || self.state.path != doc.path.to_string_lossy() {
                self.state.text.clone_from(&doc.text);
                self.state.blocks = presentation::parse(&doc.text);
                self.state.html = presentation::html(&self.state.blocks);
                self.state.matches.clear();
            }
            self.state.path = doc.path.to_string_lossy().into_owned();
            self.state.revision = doc.revision;
            self.state.dirty = doc.dirty();
            self.state.can_undo = doc.can_undo();
            self.state.can_redo = doc.can_redo();
        }
    }
}
