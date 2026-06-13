import { describe, expect, it } from "vitest";
import { renderMarkdown } from "./markdown";

describe("markdown renderer", () => {
  it("renders headings and code fences with escaped highlighted code", () => {
    const result = renderMarkdown(
      '## Install\n\n```ts\nconst value = "ok";\n```',
      { copyButtons: true },
    );

    expect(result.headings).toEqual([
      { id: "install", level: 2, text: "Install" },
    ]);
    expect(result.html).toContain('id="install"');
    expect(result.html).toContain('class="md-code"');
    expect(result.html).toContain('data-copy="const value = &quot;ok&quot;;"');
    expect(result.html).toContain('<span class="tok-kw">const</span>');
  });

  it("escapes HTML in assistant-controlled markdown", () => {
    const result = renderMarkdown("Hello <script>alert(1)</script>");
    expect(result.html).toContain("&lt;script&gt;");
    expect(result.html).not.toContain("<script>");
  });

  it("renders safe image blocks", () => {
    const result = renderMarkdown(
      "![Composer 2.5 in OpenCode](/opencode-composer-2-5.webp)",
    );

    expect(result.html).toContain('<figure class="md-image">');
    expect(result.html).toContain('src="/opencode-composer-2-5.webp"');
    expect(result.html).toContain('alt="Composer 2.5 in OpenCode"');
  });

  it("renders collapsible details blocks with escaped summaries", () => {
    const result = renderMarkdown(
      ["::: details Old <route>", "", "Use `v1`.", "", ":::"].join("\n"),
    );

    expect(result.html).toContain('<details class="md-details">');
    expect(result.html).toContain("<summary>Old &lt;route&gt;</summary>");
    expect(result.html).toContain("Use <code>v1</code>.");
  });

  it("renders tabbed code samples and relative links", () => {
    const result = renderMarkdown(
      [
        "Open [Cursor Chat](/chat).",
        "",
        "::: code-tabs",
        "",
        "```ts",
        'const value = "ok";',
        "```",
        "",
        "```python",
        'print("ok")',
        "```",
        "",
        ":::",
      ].join("\n"),
      { copyButtons: true },
    );

    expect(result.html).toContain('<a href="/chat">Cursor Chat</a>');
    expect(result.html).toContain("data-code-tabs");
    expect(result.html).toContain('data-code-tab="0"');
    expect(result.html).toContain('data-code-panel="1" hidden');
    expect(result.html).toContain("TypeScript");
    expect(result.html).toContain("Python");
    expect(result.html).toContain('<span class="tok-kw">print</span>');
  });
});
