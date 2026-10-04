use fltk::{
    app,
    button::Button,
    frame::Frame,
    input::Input,
    misc::HelpView,
    prelude::*,
    text::{TextBuffer, TextEditor},
    window::Window,
};
use markdown_reader_rust::shell::Model;
use std::{cell::RefCell, rc::Rc};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let app = app::App::default();
    let mut win = Window::new(100, 100, 1080, 780, "Markdown Reader Rust FLTK");
    let mut path = Input::new(10, 10, 555, 30, "");
    let mut buttons = Vec::new();
    for (i, (label, action)) in [
        ("Open", "open"),
        ("Undo", "undo"),
        ("Redo", "redo"),
        ("Reload", "reload"),
        ("Save Copy", "saveCopy"),
    ]
    .into_iter()
    .enumerate()
    {
        buttons.push((Button::new(575 + i as i32 * 98, 10, 92, 30, label), action));
    }
    let mut toggle = Button::new(10, 50, 100, 30, "Edit / Preview");
    let mut query = Input::new(120, 50, 800, 30, "");
    let mut search = Button::new(930, 50, 140, 30, "Search");
    let mut status = Frame::new(10, 85, 1060, 35, "");
    status.set_align(fltk::enums::Align::Left | fltk::enums::Align::Inside);
    let mut preview = HelpView::new(10, 125, 1060, 645, "");
    let mut editor = TextEditor::new(10, 125, 1060, 645, "");
    let mut buffer = TextBuffer::default();
    editor.set_buffer(buffer.clone());
    editor.hide();
    win.resizable(&preview);
    win.end();
    win.show();
    let model = Rc::new(RefCell::new(Model::startup()));
    path.set_value(&model.borrow().path);
    preview.set_value(&model.borrow().core.state.html);
    status.set_label(&model.borrow().status);
    // Only toolkit edit callbacks dispatch writes. Programmatic buffer replacement
    // is guarded to avoid autosaving a half-applied undo/open response.
    let syncing = Rc::new(std::cell::Cell::new(false));
    for (mut button, action) in buttons {
        let (m, p, q, mut s, mut v, mut b, guard) = (
            model.clone(),
            path.clone(),
            query.clone(),
            status.clone(),
            preview.clone(),
            buffer.clone(),
            syncing.clone(),
        );
        button.set_callback(move |_| {
            let mut m = m.borrow_mut();
            m.path = p.value();
            m.query = q.value();
            m.action(action);
            s.set_label(&m.status);
            v.set_value(&m.core.state.html);
            if m.editing {
                guard.set(true);
                b.set_text(&m.core.state.text);
                guard.set(false);
            }
        });
    }
    let (m, mut e, mut v, mut b, guard) = (
        model.clone(),
        editor.clone(),
        preview.clone(),
        buffer.clone(),
        syncing.clone(),
    );
    toggle.set_callback(move |_| {
        let mut m = m.borrow_mut();
        m.editing = !m.editing;
        if m.editing {
            guard.set(true);
            b.set_text(&m.core.state.text);
            guard.set(false);
            v.hide();
            e.show();
        } else {
            e.hide();
            v.set_value(&m.core.state.html);
            v.show();
        }
    });
    let (m, q, mut s) = (model.clone(), query.clone(), status.clone());
    search.set_callback(move |_| {
        let mut m = m.borrow_mut();
        m.query = q.value();
        m.action("search");
        s.set_label(&m.status);
    });
    let (m, b, mut s, guard) = (model.clone(), buffer.clone(), status.clone(), syncing);
    buffer.add_modify_callback(move |_, inserted, deleted, _, _| {
        if !guard.get() && (inserted > 0 || deleted > 0) {
            let mut m = m.borrow_mut();
            m.edit(b.text());
            s.set_label(&m.status);
        }
    });
    query.set_tooltip("Literal, case-sensitive current-document search");
    win.set_callback(move |win| {
        let mut model = model.borrow_mut();
        if model.request_close() {
            win.hide();
        } else {
            status.set_label(&model.status);
        }
    });
    app.run()?;
    Ok(())
}
