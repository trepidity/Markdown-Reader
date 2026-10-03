use markdown_viewer_rust::Session;
use serde_json::json;
use std::fs;

#[test]
fn edits_and_undo_reach_disk_and_stale_commands_cannot_overwrite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("note.md");
    fs::write(&path, "# Original").unwrap();
    let mut app = Session::default();
    let opened = app.dispatch(json!({"action":"open","path":path}));
    assert_eq!(opened["text"], "# Original");
    let edited = app.dispatch(
        json!({"action":"edit","path":path,"revision":opened["revision"],"text":"# Changed"}),
    );
    assert_eq!(edited["error"], "");
    assert_eq!(fs::read_to_string(&path).unwrap(), "# Changed");
    let stale = app.dispatch(
        json!({"action":"edit","path":path,"revision":opened["revision"],"text":"stale"}),
    );
    assert_ne!(stale["error"], "");
    assert_eq!(fs::read_to_string(&path).unwrap(), "# Changed");
    let undone = app.dispatch(json!({"action":"undo"}));
    assert_eq!(undone["text"], "# Original");
    assert_eq!(fs::read_to_string(&path).unwrap(), "# Original");
}

#[test]
fn external_conflict_keeps_draft_blocks_navigation_and_can_save_copy() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("note.md");
    let other = dir.path().join("other.md");
    let copy = dir.path().join("copy.md");
    fs::write(&path, "Original").unwrap();
    fs::write(&other, "Other").unwrap();
    let mut app = Session::default();
    let opened = app.dispatch(json!({"action":"open","path":path}));
    fs::write(&path, "External").unwrap();
    let draft = app.dispatch(
        json!({"action":"edit","path":path,"revision":opened["revision"],"text":"Draft"}),
    );
    assert_eq!(draft["dirty"], true);
    let blocked = app.dispatch(json!({"action":"open","path":other}));
    assert_ne!(blocked["error"], "");
    assert_eq!(blocked["text"], "Draft");
    assert_eq!(
        blocked["path"],
        path.canonicalize().unwrap().to_str().unwrap()
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "External");
    assert_ne!(
        app.dispatch(json!({"action":"saveCopy","path":other}))["error"],
        ""
    );
    assert_eq!(fs::read_to_string(&other).unwrap(), "Other");
    assert_eq!(
        app.dispatch(json!({"action":"saveCopy","path":copy}))["error"],
        ""
    );
    assert_eq!(fs::read_to_string(copy).unwrap(), "Draft");
}

#[test]
fn preview_preserves_content_without_executable_html_or_remote_images() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("note.md");
    fs::write(&path, "# Heading\n\nA **bold** word.\n\n| A | B |\n|---|---|\n| one | two |\n\n```rust\nlet x = 1;\n```\n\n<script>evil()</script>\n\n![alt](https://example.com/a.png)").unwrap();
    let state = Session::default().dispatch(json!({"action":"open","path":path}));
    let blocks = state["blocks"].as_array().unwrap();
    assert!(
        blocks
            .iter()
            .any(|b| b["kind"] == "heading" && b["runs"][0]["text"] == "Heading")
    );
    assert!(blocks.iter().any(|b| {
        b["runs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["text"] == "bold" && r["bold"] == true)
    }));
    let output = state["blocks"].to_string();
    assert!(output.contains("one") && output.contains("two") && output.contains("let x = 1;"));
    assert!(!output.contains("evil()") && !output.contains("https://example.com/a.png"));
}
