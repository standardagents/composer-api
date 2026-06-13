import { escapeAttr, escapeHtml, highlightJson } from "./ui";

export interface MarkdownHeading {
  id: string;
  level: number;
  text: string;
}

export interface MarkdownResult {
  html: string;
  headings: MarkdownHeading[];
}

interface CodeSample {
  lang: string;
  code: string;
}

interface MarkdownOptions {
  copyButtons?: boolean;
  headingIds?: boolean;
}

export function renderMarkdown(
  markdown: string,
  options: MarkdownOptions = {},
): MarkdownResult {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const html: string[] = [];
  const headings: MarkdownHeading[] = [];
  let paragraph: string[] = [];
  let list: string[] = [];
  let listType: "ul" | "ol" | null = null;
  let codeLang = "";
  let codeLines: string[] | null = null;
  let codeTabs: CodeSample[] | null = null;
  let detailsSummary = "";
  let detailsLines: string[] | null = null;

  const flushParagraph = () => {
    if (!paragraph.length) return;
    html.push(`<p>${renderInline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };

  const flushList = () => {
    if (!list.length || !listType) return;
    html.push(
      `<${listType}>${list.map((item) => `<li>${renderInline(item)}</li>`).join("")}</${listType}>`,
    );
    list = [];
    listType = null;
  };

  const flushCode = () => {
    if (!codeLines) return;
    const code = codeLines.join("\n");
    html.push(codeBlockHtml(code, codeLang, options));
    codeLines = null;
    codeLang = "";
  };

  const flushTabbedCode = () => {
    if (!codeTabs) return;
    if (codeLines) {
      codeTabs.push({ lang: codeLang || "text", code: codeLines.join("\n") });
      codeLines = null;
      codeLang = "";
    }
    html.push(renderCodeTabs(codeTabs, options));
    codeTabs = null;
  };

  const flushDetails = () => {
    if (!detailsLines) return;
    const rendered = renderMarkdown(detailsLines.join("\n"), {
      ...options,
      headingIds: false,
    });
    html.push(
      `<details class="md-details"><summary>${renderInline(detailsSummary)}</summary>${rendered.html}</details>`,
    );
    detailsSummary = "";
    detailsLines = null;
  };

  for (const line of lines) {
    const fence = /^```(\S*)\s*$/.exec(line);
    if (detailsLines) {
      if (line.trim() === ":::") {
        flushDetails();
        continue;
      }
      detailsLines.push(line);
      continue;
    }

    if (codeTabs) {
      if (fence) {
        if (codeLines) {
          codeTabs.push({
            lang: codeLang || "text",
            code: codeLines.join("\n"),
          });
          codeLines = null;
          codeLang = "";
        } else {
          codeLang = fence[1] || "text";
          codeLines = [];
        }
        continue;
      }
      if (codeLines) {
        codeLines.push(line);
        continue;
      }
      if (line.trim() === ":::") {
        flushTabbedCode();
        continue;
      }
      continue;
    }

    if (fence) {
      if (codeLines) flushCode();
      else {
        flushParagraph();
        flushList();
        codeLang = fence[1] || "text";
        codeLines = [];
      }
      continue;
    }

    const details = /^:::\s*details\s+(.+)$/.exec(line.trim());
    if (details) {
      flushParagraph();
      flushList();
      detailsSummary = details[1];
      detailsLines = [];
      continue;
    }

    if (line.trim() === "::: code-tabs") {
      flushParagraph();
      flushList();
      codeTabs = [];
      continue;
    }

    if (codeLines) {
      codeLines.push(line);
      continue;
    }

    const heading = /^(#{1,3})\s+(.+)$/.exec(line);
    if (heading) {
      flushParagraph();
      flushList();
      const level = heading[1].length;
      const text = stripInline(heading[2]);
      const id = slugify(text);
      headings.push({ id, level, text });
      const idAttr =
        options.headingIds !== false ? ` id="${escapeAttr(id)}"` : "";
      html.push(`<h${level}${idAttr}>${renderInline(heading[2])}</h${level}>`);
      continue;
    }

    const image = /^!\[([^\]]*)\]\(((?:\/|https?:\/\/)[^)\s]+)\)$/.exec(
      line.trim(),
    );
    if (image) {
      flushParagraph();
      flushList();
      html.push(
        `<figure class="md-image"><img src="${escapeAttr(image[2])}" alt="${escapeAttr(image[1])}" loading="lazy" /></figure>`,
      );
      continue;
    }

    const unordered = /^\s*[-*]\s+(.+)$/.exec(line);
    const ordered = /^\s*\d+\.\s+(.+)$/.exec(line);
    if (unordered || ordered) {
      flushParagraph();
      const nextType = unordered ? "ul" : "ol";
      if (listType && listType !== nextType) flushList();
      listType = nextType;
      list.push((unordered || ordered)?.[1] || "");
      continue;
    }

    if (!line.trim()) {
      flushParagraph();
      flushList();
      continue;
    }

    paragraph.push(line.trim());
  }

  flushCode();
  flushTabbedCode();
  flushDetails();
  flushParagraph();
  flushList();
  return { html: html.join("\n"), headings };
}

