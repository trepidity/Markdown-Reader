use markdown_viewer_rust::shell::Model;
use tao::{
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::WebViewBuilder;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let event_loop = EventLoopBuilder::<String>::with_user_event().build();
    let window = WindowBuilder::new()
        .with_title("Markdown Viewer Rust Wry")
        .with_inner_size(tao::dpi::LogicalSize::new(1080, 780))
        .build(&event_loop)?;
    let proxy = event_loop.create_proxy();
    let mut model = Model::startup();
    let view = WebViewBuilder::new()
        .with_html(include_str!("../wry.html"))
        .with_navigation_handler(|url| url == "about:blank")
        .with_ipc_handler(move |request| {
            if let Err(error) = proxy.send_event(request.body().clone()) {
                eprintln!("IPC delivery failed: {error}");
            }
        })
        .build(&window)?;
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                if model.request_close() {
                    *flow = ControlFlow::Exit;
                } else if let Ok(message) = serde_json::to_string(&model.status)
                    && let Err(error) = view.evaluate_script(&format!(
                        "document.getElementById('status').textContent={message}"
                    ))
                {
                    eprintln!("UI delivery failed: {error}");
                }
            }
            Event::UserEvent(raw) => {
                let state = match serde_json::from_str(&raw) {
                    Ok(command) => model.core.dispatch(command),
                    Err(error) => {
                        eprintln!("Invalid IPC: {error}");
                        return;
                    }
                };
                if let Err(error) = view.evaluate_script(&format!("receive({state})")) {
                    eprintln!("UI delivery failed: {error}");
                }
            }
            _ => {}
        }
    });
}
