import {
  AlertTriangle,
  BookOpen,
  CheckCircle,
  Code,
  Copy,
  Github,
  GitBranch,
  KeyRound,
  Link,
  Lock,
  MessageSquare,
  Send,
  ShieldCheck,
  Sparkles,
  Star,
  Terminal,
  User,
  Zap,
  type IconNode
} from "lucide";
import "./styles.css";

const icons = {
  AlertTriangle,
  BookOpen,
  CheckCircle,
  Code,
  Copy,
  Github,
  GitBranch,
  KeyRound,
  Link,
  Lock,
  MessageSquare,
  Send,
  ShieldCheck,
  Sparkles,
  Star,
  Terminal,
  User,
  Zap
};

for (const icon of document.querySelectorAll<HTMLElement>("[data-lucide]")) {
  const name = icon.dataset.lucide || "";
  const pascal = name
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join("") as keyof typeof icons;
  const Icon = icons[pascal];
  if (Icon) icon.outerHTML = iconToSvg(Icon, { width: 18, height: 18, "aria-hidden": "true" });
}

/* ---- endpoints ---- */

const origin = window.location.origin;
const endpoints = {
  baseUrl: `${origin}/v1`,
  chatCompletions: `${origin}/v1/chat/completions`,
  responses: `${origin}/v1/responses`,
  models: `${origin}/v1/models`
};

const endpointList = document.querySelector<HTMLElement>("#endpoint-list");
if (endpointList) {
  endpointList.innerHTML = [
    endpointRow("Base URL", endpoints.baseUrl),
    endpointRow("Chat Completions", endpoints.chatCompletions),
    endpointRow("Responses", endpoints.responses),
    endpointRow("Models", endpoints.models)
  ].join("");
  wireCopyButtons(endpointList);
}

function endpointRow(label: string, value: string): string {
  return `
    <div class="endpoint-row">
      <span>${escapeHtml(label)}</span>
      <code>${escapeHtml(value)}</code>
      <button class="icon-button" data-copy="${escapeAttr(value)}" aria-label="Copy ${escapeAttr(label)}">
        ${iconToSvg(Copy, { width: 17, height: 17, "aria-hidden": "true" })}
      </button>
    </div>
  `;
}

function wireCopyButtons(root: HTMLElement) {
  root.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy || "");
        button.classList.add("copied");
        window.setTimeout(() => button.classList.remove("copied"), 900);
      } catch {
        /* clipboard unavailable - ignore */
      }
    });
  });
}

/* ---- demo ---- */

type ChatMessage = { role: "user" | "assistant"; content: string };

// The Cursor key lives only in runtime state - never localStorage/sessionStorage.
const messages: ChatMessage[] = [];

const keyInput = document.querySelector<HTMLInputElement>("#cursor-key");
const promptInput = document.querySelector<HTMLTextAreaElement>("#prompt");
const chatForm = document.querySelector<HTMLFormElement>("#chat-form");
const sendButton = document.querySelector<HTMLButtonElement>("#send");
const transcript = document.querySelector<HTMLElement>("#transcript");
const status = document.querySelector<HTMLElement>("#status");

const reqBody = document.querySelector<HTMLElement>("#req-body");
const toolState = document.querySelector<HTMLElement>("#tool-state");

let busy = false;

type ToolState = "idle" | "run" | "wait" | "stream" | "err";

function setToolState(state: ToolState, text: string) {
  if (!toolState) return;
  toolState.dataset.state = state;
  const label = toolState.querySelector<HTMLElement>(".tool-state-text");
  if (label) label.textContent = text;
}

function requestBody(extraUserMessage?: string): Record<string, unknown> {
  const outgoing = [...messages];
  if (extraUserMessage) outgoing.push({ role: "user", content: extraUserMessage });
  return {
    model: "composer-2.5",
    messages: outgoing,
    stream: true
  };
}

function renderRequestPreview() {
  const draft = promptInput?.value.trim() || "";
  if (reqBody) reqBody.innerHTML = highlightJson(JSON.stringify(requestBody(draft || undefined), null, 2));
}

