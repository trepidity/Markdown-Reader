use crate::Session;
use serde_json::json;
#[derive(Debug, Default)]
pub struct Model {
    pub core: Session,
    pub path: String,
    pub query: String,
    pub editing: bool,
    pub dark: bool,
    pub status: String,
}
impl Model {
    pub fn request_close(&mut self) -> bool {
        if !self.core.state.dirty {
            return true;
        }
        self.action("save");
        if self.core.state.dirty {
            self.status
                .push_str("; window kept open. Use Save Copy to preserve the draft.");
            false
        } else {
            true
        }
    }
    pub fn startup() -> Self {
        let mut model = Self::default();
        if let Some(path) = std::env::args().nth(1) {
            model.path = path;
            model.action("open");
        }
        model
    }
    pub fn action(&mut self, action: &str) {
        self.core
            .dispatch(json!({"action":action,"path":self.path,"query":self.query}));
        self.status = if self.core.state.error.is_empty() {
            if action == "search" {
                format!("Matching lines: {:?}", self.core.state.matches)
            } else {
                format!(
                    "{}{}",
                    self.core.state.path,
                    if self.core.state.dirty {
                        " — unsaved draft"
                    } else {
                        " — saved"
                    }
                )
            }
        } else {
            self.core.state.error.clone()
        };
    }
    pub fn edit(&mut self, text: String) {
        self.core.dispatch(json!({"action":"edit","path":self.core.state.path,"revision":self.core.state.revision,"text":text}));
        self.status = if self.core.state.error.is_empty() {
            "Saved".into()
        } else {
            self.core.state.error.clone()
        };
    }
}
