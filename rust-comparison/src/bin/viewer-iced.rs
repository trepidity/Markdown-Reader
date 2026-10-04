use iced::{
    Element, Length, Theme,
    widget::{button, column, row, scrollable, text, text_editor, text_input},
};
use markdown_reader_rust::shell::Model;
#[derive(Debug, Clone)]
enum Message {
    Close(iced::window::Id),
    Path(String),
    Query(String),
    Action(&'static str),
    Edit(text_editor::Action),
    Toggle,
    Theme,
}
struct Viewer {
    model: Model,
    editor: text_editor::Content,
}
impl Viewer {
    fn new() -> Self {
        Self {
            model: Model::startup(),
            editor: text_editor::Content::new(),
        }
    }
    fn update(&mut self, message: Message) -> iced::Task<Message> {
        match message {
            Message::Close(id) => {
                if self.model.request_close() {
                    return iced::window::close(id);
                }
            }
            Message::Path(path) => self.model.path = path,
            Message::Query(query) => self.model.query = query,
            Message::Action(action) => {
                self.model.action(action);
                if self.model.editing {
                    self.editor = text_editor::Content::with_text(&self.model.core.state.text);
                }
            }
            Message::Toggle => {
                self.model.editing = !self.model.editing;
                if self.model.editing {
                    self.editor = text_editor::Content::with_text(&self.model.core.state.text);
                }
            }
            Message::Theme => self.model.dark = !self.model.dark,
            Message::Edit(action) => {
                let changed = action.is_edit();
                self.editor.perform(action);
                if changed {
                    self.model.edit(self.editor.text());
                }
            }
        }
        iced::Task::none()
    }
    fn view(&self) -> Element<'_, Message> {
        let controls = row![
            text_input("Path / Save Copy destination", &self.model.path).on_input(Message::Path),
            button("Open").on_press(Message::Action("open")),
            button("Undo").on_press(Message::Action("undo")),
            button("Redo").on_press(Message::Action("redo")),
            button("Reload").on_press(Message::Action("reload")),
            button("Save Copy").on_press(Message::Action("saveCopy"))
        ]
        .spacing(6);
        let tools = row![
            button(if self.model.editing {
                "Preview"
            } else {
                "Edit"
            })
            .on_press(Message::Toggle),
            button("Theme").on_press(Message::Theme),
            text_input("Search current document", &self.model.query).on_input(Message::Query),
            button("Search").on_press(Message::Action("search"))
        ]
        .spacing(6);
        let content: Element<'_, Message> = if self.model.editing {
            text_editor(&self.editor)
                .on_action(Message::Edit)
                .height(Length::Fill)
                .into()
        } else {
            let blocks = self.model.core.state.blocks.iter().map(|block| {
                let size = if block.kind == "heading" {
                    32 - u16::from(block.level) * 2
                } else {
                    16
                };
                let spans: Vec<iced::widget::text::Span<'_, (), iced::Font>> = block
                    .runs
                    .iter()
                    .map(|run| {
                        iced::widget::span(run.text.as_str())
                            .font(iced::Font {
                                family: if run.mono {
                                    iced::font::Family::Monospace
                                } else {
                                    iced::font::Family::SansSerif
                                },
                                weight: if run.bold {
                                    iced::font::Weight::Bold
                                } else {
                                    iced::font::Weight::Normal
                                },
                                style: if run.italic {
                                    iced::font::Style::Italic
                                } else {
                                    iced::font::Style::Normal
                                },
                                ..iced::Font::DEFAULT
                            })
                            .strikethrough(run.strike)
                    })
                    .collect();
                iced::widget::rich_text(spans).size(f32::from(size)).into()
            });
            scrollable(column(blocks).spacing(12).width(Length::Fill))
                .height(Length::Fill)
                .into()
        };
        column![controls, tools, text(&self.model.status), content]
            .spacing(10)
            .padding(16)
            .into()
    }
}
fn main() -> iced::Result {
    iced::application(Viewer::new, Viewer::update, Viewer::view)
        .title("Markdown Reader Rust Iced")
        .theme(|v: &Viewer| {
            if v.model.dark {
                Theme::Dark
            } else {
                Theme::Light
            }
        })
        .exit_on_close_request(false)
        .subscription(|_| iced::window::close_requests().map(Message::Close))
        .window_size((1080.0, 780.0))
        .run()
}
