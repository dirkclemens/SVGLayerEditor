# SVGLayerEditor

macOS SwiftUI app for editing SVG layer hierarchies, previewing graphics, and saving changes.
Fully vibe coded / agentic coded using GPT-5.2-Codex

## Screenshots

<img width="529" height="400" alt="screenshot" src="https://github.com/user-attachments/assets/56ae8858-9bd8-4815-a56a-557420daa597" />


## Features

- Open, edit, and save SVG files.
- Document XML editor with live re-parse and error banner.
- Layer tree with selection, drag & drop reorder, indent/outdent, and delete.
- Per-layer visibility toggle (hidden layers not rendered in preview).
- Shapes: `rect`, `circle`, `ellipse`, `line`, `polygon`, `polyline`, `text`, and group `<g>`.
- Preserve fill/stroke defaults for new shapes.
- Preview with grid and canvas border, zoom controls, fit-to-view, and selection outlines.
- Mouse drag to move/resize selected elements (paths and basic shapes).
- Rotate selected element in 15-degree steps.
- Align selected element to canvas center or to a reference element.
- Undo/redo stack.
- Open Recent menu.
- File drop to open SVGs.
- Unsaved changes indicator + close confirmation.

## UI Overview

- Left: Layer tree with visibility toggles and reorder support.
- Right: Document XML editor, selected element details, and preview.
- Top toolbar: file actions, undo/redo, shape tools, color pickers, rotate, align.

## Document XML Editing

- The "Document XML" editor re-parses the entire SVG on change.
- Parsing errors show as a red banner next to the editor.
- Saving validates `width` and `height` on the root `<svg>`.

## Default New Document

```
<?xml version="1.0" encoding="UTF-8"?>
<svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
</svg>
```

## Layer Operations

- Select any layer to edit its raw XML and attributes.
- Toggle visibility via the eye icon (hidden layers are not rendered).
- Drag & drop to reorder; use indent/outdent for hierarchy changes.

## Shortcuts

- New: `Cmd+N`
- Open: `Cmd+O`
- Save: `Cmd+S`
- Save As: `Cmd+Shift+S`
- Undo: `Cmd+Z`
- Redo: `Cmd+Shift+Z`
- Delete: `Delete`
- Move Up/Down: `Cmd+Option+Up/Down`
- Indent/Outdent: `Cmd+]` / `Cmd+[`
- Insert from Clipboard: `Cmd+Shift+V`

## Notes

- Save panels require the App Sandbox user-selected **read/write** entitlement.
- Root SVG attributes (`width`, `height`, `viewBox`) are editable when the root is selected.

## Development

Open the Xcode project in `SVGLayerEditor.xcodeproj`.
