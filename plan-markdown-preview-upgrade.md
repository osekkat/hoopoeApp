# Markdown Preview Upgrade — Implemented

**Status:** Completed (commit `a3d3196`)

## What changed

Replaced the hand-rolled Swift `MarkdownHTMLConverter` (~230 lines) with three battle-tested JS libraries running inside the existing `WKWebView`, adopted from VS Code's markdown preview architecture.

## Libraries bundled (UMD browser builds)

| Library | Version | Global | Size | Role |
|---------|---------|--------|------|------|
| markdown-it | 12.3.2 | `window.markdownit` | 101KB | CommonMark-compliant parser |
| highlight.js | 11.8.0 | `window.hljs` | 121KB | Syntax highlighting for fenced code blocks |
| morphdom | 2.7.7 | `window.morphdom` | 12KB | Incremental DOM diffing (no full reloads) |

## Files changed

| File | Change |
|------|--------|
| `Hoopoe/MarkdownPreviewView.swift` | Deleted `MarkdownHTMLConverter`; rewrote `PreviewHTMLTemplate` to load JS libs inline and expose `updatePreview()`/`scrollToFraction()` JS functions; rewrote `MarkdownPreviewRepresentable` to send raw markdown via `evaluateJavaScript` with a `pageReady` message handler for lifecycle coordination |
| `Hoopoe/PlanGenerationView.swift` | Streaming generation pane (`.generating` case) now uses `MarkdownPreviewRepresentable` with `scrollFraction: 1` instead of raw `Text()`, so markdown renders live during streaming |
| `Hoopoe.xcodeproj/project.pbxproj` | Added 3 JS files to file references, Hoopoe group, and Copy Bundle Resources |
| `Hoopoe/markdown-it.min.js` | New — vendor bundle |
| `Hoopoe/highlight.min.js` | New — vendor bundle |
| `Hoopoe/morphdom-umd.min.js` | New — vendor bundle |

## Architecture

```
Swift (MarkdownPreviewRepresentable)
  │
  │  makeNSView: loads template HTML once (vendor JS inlined)
  │  updateNSView: sends raw markdown via evaluateJavaScript
  │
  ▼
WKWebView
  │
  │  markdown-it: parses markdown → HTML
  │  highlight.js: syntax-highlights code fences
  │  morphdom: diffs DOM incrementally (no full page reload)
  │
  │  pageReady message → Swift coordinator flushes pending markdown
  │  scrollToFraction() → scroll sync from editor cursor
  │
  ▼
Rendered preview (light/dark mode via CSS variables)
```

**Key design decisions:**
- Vendor JS loaded inline via `String(contentsOf:)` from `Bundle.main` to avoid WKWebView `file://` security restrictions
- `JSONSerialization.data(withJSONObject:options:.fragmentsAllowed)` for safe JS string escaping
- `WKScriptMessageHandler` for `pageReady` eliminates the old 50ms `DispatchQueue.main.asyncAfter` timing hack
- Highlight.js token colors use CSS variables that adapt to light/dark mode (Xcode-style palette)
- Public interface `MarkdownPreviewRepresentable(markdown:scrollFraction:)` unchanged — no call-site modifications needed

## Verification

- [x] `xcodebuild build` compiles clean
- [x] JS files confirmed in app bundle (`Contents/Resources/`)
- [ ] Manual: rendered markdown in plan editor preview pane
- [ ] Manual: syntax-highlighted code blocks (```swift, ```rust)
- [ ] Manual: light/dark mode toggle
- [ ] Manual: flicker-free typing in editor
- [ ] Manual: scroll sync
- [ ] Manual: streaming generation renders markdown live
