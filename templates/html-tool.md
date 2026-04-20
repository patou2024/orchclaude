# orchclaude template: HTML Tool

Build a standalone single-file HTML tool that runs entirely in the browser.

## Project Goal

Create a self-contained HTML page (one `.html` file, no build step, no server required)
that solves a useful problem. Choose one of the following based on context clues in
this directory, or default to a **data converter / formatter tool**:

- Data converter (JSON ↔ CSV ↔ YAML, base64 encode/decode, URL encode/decode)
- Text processor (word count, find-and-replace, markdown preview, diff viewer)
- Calculator or unit converter (currency, units, time zones, percentage)
- Mini dashboard (reads localStorage, visualises data with a canvas chart)
- Form generator (build and preview an HTML form, copy the generated markup)

## Technical requirements

- **Single file**: all CSS and JavaScript inline in `<style>` and `<script>` tags
- **Zero dependencies**: no CDN links, no npm, no build tools
- **Works offline**: open the file directly with `file://` in any modern browser
- **Responsive**: usable on both desktop (1024px+) and mobile (375px+)
- **Dark/light mode**: respects `prefers-color-scheme` automatically
- **Accessible**: semantic HTML, proper labels, keyboard-navigable

## Design standards

- Clean, minimal UI — no garish colors, no unnecessary decorations
- Clear primary action button (large, high-contrast)
- Inline error messages when input is invalid
- Copy-to-clipboard button wherever the output is text

## Deliverables

1. `index.html` — the working tool (single file)
2. `README.md` with:
   - What the tool does
   - How to open it (just `open index.html` or double-click)
   - Description of every feature/control

## Acceptance

Open `index.html` in a browser and verify:
- The tool performs its primary function correctly
- Error states are handled gracefully (bad input, empty input)
- The page looks correct on a narrow viewport (resize to 400px wide)
- No console errors on load or during use

When done, output: ORCHESTRATION_COMPLETE
