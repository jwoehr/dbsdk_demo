# Markdown Authoring Standards

When creating or modifying ANY Markdown (`.md`) files in this project, adhere
strictly to the following content and structural rules.

## 1. File Handling & Content

- Preserve existing structure: do not silently delete content without explicit
  confirmation.
- Use **tool-agnostic CommonMark**. Do not use vendor-specific syntax (e.g.,
  admonitions) unless requested.
- **Tone and Voice**: Second person, present tense, active voice. Short
  paragraphs (3–5 sentences). Avoid filler words ("simply", "just",
  "obviously").

## 2. Links and References

- All `language construct` or filename references in prose MUST be rendered as
  clickable Markdown links.
  - Good: `[filename.ext](relative/path/to/filename.ext)`
  - Bad: `` `filename.ext` `` (bare backticks are not allowed for filenames in
    prose)
- Construct references inside fenced code blocks are exempt.
- Images require alt text (use `alt=""` for decorative).
- All relative links MUST resolve from the file's directory.
- Use reference-style links only when the same URL is reused three or more
  times; otherwise use inline links.

## 3. Code & Diagrams

- Every fenced code block MUST include a language tag.
- Inline code MUST be used for filenames, flag names, env vars, and small
  literals.
- Mermaid diagrams are permitted (`mermaid` language tag). Node/edge labels
  inside square brackets MUST NOT contain double quotes or parentheses (e.g.,
  use `A[User Admin]` not `A["User (Admin)"]`).
- Each Mermaid diagram MUST be preceded by a short caption sentence explaining
  its purpose.

## 4. Headings

- One H1 per file.
- Heading levels MUST NOT skip (no H1 → H3 jump).
- Heading text uses **sentence case** unless proper nouns are involved (e.g.,
  `## Phase 1: Security and correctness`).

## 5. Automated Formatting (CRITICAL)

Do not attempt to manually count line lengths or spacing for Markdown linting
rules. Instead, rely on automated formatting.

**After creating or modifying ANY markdown file, you MUST run the following
command to format it automatically:**
`npx prettier --write --prose-wrap always <filepath>`