function renderTranscript(streaming?: HTMLElement) {
  if (!transcript) return;
  if (!messages.length && !streaming) {
    transcript.innerHTML = `
      <div class="transcript-empty">
        ${iconToSvg(Sparkles, { width: 22, height: 22, "aria-hidden": "true" })}
        <span>Enter a key and a prompt to start.</span>
      </div>`;
    return;
  }
  transcript.innerHTML = "";
  for (const message of messages) transcript.appendChild(messageNode(message.role, message.content));
  if (streaming) transcript.appendChild(streaming);
  transcript.scrollTop = transcript.scrollHeight;
}

function messageNode(role: "user" | "assistant", content: string): HTMLElement {
  const node = document.createElement("div");
  node.className = `msg msg-${role}`;
  const icon = role === "user" ? User : Sparkles;
  node.innerHTML = `
    <span class="msg-avatar">${iconToSvg(icon, { width: 15, height: 15, "aria-hidden": "true" })}</span>
    <div class="msg-body"></div>`;
  const body = node.querySelector<HTMLElement>(".msg-body");
  if (body) body.textContent = content;
  return node;
}

function setStatus(message: string, tone?: "ok" | "err") {
  if (!status) return;
  const text = status.querySelector<HTMLElement>(".status-text");
  const isDefault = message === "";
  if (text) {
    text.textContent = isDefault
      ? "Your key stays in this tab - it is never written to storage."
      : message;
  }
  status.dataset.tone = isDefault ? "" : tone || "";
  const iconSvg = status.querySelector("svg");
  if (iconSvg) {
    const nextIcon = tone === "err" ? AlertTriangle : tone === "ok" ? CheckCircle : Lock;
    iconSvg.outerHTML = iconToSvg(nextIcon, { width: 14, height: 14, class: "status-icon", "aria-hidden": "true" });
  }
}

function setBusy(value: boolean) {
  busy = value;
  if (sendButton) sendButton.disabled = value;
  if (promptInput) promptInput.disabled = value;
}

promptInput?.addEventListener("input", () => {
  renderRequestPreview();
  autoGrow();
});

function autoGrow() {
  if (!promptInput) return;
  promptInput.style.height = "auto";
  promptInput.style.height = `${Math.min(promptInput.scrollHeight, 160)}px`;
}

promptInput?.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    chatForm?.requestSubmit();
  }
});

chatForm?.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (busy) return;

  const key = keyInput?.value.trim() || "";
  const prompt = promptInput?.value.trim() || "";
  if (!key) {
    setStatus("Enter your Cursor API key first.", "err");
    setToolState("err", "missing key");
    keyInput?.focus();
    return;
  }
  if (!prompt) {
    setStatus("Type a prompt to send.", "err");
    setToolState("err", "empty prompt");
    return;
  }

  messages.push({ role: "user", content: prompt });
  if (promptInput) {
    promptInput.value = "";
    autoGrow();
  }
  setBusy(true);
  setToolState("run", "starting run");
  setStatus("Starting a Cursor Cloud Agent run. First token can take around 20 seconds.");

  const pending = messageNode("assistant", "");
  const pendingBody = pending.querySelector<HTMLElement>(".msg-body");
  pending.classList.add("is-streaming");
  renderTranscript(pending);
  renderRequestPreview();

  let received = "";
  const typewriter = createTypewriter((text) => {
    if (pendingBody) pendingBody.textContent = text;
    if (transcript) transcript.scrollTop = transcript.scrollHeight;
  });

  try {
    const response = await fetch(endpoints.chatCompletions, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(requestBody())
    });

    if (!response.ok || !response.body) {
      const payload = (await response.json().catch(() => ({}))) as { error?: { message?: string } };
      throw new Error(payload.error?.message || `Request failed with status ${response.status}`);
    }

    setToolState("wait", "waiting token");
    setStatus("Run created; waiting for composer-2.5 to send the first token.");

    let sawFirstToken = false;
    for await (const delta of readChatStream(response.body)) {
      received += delta;
      if (!sawFirstToken) {
        sawFirstToken = true;
        setToolState("stream", "streaming");
        setStatus("Streaming response.");
      }
      typewriter.enqueue(delta);
    }

    const answer = await typewriter.done();
    if (!answer.trim()) throw new Error("composer-2.5 returned an empty response.");
    messages.push({ role: "assistant", content: answer });
    renderTranscript();
    setToolState("idle", "ready");
    setStatus("");
  } catch (error) {
    const partial = typewriter.value || received;
    if (partial.trim()) messages.push({ role: "assistant", content: partial });
    renderTranscript();
    setToolState("err", "error");
    setStatus(error instanceof Error ? error.message : "Unexpected error", "err");
  } finally {
    setBusy(false);
    renderRequestPreview();
    promptInput?.focus();
  }
});

