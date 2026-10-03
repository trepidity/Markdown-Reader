//! Independent Rust comparison core; all shells use the same dispatcher.
mod document;
mod presentation;
mod session;
pub mod shell;
pub use presentation::{Block, Run};
pub use session::{Session, State};
