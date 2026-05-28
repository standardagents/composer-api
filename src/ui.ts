import {
  ArrowRight,
  BookOpen,
  Check,
  ChevronDown,
  Code2,
  Copy,
  Download,
  Github,
  ImagePlus,
  KeyRound,
  Loader2,
  Lock,
  MessageSquarePlus,
  MonitorDot,
  Pencil,
  Plus,
  RefreshCw,
  SendHorizontal,
  Server,
  Sparkles,
  Star,
  Terminal,
  Trash2,
  TriangleAlert,
  User,
  X,
  Zap,
  type IconNode
} from "lucide";

/** Lucide icons referenced by `data-lucide` attributes or by name in code. */
export const icons = {
  ArrowRight,
  BookOpen,
  Check,
  ChevronDown,
  Code2,
  Copy,
  Download,
  Github,
  ImagePlus,
  KeyRound,
  Loader2,
  Lock,
  MessageSquarePlus,
  MonitorDot,
  Pencil,
  Plus,
  RefreshCw,
  SendHorizontal,
  Server,
  Sparkles,
  Star,
  Terminal,
  Trash2,
  TriangleAlert,
  User,
  X,
  Zap
} satisfies Record<string, IconNode>;

export type IconName = keyof typeof icons;

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function escapeAttr(value: string): string {
  return escapeHtml(value).replaceAll("`", "&#096;");
}

/** Serialize a Lucide icon node to an inline SVG string. */
export function iconToSvg(icon: IconNode, attrs: Record<string, string | number> = {}): string {
  const attrText = Object.entries({
    xmlns: "http://www.w3.org/2000/svg",
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    "stroke-width": 2,
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
    width: 18,
    height: 18,
    "aria-hidden": "true",
    ...attrs
  })
    .map(([key, value]) => `${key}="${escapeAttr(String(value))}"`)
    .join(" ");
  const children = icon
    .map(([tag, childAttrs]) => {
      const childAttrText = Object.entries(childAttrs)
        .map(([key, value]) => `${key}="${escapeAttr(String(value))}"`)
        .join(" ");
      return `<${tag} ${childAttrText}></${tag}>`;
    })
    .join("");
  return `<svg ${attrText}>${children}</svg>`;
}

/** Render an icon by name, falling back to an empty string for unknown names. */
export function icon(name: IconName, attrs: Record<string, string | number> = {}): string {
  return iconToSvg(icons[name], attrs);
}

type QueryRoot = {
  querySelectorAll<E extends Element = Element>(selectors: string): NodeListOf<E>;
};

/** Replace every `<i data-lucide="...">` placeholder under `root` with an SVG. */
export function hydrateIcons(root: QueryRoot = document): void {
  for (const el of root.querySelectorAll<HTMLElement>("[data-lucide]")) {
    const raw = el.dataset.lucide || "";
    const pascal = raw
      .split("-")
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
      .join("") as IconName;
    const node = icons[pascal];
    if (node) {
      const size = el.dataset.size ? Number(el.dataset.size) : 18;
      el.outerHTML = iconToSvg(node, { width: size, height: size });
    }
  }
}

/** Wire any `[data-copy]` buttons under `root` to the clipboard. */
export function wireCopyButtons(root: QueryRoot = document): void {
  for (const button of root.querySelectorAll<HTMLButtonElement>("[data-copy]")) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy || "");
        button.classList.add("copied");
        window.setTimeout(() => button.classList.remove("copied"), 1100);
      } catch {
        /* clipboard unavailable - ignore */
      }
    });
  }
}

/** Lightweight JSON syntax highlighter that returns escaped HTML. */
export function highlightJson(json: string): string {
  return json.replace(
    /("(?:\\.|[^"\\])*")(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}[\],]/g,
    (match, stringToken: string | undefined, keySuffix: string | undefined) => {
      if (stringToken) {
        const className = keySuffix ? "j-key" : "j-str";
        const suffix = keySuffix ? keySuffix.replace(":", '<span class="j-punc">:</span>') : "";
        return `<span class="${className}">${escapeHtml(stringToken)}</span>${suffix}`;
      }
      if (match === "true" || match === "false" || match === "null") {
        return `<span class="j-bool">${match}</span>`;
      }
      if (/^-?\d/.test(match)) return `<span class="j-num">${match}</span>`;
      return `<span class="j-punc">${escapeHtml(match)}</span>`;
    }
  );
}
