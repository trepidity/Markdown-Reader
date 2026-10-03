# Viewer-only experiment

This separate, user-requested build prioritizes low resident memory. Go parses
Markdown in a short-lived, read-only helper; AppKit presents one document using
TextKit 2. It does not use the editing application's document/history cache.

Product seams: the renderer command's arguments, emitted presentation stream,
exit status, and unchanged input files; the bundled app's Open action, displayed
content, read-only text, scrolling, and reload failure behavior. Measure physical
footprint in the native bundle, including any live renderer helper. Keep limitations
and transient-versus-settled memory explicit. Root verification gates still apply.
