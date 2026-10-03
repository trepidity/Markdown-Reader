# Renderer comparison builds

User-authorized alternatives to the WebKit presentation: AppKit, Fyne, Qt Widgets,
and Gio. Keep document state, persistence, conflict handling, undo, and search in
`markdownviewer/internal/app`. Do not substitute independent save implementations.

Product seams are the existing JSON dispatcher, the structured presentation
response derived from its sanitized HTML, actual temporary files, and each
bundled native application. Renderer changes must preserve meaningful document
content; record unsupported interactions explicitly. Compare identical fixtures
and include all helper processes in native memory accounting.
