# Mermaid plugin

This diagram is rendered by the optional Mermaid plugin. The reader displays a
vector PDF and retains the original SVG for export.

```mermaid
flowchart LR
    Start[Open Markdown] --> Match{Mermaid fence?}
    Match -->|Yes| Render[Temporary plugin]
    Render --> Vector[SVG and PDF]
    Vector --> Reader[Native reader]
    Match -->|No| Reader
```

## Sequence diagram

```mermaid
sequenceDiagram
    participant Reader
    participant Parser
    participant Plugin
    Reader->>Parser: Open document
    Parser->>Plugin: Render diagram
    Plugin-->>Parser: SVG and PDF
    Note over Plugin: Process exits
    Parser-->>Reader: Presentation
```

## Ordinary code remains code

```go
fmt.Println("No plugin is launched for this block")
```