function renderCodeTabs(
  samples: CodeSample[],
  options: MarkdownOptions,
): string {
  const valid = samples.filter((sample) => sample.code.trim());
  if (!valid.length) return "";
  const buttons = valid
    .map(
      (sample, index) =>
        `<button class="md-code-tab${index === 0 ? " is-active" : ""}" type="button" role="tab" aria-selected="${index === 0 ? "true" : "false"}" data-code-tab="${index}">${languageLabel(sample.lang)}</button>`,
    )
    .join("");
  const panels = valid
    .map((sample, index) =>
      codeBlockHtml(sample.code, sample.lang, options, index === 0, index),
    )
    .join("");
  return `<div class="md-code-tabs" data-code-tabs><div class="md-code-tab-list" role="tablist">${buttons}</div>${panels}</div>`;
}

function codeBlockHtml(
  code: string,
  lang: string,
  options: MarkdownOptions,
  active = true,
  index?: number,
): string {
  const highlighted = highlightCode(code, lang);
  const copy = options.copyButtons
    ? `<button class="code-copy" type="button" data-copy="${escapeAttr(code)}">Copy</button>`
    : "";
  const className =
    index === undefined ? "md-code" : `md-code${active ? " is-active" : ""}`;
  const panelAttrs =
    index === undefined
      ? ""
      : ` role="tabpanel" data-code-panel="${index}"${active ? "" : " hidden"}`;
  return (
    `<figure class="${className}" data-lang="${escapeAttr(lang || "text")}"${panelAttrs}>` +
    `<figcaption><span>${escapeHtml(languageLabel(lang || "text"))}</span>${copy}</figcaption>` +
    `<pre><code>${highlighted}</code></pre>` +
    `</figure>`
  );
}

function languageLabel(lang: string): string {
  const normalized = lang.toLowerCase();
  if (["ts", "tsx", "typescript"].includes(normalized)) return "TypeScript";
  if (["js", "jsx", "javascript"].includes(normalized)) return "JavaScript";
  if (["py", "python"].includes(normalized)) return "Python";
  if (["bash", "sh", "shell"].includes(normalized)) return "Shell";
  if (normalized === "http") return "HTTP";
  if (normalized === "json") return "JSON";
  return lang || "text";
}

function renderInline(value: string): string {
  let text = escapeHtml(value);
  text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(
    /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
    (_match, label: string, href: string) =>
      `<a href="${escapeAttr(href)}" target="_blank" rel="noreferrer">${label}</a>`,
  );
  text = text.replace(
    /\[([^\]]+)\]((?:\((?:\/|#)[^)\s]*\)))/g,
    (_match, label: string, wrappedHref: string) => {
      const href = wrappedHref.slice(1, -1);
      return `<a href="${escapeAttr(href)}">${label}</a>`;
    },
  );
  return text;
}

function stripInline(value: string): string {
  return value
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
}

function slugify(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "section"
  );
}

function highlightCode(code: string, lang: string): string {
  const normalized = lang.toLowerCase();
  if (normalized === "json") return highlightJson(code);
  if (
    ["js", "jsx", "ts", "tsx", "typescript", "javascript"].includes(normalized)
  )
    return highlightTs(code);
  if (["py", "python"].includes(normalized)) return highlightPython(code);
  if (["bash", "sh", "shell"].includes(normalized)) return highlightShell(code);
  if (normalized === "http") return highlightHttp(code);
  return escapeHtml(code);
}

function highlightTs(code: string): string {
  return escapeHtml(code)
    .replace(/(&quot;[^&]*?&quot;|'[^']*')/g, '<span class="tok-str">$1</span>')
    .replace(
      /\b(import|from|const|let|var|await|async|for|of|return|new|process|console)\b/g,
      '<span class="tok-kw">$1</span>',
    )
    .replace(
      /\b(true|false|null|undefined)\b/g,
      '<span class="tok-bool">$1</span>',
    );
}

function highlightShell(code: string): string {
  return escapeHtml(code)
    .replace(
      /^(\s*)(curl|npm|npx|pnpm|yarn|export)\b/gm,
      '$1<span class="tok-kw">$2</span>',
    )
    .replace(
      /(&quot;[^&]*?&quot;|'[^']*')/g,
      '<span class="tok-str">$1</span>',
    );
}

function highlightPython(code: string): string {
  return escapeHtml(code)
    .replace(/(&quot;[^&]*?&quot;|'[^']*')/g, '<span class="tok-str">$1</span>')
    .replace(
      /\b(import|from|as|def|return|for|in|with|print|True|False|None)\b/g,
      '<span class="tok-kw">$1</span>',
    );
}

function highlightHttp(code: string): string {
  return escapeHtml(code).replace(
    /^([A-Za-z-]+):/gm,
    '<span class="j-key">$1</span><span class="j-punc">:</span>',
  );
}
