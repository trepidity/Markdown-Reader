use eframe::egui;
use markdown_reader_rust::shell::Model;
struct Viewer {
    model: Model,
    draft: String,
}
impl eframe::App for Viewer {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        if ui.ctx().input(|i| i.viewport().close_requested()) && !self.model.request_close() {
            ui.ctx()
                .send_viewport_cmd(egui::ViewportCommand::CancelClose);
        }
        ui.ctx().set_visuals(if self.model.dark {
            egui::Visuals::dark()
        } else {
            egui::Visuals::light()
        });
        egui::CentralPanel::default().show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label("Path / Save Copy destination");
                ui.text_edit_singleline(&mut self.model.path);
                for (label, action) in [
                    ("Open", "open"),
                    ("Undo", "undo"),
                    ("Redo", "redo"),
                    ("Reload", "reload"),
                    ("Save Copy", "saveCopy"),
                ] {
                    if ui.button(label).clicked() {
                        self.model.action(action);
                        self.draft.clone_from(&self.model.core.state.text);
                    }
                }
            });
            ui.horizontal(|ui| {
                if ui
                    .selectable_label(!self.model.editing, "Preview")
                    .clicked()
                {
                    self.model.editing = false;
                }
                if ui.selectable_label(self.model.editing, "Edit").clicked() {
                    self.model.editing = true;
                    self.draft.clone_from(&self.model.core.state.text);
                }
                ui.checkbox(&mut self.model.dark, "Night");
                ui.text_edit_singleline(&mut self.model.query);
                if ui.button("Search").clicked() {
                    self.model.action("search");
                }
            });
            ui.label(&self.model.status);
            ui.separator();
            egui::ScrollArea::vertical().show(ui, |ui| {
                if self.model.editing {
                    if ui
                        .add(
                            egui::TextEdit::multiline(&mut self.draft)
                                .font(egui::TextStyle::Monospace)
                                .desired_width(f32::INFINITY),
                        )
                        .changed()
                    {
                        self.model.edit(self.draft.clone());
                    }
                } else {
                    for block in &self.model.core.state.blocks {
                        if block.kind == "rule" {
                            ui.separator();
                            continue;
                        }
                        let size = if block.kind == "heading" {
                            32.0 - f32::from(block.level) * 2.0
                        } else {
                            16.0
                        };
                        let mut job = egui::text::LayoutJob::default();
                        for run in &block.runs {
                            let color = ui.visuals().text_color();
                            job.append(
                                &run.text,
                                0.0,
                                egui::TextFormat {
                                    font_id: egui::FontId::new(
                                        size,
                                        if run.mono {
                                            egui::FontFamily::Monospace
                                        } else {
                                            egui::FontFamily::Proportional
                                        },
                                    ),
                                    color,
                                    italics: run.italic,
                                    extra_letter_spacing: if run.bold { 0.4 } else { 0.0 },
                                    strikethrough: if run.strike {
                                        egui::Stroke::new(1.0, color)
                                    } else {
                                        egui::Stroke::NONE
                                    },
                                    ..Default::default()
                                },
                            );
                        }
                        ui.label(job);
                        ui.add_space(8.0);
                    }
                }
            });
        });
    }
}
fn main() -> eframe::Result {
    let model = Model::startup();
    let draft = String::new();
    eframe::run_native(
        "Markdown Reader Rust egui",
        eframe::NativeOptions {
            viewport: egui::ViewportBuilder::default().with_inner_size([1080.0, 780.0]),
            ..Default::default()
        },
        Box::new(move |_| Ok(Box::new(Viewer { model, draft }))),
    )
}