function createTypewriter(onUpdate: (text: string) => void) {
  let rendered = "";
  let queue = "";
  let draining = false;
  let drainPromise: Promise<void> = Promise.resolve();

  const drain = async () => {
    draining = true;
    try {
      while (queue.length) {
        const size = queue.length > 120 ? 5 : queue.length > 48 ? 3 : 1;
        rendered += queue.slice(0, size);
        queue = queue.slice(size);
        onUpdate(rendered);
        await sleep(queue.length > 120 ? 6 : 12);
      }
    } finally {
      draining = false;
    }
  };

  return {
    get value() {
      return rendered;
    },
    enqueue(text: string) {
      queue += text;
      if (!draining) drainPromise = drain();
    },
    async done() {
      while (draining || queue.length) {
        if (!draining) drainPromise = drain();
        await drainPromise;
      }
      return rendered;
    }
  };
}

function sleep(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

async function* readChatStream(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  const readEvent = function* (rawEvent: string): Generator<string> {
    for (const line of rawEvent.split(/\r?\n/)) {
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      try {
        const chunk = JSON.parse(data) as { choices?: Array<{ delta?: { content?: string } }> };
        const content = chunk.choices?.[0]?.delta?.content;
        if (content) yield content;
      } catch {
        /* skip malformed chunk */
      }
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      buffer += decoder.decode();
      break;
    }
    buffer += decoder.decode(value, { stream: true });
    let boundary = findSseBoundary(buffer);
    while (boundary !== -1) {
      const rawEvent = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + boundaryLength(buffer, boundary));
      for (const content of readEvent(rawEvent)) yield content;
      boundary = findSseBoundary(buffer);
    }
  }

  if (buffer.trim()) {
    for (const content of readEvent(buffer)) yield content;
  }
}

function findSseBoundary(buffer: string) {
  const lf = buffer.indexOf("\n\n");
  const crlf = buffer.indexOf("\r\n\r\n");
  if (lf === -1) return crlf;
  if (crlf === -1) return lf;
  return Math.min(lf, crlf);
}

function boundaryLength(buffer: string, index: number) {
  return buffer.startsWith("\r\n\r\n", index) ? 4 : 2;
}

function highlightJson(json: string) {
  return json.replace(
    /("(?:\\.|[^"\\])*")(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],]/g,
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

renderRequestPreview();
renderTranscript();
setToolState("idle", "ready");

/* ---- shared helpers ---- */

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttr(value: string) {
  return escapeHtml(value).replaceAll("`", "&#096;");
}

const starValue = document.querySelector<HTMLElement>("#star-value");

function formatStars(count: number) {
  if (count >= 1000) {
    const thousands = count / 1000;
    return `${thousands.toFixed(thousands >= 10 ? 0 : 1).replace(/\.0$/, "")}k`;
  }
  return String(count);
}

async function loadStars() {
  if (!starValue) return;
  try {
    const response = await fetch("https://api.github.com/repos/standardagents/composer-api", {
      headers: { Accept: "application/vnd.github+json" }
    });
    if (!response.ok) throw new Error(`GitHub responded ${response.status}`);
    const data = (await response.json()) as { stargazers_count?: number };
    if (typeof data.stargazers_count !== "number") throw new Error("Missing star count");
    starValue.textContent = formatStars(data.stargazers_count);
  } catch {
    starValue.textContent = "Stars";
  }
}

void loadStars();

function iconToSvg(icon: IconNode, attrs: Record<string, string | number>) {
  const attrText = Object.entries({
    xmlns: "http://www.w3.org/2000/svg",
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    "stroke-width": 2,
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
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
