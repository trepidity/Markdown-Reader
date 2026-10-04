use markdown_reader_rust::shell::Model;
use slint::ComponentHandle;
use std::{cell::RefCell, rc::Rc};
slint::slint! {
    import { VerticalBox, HorizontalBox, Button, LineEdit, TextEdit, ScrollView } from "std-widgets.slint";
    export struct PreviewBlock { content: string, size: float, mono: bool }
    export component Viewer inherits Window {
        title: "Markdown Reader Rust Slint"; width: 1080px; height: 780px;
        in-out property <string> path;
        in-out property <string> query;
        in-out property <string> source;
        in property <string> status;
        in property <[PreviewBlock]> blocks;
        in-out property <bool> editing: false;
        callback command(string);
        callback edited(string);
        VerticalBox {
            HorizontalBox {
                LineEdit { text <=> root.path; placeholder-text: "Path / Save Copy destination"; }
                Button { text: "Open"; clicked => { root.command("open"); } }
                Button { text: "Undo"; clicked => { root.command("undo"); } }
                Button { text: "Redo"; clicked => { root.command("redo"); } }
                Button { text: "Reload"; clicked => { root.command("reload"); } }
                Button { text: "Save Copy"; clicked => { root.command("saveCopy"); } }
            }
            HorizontalBox {
                Button { text: root.editing ? "Preview" : "Edit"; clicked => { root.editing = !root.editing; root.command("state"); } }
                LineEdit { text <=> root.query; placeholder-text: "Search current document"; }
                Button { text: "Search"; clicked => { root.command("search"); } }
            }
            Text { text: root.status; wrap: word-wrap; }
            if root.editing: TextEdit { text <=> root.source; edited => { root.edited(self.text); } }
            if !root.editing: ScrollView {
                VerticalBox {
                    for block in root.blocks: Text {
                        text: block.content; font-size: block.size * 1px;
                        font-family: block.mono ? "Menlo" : "Helvetica";
                        wrap: word-wrap;
                    }
                }
            }
        }
    }
}
fn sync(ui: &Viewer, model: &Model) {
    ui.set_status(model.status.as_str().into());
    if ui.get_editing() {
        ui.set_source(model.core.state.text.as_str().into());
    }
    let blocks: Vec<PreviewBlock> = model
        .core
        .state
        .blocks
        .iter()
        .map(|b| PreviewBlock {
            content: b.text().into(),
            size: if b.kind == "heading" {
                32.0 - f32::from(b.level) * 2.0
            } else {
                16.0
            },
            mono: b.kind == "code",
        })
        .collect();
    ui.set_blocks(Rc::new(slint::VecModel::from(blocks)).into());
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ui = Viewer::new()?;
    let model = Rc::new(RefCell::new(Model::startup()));
    ui.set_path(model.borrow().path.as_str().into());
    sync(&ui, &model.borrow());
    let weak = ui.as_weak();
    let m = model.clone();
    ui.on_command(move |action| {
        if let Some(ui) = weak.upgrade() {
            let mut model = m.borrow_mut();
            model.path = ui.get_path().to_string();
            model.query = ui.get_query().to_string();
            model.action(action.as_str());
            sync(&ui, &model);
        }
    });
    let weak = ui.as_weak();
    let edit_model = model.clone();
    ui.on_edited(move |source| {
        if let Some(ui) = weak.upgrade() {
            let mut model = edit_model.borrow_mut();
            model.edit(source.to_string());
            ui.set_status(model.status.as_str().into());
        }
    });
    let weak = ui.as_weak();
    ui.window().on_close_requested(move || {
        let mut model = model.borrow_mut();
        if model.request_close() {
            slint::CloseRequestResponse::HideWindow
        } else {
            if let Some(ui) = weak.upgrade() {
                ui.set_status(model.status.as_str().into());
            }
            slint::CloseRequestResponse::KeepWindowShown
        }
    });
    ui.run()?;
    Ok(())
}
