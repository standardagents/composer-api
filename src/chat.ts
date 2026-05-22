import { escapeAttr, escapeHtml, highlightJson, icon } from "./ui";
import { assistantDisplayContent, sanitizeAssistantContent } from "./chat-sanitize";
import { renderMarkdown } from "./markdown";

/* ============================================================ types */

type Role = "user" | "assistant";
type ApiMode = "chat" | "responses";

interface ChatMessage {
  role: Role;
  content: string;
  images?: ChatImage[];
}

interface ChatImage {
  id: string;
  name: string;
  dataUrl: string;
  mimeType: string;
  width: number;
  height: number;
  size: number;
}

interface Session {
  id: string;
  title: string;
  messages: ChatMessage[];
  createdAt: number;
  updatedAt: number;
}

interface PersistedState {
  sessions: Session[];
  activeId: string | null;
  model: string;
  mode: ApiMode;
  inspectorOpen: boolean;
}

const MODELS = [
  { id: "default", label: "Auto" },
  { id: "composer-2.5", label: "composer-2.5" },
  { id: "composer-2.5-fast", label: "composer-2.5-fast" },
  { id: "composer-2", label: "composer-2" },
  { id: "composer-latest", label: "composer-latest" },
  { id: "gpt-5.3-codex", label: "gpt-5.3-codex" },
  { id: "gpt-5.2-codex", label: "gpt-5.2-codex" },
  { id: "gpt-5.1-codex-max", label: "gpt-5.1-codex-max" },
  { id: "gpt-5.1-codex-mini", label: "gpt-5.1-codex-mini" },
  { id: "gpt-5.2", label: "gpt-5.2" },
  { id: "gpt-5.1", label: "gpt-5.1" },
  { id: "gpt-5-mini", label: "gpt-5-mini" },
  { id: "gemini-3.1-pro", label: "gemini-3.1-pro" },
  { id: "gemini-3.5-flash", label: "gemini-3.5-flash" },
  { id: "gemini-3-flash", label: "gemini-3-flash" },
  { id: "gemini-2.5-flash", label: "gemini-2.5-flash" },
  { id: "grok-build-0.1", label: "grok-build-0.1" },
  { id: "grok-4.3", label: "grok-4.3" },
  { id: "kimi-k2.5", label: "kimi-k2.5" }
];

const STATE_KEY = "cursor-chat.state.v1";
const REMEMBERED_KEY = "cursor-chat.apiKey";
const LOCAL_DEV_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const LOCAL_DEV_API_ORIGIN = "https://cursor-api.standardagents.ai";
const MAX_ATTACHMENTS = 4;
const IMAGE_MAX_DIMENSION = 1024;
const IMAGE_TARGET_BYTES = 900 * 1024;
const IMAGE_OUTPUT_TYPE = "image/jpeg";
const CHAT_IMAGE_MAX_WIDTH = 260;
const CHAT_IMAGE_MAX_HEIGHT = 180;
const MOBILE_INSPECTOR_QUERY = "(max-width: 900px)";

/* ============================================================ state */

// The Cursor API key lives in memory only, unless the user opts in to
// persisting it via the modal's "remember" checkbox.
let apiKey = "";

let state: PersistedState = loadState();

function loadState(): PersistedState {
  const fallback: PersistedState = {
    sessions: [],
    activeId: null,
    model: "composer-2.5",
    mode: "chat",
    inspectorOpen: defaultInspectorOpen()
  };
  try {
    const raw = localStorage.getItem(STATE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<PersistedState>;
    return {
      sessions: Array.isArray(parsed.sessions) ? (parsed.sessions as Session[]) : [],
      activeId: typeof parsed.activeId === "string" ? parsed.activeId : null,
      model: typeof parsed.model === "string" ? parsed.model : "composer-2.5",
      mode: parsed.mode === "responses" ? "responses" : "chat",
      inspectorOpen: defaultInspectorOpen() && parsed.inspectorOpen !== false
    };
  } catch {
    return fallback;
  }
}

function defaultInspectorOpen(): boolean {
  return !window.matchMedia(MOBILE_INSPECTOR_QUERY).matches;
}

function saveState(): void {
  try {
    localStorage.setItem(STATE_KEY, JSON.stringify(state));
  } catch {
    /* storage unavailable - keep running from memory */
  }
}

function uid(prefix: string): string {
  return `${prefix}_${Math.random().toString(36).slice(2, 10)}${Date.now().toString(36)}`;
}

function activeSession(): Session | null {
  return state.sessions.find((session) => session.id === state.activeId) ?? null;
}

/* ============================================================ mount */

let busy = false;
let pendingImages: ChatImage[] = [];
let inspectorTouched = false;
let responsiveInspectorBound = false;

export function mountChat(root: HTMLElement): void {
  cleanStoredSessions();
  root.innerHTML = template();
  cacheRefs(root);
  bindEvents();
  bindResponsiveInspector();

  const remembered = (() => {
    try {
      return localStorage.getItem(REMEMBERED_KEY) || "";
    } catch {
      return "";
    }
  })();
  if (remembered) apiKey = remembered;

  renderSessions();
  renderTranscript();
  renderInspector();
  syncControls();
  syncResponsiveInspector();

  if (!apiKey) openKeyModal();
  refs.composer.focus();
}

/* ============================================================ template */

function template(): string {
  return `
  <div class="chat-app" data-inspector="${state.inspectorOpen ? "open" : "closed"}">
    <aside class="chat-sidebar" id="chat-sidebar">
      <div class="chat-sidebar-head">
        <a class="chat-brand" href="/">
          ${icon("ArrowRight", { width: 15, height: 15, class: "chat-brand-back" })}
          <img src="/cursor-logo.svg" alt="" width="18" height="18" />
          <span>Cursor Chat</span>
        </a>
        <button class="btn-new" id="new-chat" type="button">
          ${icon("Plus", { width: 16, height: 16 })}
          <span>New chat</span>
        </button>
      </div>
      <nav class="session-list" id="session-list" aria-label="Chat sessions"></nav>
      <div class="chat-sidebar-foot">
        <button class="key-status" id="key-button" type="button">
          ${icon("KeyRound", { width: 15, height: 15 })}
          <span id="key-status-label">Set Cursor key</span>
        </button>
      </div>
    </aside>

    <main class="chat-main">
      <header class="chat-topbar">
        <button class="icon-button mobile-only" id="sidebar-toggle" type="button" aria-label="Toggle sessions">
          ${icon("MessageSquarePlus", { width: 17, height: 17 })}
        </button>
        <h1 class="chat-title" id="chat-title">New chat</h1>
        <div class="chat-controls">
          <label class="control">
            <span class="control-label">Model</span>
            <span class="select-wrap">
              <select id="model-select">
                ${MODELS.map((m) => `<option value="${m.id}">${escapeHtml(m.label)}</option>`).join("")}
              </select>
              ${icon("ChevronDown", { width: 14, height: 14, class: "select-caret" })}
            </span>
          </label>
          <div class="control">
            <span class="control-label">API</span>
            <div class="mode-switch" id="mode-switch" role="tablist" aria-label="API mode">
              <button class="mode-option" data-mode="chat" role="tab" type="button">Chat Completions</button>
              <button class="mode-option" data-mode="responses" role="tab" type="button">Responses API</button>
            </div>
          </div>
          <button class="icon-button" id="inspector-toggle" type="button" aria-label="Toggle request panel">
            ${icon("Code2", { width: 17, height: 17 })}
          </button>
        </div>
      </header>

      <div class="chat-body">
        <section class="chat-thread">
          <div class="chat-transcript" id="transcript" aria-live="polite"></div>
          <div class="chat-error" id="chat-error" hidden>
            <span class="chat-error-icon">${icon("TriangleAlert", { width: 16, height: 16 })}</span>
            <span id="chat-error-text"></span>
            <button class="chat-error-close" id="chat-error-close" type="button" aria-label="Dismiss error">
              ${icon("X", { width: 14, height: 14 })}
            </button>
          </div>
          <form class="chat-composer" id="chat-form">
            <div class="attachment-tray" id="attachment-tray" hidden></div>
            <div class="composer-row">
              <button class="attach-btn" id="attach-image" type="button" aria-label="Attach images">
                ${icon("ImagePlus", { width: 18, height: 18 })}
              </button>
              <input id="image-input" type="file" accept="image/*" multiple hidden />
              <textarea
                id="composer"
                rows="1"
                placeholder="Message Cursor Chat..."
                aria-label="Message"
              ></textarea>
              <button class="send-btn" id="send" type="submit" aria-label="Send message">
                ${icon("SendHorizontal", { width: 18, height: 18, class: "send-icon" })}
                ${icon("Loader2", { width: 18, height: 18, class: "send-spinner spin" })}
              </button>
            </div>
          </form>
        </section>

        <aside class="chat-inspector" id="inspector" aria-label="Request preview">
          <div class="inspector-head">
            <span class="inspector-title">${icon("Code2", { width: 14, height: 14 })} Request</span>
            <code class="inspector-route" id="inspector-route"></code>
          </div>
          <pre class="inspector-body"><code id="request-json"></code></pre>
          <p class="inspector-note" id="inspector-note"></p>
        </aside>
      </div>
    </main>

    <div class="modal-backdrop" id="key-modal" hidden>
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="key-modal-title">
        <div class="modal-icon">${icon("KeyRound", { width: 22, height: 22 })}</div>
        <h2 id="key-modal-title">Add your Cursor API key</h2>
        <p class="modal-text">
          Cursor Chat talks to your Cursor account directly. Get a key from
          <a href="https://cursor.com/dashboard" target="_blank" rel="noreferrer">cursor.com/dashboard</a>
          &rarr; Integrations &rarr; API Keys.
        </p>
        <form id="key-form" class="modal-form" novalidate>
          <label class="modal-field">
            <span>Cursor API key</span>
            <input id="key-input" type="password" autocomplete="off" spellcheck="false"
              placeholder="crsr_..." />
          </label>
          <label class="modal-check">
            <input id="key-remember" type="checkbox" />
            <span>Remember in this browser</span>
          </label>
          <p class="modal-error" id="key-error" hidden></p>
          <div class="modal-actions">
            <button class="btn btn-primary" type="submit">Start chatting</button>
          </div>
        </form>
      </div>
    </div>
  </div>`;
}

/* ============================================================ refs */

interface Refs {
  app: HTMLElement;
  sessionList: HTMLElement;
  transcript: HTMLElement;
  title: HTMLElement;
  composer: HTMLTextAreaElement;
  form: HTMLFormElement;
  send: HTMLButtonElement;
  attachImage: HTMLButtonElement;
  imageInput: HTMLInputElement;
  attachmentTray: HTMLElement;
  modelSelect: HTMLSelectElement;
  modeSwitch: HTMLElement;
  inspector: HTMLElement;
  requestJson: HTMLElement;
  inspectorRoute: HTMLElement;
  inspectorNote: HTMLElement;
  keyButton: HTMLButtonElement;
  keyStatusLabel: HTMLElement;
  keyModal: HTMLElement;
  keyForm: HTMLFormElement;
  keyInput: HTMLInputElement;
  keyRemember: HTMLInputElement;
  keyError: HTMLElement;
  error: HTMLElement;
  errorText: HTMLElement;
}

const refs = {} as Refs;

function cacheRefs(root: HTMLElement): void {
  const get = <T = HTMLElement>(id: string): T => root.querySelector(`#${id}`)! as unknown as T;
  refs.app = root.querySelector<HTMLElement>(".chat-app")!;
  refs.sessionList = get("session-list");
  refs.transcript = get("transcript");
  refs.title = get("chat-title");
  refs.composer = get<HTMLTextAreaElement>("composer");
  refs.form = get<HTMLFormElement>("chat-form");
  refs.send = get<HTMLButtonElement>("send");
  refs.attachImage = get<HTMLButtonElement>("attach-image");
  refs.imageInput = get<HTMLInputElement>("image-input");
  refs.attachmentTray = get("attachment-tray");
  refs.modelSelect = get<HTMLSelectElement>("model-select");
  refs.modeSwitch = get("mode-switch");
  refs.inspector = get("inspector");
  refs.requestJson = get("request-json");
  refs.inspectorRoute = get("inspector-route");
  refs.inspectorNote = get("inspector-note");
  refs.keyButton = get<HTMLButtonElement>("key-button");
  refs.keyStatusLabel = get("key-status-label");
  refs.keyModal = get("key-modal");
  refs.keyForm = get<HTMLFormElement>("key-form");
  refs.keyInput = get<HTMLInputElement>("key-input");
  refs.keyRemember = get<HTMLInputElement>("key-remember");
  refs.keyError = get("key-error");
  refs.error = get("chat-error");
  refs.errorText = get("chat-error-text");
}

/* ============================================================ events */

function bindEvents(): void {
  refs.form.addEventListener("submit", (event) => {
    event.preventDefault();
    void send();
  });

  refs.composer.addEventListener("input", () => {
    autoGrow();
    renderInspector();
  });
  refs.composer.addEventListener("paste", (event) => {
    const files = [...(event.clipboardData?.files ?? [])].filter((file) => file.type.startsWith("image/"));
    if (!files.length) return;
    event.preventDefault();
    void addImageFiles(files);
  });
  refs.composer.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      refs.form.requestSubmit();
    }
  });
  refs.form.addEventListener("dragover", (event) => {
    if ([...(event.dataTransfer?.items ?? [])].some((item) => item.type.startsWith("image/"))) {
      event.preventDefault();
      refs.form.classList.add("is-dragging");
    }
  });
  refs.form.addEventListener("dragleave", () => refs.form.classList.remove("is-dragging"));
  refs.form.addEventListener("drop", (event) => {
    const files = [...(event.dataTransfer?.files ?? [])].filter((file) => file.type.startsWith("image/"));
    if (!files.length) return;
    event.preventDefault();
    refs.form.classList.remove("is-dragging");
    void addImageFiles(files);
  });

  refs.attachImage.addEventListener("click", () => refs.imageInput.click());
  refs.imageInput.addEventListener("change", () => {
    void addImageFiles([...(refs.imageInput.files ?? [])]);
    refs.imageInput.value = "";
  });

  document.getElementById("new-chat")?.addEventListener("click", () => {
    state.activeId = null;
    pendingImages = [];
    saveState();
    renderSessions();
    renderTranscript();
    renderInspector();
    renderPendingImages();
    refs.composer.focus();
  });

  refs.modelSelect.addEventListener("change", () => {
    state.model = refs.modelSelect.value;
    saveState();
    renderInspector();
  });

  refs.modeSwitch.addEventListener("click", (event) => {
    const button = (event.target as HTMLElement).closest<HTMLButtonElement>("[data-mode]");
    if (!button) return;
    state.mode = button.dataset.mode === "responses" ? "responses" : "chat";
    saveState();
    syncControls();
    renderInspector();
  });

  document.getElementById("inspector-toggle")?.addEventListener("click", () => {
    inspectorTouched = true;
    state.inspectorOpen = !state.inspectorOpen;
    refs.app.dataset.inspector = state.inspectorOpen ? "open" : "closed";
    saveState();
  });

  document.getElementById("sidebar-toggle")?.addEventListener("click", () => {
    refs.app.classList.toggle("sidebar-open");
  });

  document.getElementById("chat-error-close")?.addEventListener("click", () => clearError());

  refs.keyButton.addEventListener("click", () => openKeyModal());
  refs.keyForm.addEventListener("submit", (event) => {
    event.preventDefault();
    submitKey();
  });
}

function bindResponsiveInspector(): void {
  if (responsiveInspectorBound) return;
  responsiveInspectorBound = true;
  window.matchMedia(MOBILE_INSPECTOR_QUERY).addEventListener("change", () => syncResponsiveInspector());
}

function syncResponsiveInspector(): void {
  if (inspectorTouched || !window.matchMedia(MOBILE_INSPECTOR_QUERY).matches || !state.inspectorOpen) return;
  state.inspectorOpen = false;
  refs.app.dataset.inspector = "closed";
  saveState();
}

/* ============================================================ rendering */

function syncControls(): void {
  refs.modelSelect.value = state.model;
  for (const button of refs.modeSwitch.querySelectorAll<HTMLButtonElement>("[data-mode]")) {
    const active = button.dataset.mode === state.mode;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-selected", active ? "true" : "false");
  }
  refs.app.dataset.inspector = state.inspectorOpen ? "open" : "closed";
  refs.keyStatusLabel.textContent = apiKey ? "Cursor key set" : "Set Cursor key";
  refs.keyButton.classList.toggle("is-set", Boolean(apiKey));
}

function renderSessions(): void {
  if (!state.sessions.length) {
    refs.sessionList.innerHTML = `<p class="session-empty">No conversations yet.</p>`;
    refs.title.textContent = "New chat";
    return;
  }
  const ordered = [...state.sessions].sort((a, b) => b.updatedAt - a.updatedAt);
  refs.sessionList.innerHTML = ordered
    .map((session) => {
      const active = session.id === state.activeId;
      return `
      <div class="session-row ${active ? "is-active" : ""}" data-id="${session.id}">
        <button class="session-open" type="button" data-action="open" data-id="${session.id}">
          ${icon("MessageSquarePlus", { width: 14, height: 14 })}
          <span class="session-name">${escapeHtml(session.title)}</span>
        </button>
        <span class="session-tools">
          <button class="session-tool" type="button" data-action="rename" data-id="${session.id}" aria-label="Rename">
            ${icon("Pencil", { width: 13, height: 13 })}
          </button>
          <button class="session-tool" type="button" data-action="delete" data-id="${session.id}" aria-label="Delete">
            ${icon("Trash2", { width: 13, height: 13 })}
          </button>
        </span>
      </div>`;
    })
    .join("");

  for (const button of refs.sessionList.querySelectorAll<HTMLButtonElement>("[data-action]")) {
    button.addEventListener("click", () => {
      const id = button.dataset.id || "";
      const action = button.dataset.action;
      if (action === "open") openSession(id);
      else if (action === "rename") renameSession(id);
      else if (action === "delete") deleteSession(id);
    });
  }

  const session = activeSession();
  refs.title.textContent = session ? session.title : "New chat";
}

function openSession(id: string): void {
  if (busy) return;
  state.activeId = id;
  saveState();
  refs.app.classList.remove("sidebar-open");
  renderSessions();
  renderTranscript();
  renderInspector();
}

function renameSession(id: string): void {
  const session = state.sessions.find((s) => s.id === id);
  if (!session) return;
  const next = window.prompt("Rename conversation", session.title);
  if (next === null) return;
  const trimmed = next.trim();
  if (trimmed) {
    session.title = trimmed.slice(0, 80);
    session.updatedAt = Date.now();
    saveState();
    renderSessions();
  }
}

function deleteSession(id: string): void {
  const session = state.sessions.find((s) => s.id === id);
  if (!session) return;
  if (!window.confirm(`Delete "${session.title}"?`)) return;
  state.sessions = state.sessions.filter((s) => s.id !== id);
  if (state.activeId === id) state.activeId = null;
  saveState();
  renderSessions();
  renderTranscript();
  renderInspector();
}

function renderTranscript(streaming?: HTMLElement): void {
  const session = activeSession();
  const messages = session?.messages ?? [];
  if (!messages.length && !streaming) {
    refs.transcript.innerHTML = `
      <div class="transcript-empty">
        <span class="transcript-empty-mark">${icon("Sparkles", { width: 26, height: 26 })}</span>
        <h2>Cursor Chat</h2>
        <p>Streaming chat against Cursor Composer through standard OpenAI-style endpoints.</p>
      </div>`;
    return;
  }
  refs.transcript.innerHTML = "";
  for (const message of messages) {
    refs.transcript.appendChild(messageNode(message.role, message.content, message.images));
  }
  if (streaming) refs.transcript.appendChild(streaming);
  refs.transcript.scrollTop = refs.transcript.scrollHeight;
}

function messageNode(role: Role, content: string, images: ChatImage[] = []): HTMLElement {
  const node = document.createElement("article");
  node.className = `chat-msg chat-msg-${role}`;
  node.innerHTML = `
    <span class="chat-msg-avatar">${icon(role === "user" ? "User" : "Sparkles", { width: 15, height: 15 })}</span>
    <div class="chat-msg-bubble"></div>`;
  const bubble = node.querySelector<HTMLElement>(".chat-msg-bubble")!;
  if (role === "assistant") {
    bubble.innerHTML = renderAssistantContent(content);
  } else {
    bubble.innerHTML = renderUserContent(content, images);
  }
  return node;
}

function renderUserContent(content: string, images: ChatImage[]): string {
  const imageHtml = images.length
    ? `<div class="chat-image-grid">${images.map((image) => userImageHtml(image)).join("")}</div>`
    : "";
  const textHtml = content ? `<p>${escapeHtml(content)}</p>` : "";
  return `${imageHtml}${textHtml}`;
}

function userImageHtml(image: ChatImage): string {
  const src = image.dataUrl.startsWith("data:image/") ? image.dataUrl : "";
  const style = imagePreviewStyle(image, CHAT_IMAGE_MAX_WIDTH, CHAT_IMAGE_MAX_HEIGHT);
  return `
    <figure class="chat-image" style="${style}">
      <span class="chat-image-frame">
        <img src="${escapeAttr(src)}" alt="${escapeAttr(image.name || "Attached image")}" />
      </span>
      <figcaption>${escapeHtml(image.name || "Image")} · ${image.width}×${image.height}</figcaption>
    </figure>`;
}

function renderAssistantContent(content: string): string {
  const cleaned = assistantDisplayContent(content);
  if (!cleaned) return "";
  return renderMarkdown(cleaned, { headingIds: false }).html;
}

/* ============================================================ request preview */

function buildRequestBody(draft?: string, images: ChatImage[] = []): Record<string, unknown> {
  const session = activeSession();
  const history = sanitizeHistory(session?.messages ?? []);
  if (draft || images.length) history.push({ role: "user", content: draft || "", ...(images.length ? { images } : {}) });

  if (state.mode === "responses") {
    return {
      model: state.model,
      input: history.map(responseMessageForApi),
      stream: true
    };
  }
  return {
    model: state.model,
    messages: history.map(chatMessageForApi),
    stream: true
  };
}

function chatMessageForApi(message: ChatMessage): Record<string, unknown> {
  const images = message.images ?? [];
  if (!images.length) return { role: message.role, content: message.content };
  const content: Array<Record<string, unknown>> = [];
  if (message.content) content.push({ type: "text", text: message.content });
  for (const image of images) {
    content.push({
      type: "image_url",
      image_url: {
        url: image.dataUrl,
        detail: "auto",
        width: image.width,
        height: image.height
      }
    });
  }
  return { role: message.role, content };
}

function responseMessageForApi(message: ChatMessage): Record<string, unknown> {
  const images = message.images ?? [];
  if (!images.length) return { role: message.role, content: message.content };
  const content: Array<Record<string, unknown>> = [];
  if (message.content) content.push({ type: "input_text", text: message.content });
  for (const image of images) {
    content.push({
      type: "input_image",
      image_url: {
        url: image.dataUrl,
        detail: "auto",
        width: image.width,
        height: image.height
      }
    });
  }
  return { role: message.role, content };
}

function endpointFor(mode: ApiMode): string {
  const origin = LOCAL_DEV_HOSTS.has(window.location.hostname) ? LOCAL_DEV_API_ORIGIN : "";
  return mode === "responses" ? `${origin}/v1/responses` : `${origin}/v1/chat/completions`;
}

function renderInspector(): void {
  const draft = refs.composer.value.trim();
  const body = buildRequestBody(draft || undefined, pendingImages);
  refs.requestJson.innerHTML = highlightJson(JSON.stringify(redactPreviewImages(body), null, 2));
  refs.inspectorRoute.textContent = `POST ${endpointFor(state.mode)}`;
  refs.inspectorNote.textContent =
    state.mode === "responses"
      ? "Responses API — payload uses `input`; streamed as response.output_text.delta events. Images are resized before sending."
      : "Chat Completions — payload uses `messages`; streamed as chat.completion.chunk events. Images are resized before sending.";
}

function redactPreviewImages(value: unknown): unknown {
  if (typeof value === "string" && value.startsWith("data:image/")) {
    const approxBytes = Math.round((value.length * 3) / 4);
    return `${value.slice(0, value.indexOf(",") + 1)}<${formatBytes(approxBytes)} base64 image>`;
  }
  if (Array.isArray(value)) return value.map(redactPreviewImages);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, redactPreviewImages(item)]));
  }
  return value;
}

/* ============================================================ sending */

function sanitizeHistory(history: ChatMessage[]): ChatMessage[] {
  const cleaned: ChatMessage[] = [];
  for (const message of history) {
    if (message.role !== "assistant") {
      const images = sanitizeImages(message.images);
      cleaned.push({ role: message.role, content: message.content, ...(images.length ? { images } : {}) });
      continue;
    }
    const content = sanitizeAssistantContent(message.content);
    if (content) cleaned.push({ role: "assistant", content });
  }
  return cleaned;
}

function sanitizeImages(images: unknown): ChatImage[] {
  if (!Array.isArray(images)) return [];
  return images
    .filter((image): image is ChatImage => {
      if (!image || typeof image !== "object") return false;
      const item = image as Partial<ChatImage>;
      return (
        typeof item.id === "string" &&
        typeof item.name === "string" &&
        typeof item.dataUrl === "string" &&
        item.dataUrl.startsWith("data:image/") &&
        typeof item.mimeType === "string" &&
        typeof item.width === "number" &&
        typeof item.height === "number" &&
        typeof item.size === "number"
      );
    })
    .slice(0, MAX_ATTACHMENTS);
}

function cleanStoredSessions(): void {
  let changed = false;
  for (const session of state.sessions) {
    const cleaned = sanitizeHistory(session.messages);
    if (
      cleaned.length !== session.messages.length ||
      cleaned.some(
        (message, index) =>
          message.content !== session.messages[index]?.content ||
          (message.images?.length ?? 0) !== (session.messages[index]?.images?.length ?? 0)
      )
    ) {
      session.messages = cleaned;
      changed = true;
    }
  }
  if (changed) saveState();
}

function ensureSession(firstPrompt: string): Session {
  let session = activeSession();
  if (!session) {
    session = {
      id: uid("sess"),
      title: firstPrompt.slice(0, 48).trim() || "New chat",
      messages: [],
      createdAt: Date.now(),
      updatedAt: Date.now()
    };
    state.sessions.push(session);
    state.activeId = session.id;
  }
  return session;
}

async function send(): Promise<void> {
  if (busy) return;
  const prompt = refs.composer.value.trim();
  const images = pendingImages;
  if (!prompt && !images.length) return;
  if (!apiKey) {
    openKeyModal();
    return;
  }

  clearError();
  const session = ensureSession(prompt || images[0]?.name || "Image");
  session.messages.push({ role: "user", content: prompt, ...(images.length ? { images } : {}) });
  session.updatedAt = Date.now();
  if (session.messages.length === 1) session.title = (prompt || images[0]?.name || "Image").slice(0, 48).trim() || "New chat";
  saveState();

  refs.composer.value = "";
  pendingImages = [];
  renderPendingImages();
  autoGrow();
  setBusy(true);
  renderSessions();
  renderTranscript();
  renderInspector();

  const pending = messageNode("assistant", "");
  pending.classList.add("is-streaming");
  const bubble = pending.querySelector<HTMLElement>(".chat-msg-bubble")!;
  renderTranscript(pending);

  const mode = state.mode;
  let received = "";
  const requestBody = buildRequestBody();

  try {
    try {
      const response = await sendRequest(mode, requestBody);
      if (!response.body) throw new Error("Request failed before the stream started.");
      const stream = mode === "responses" ? readResponseDeltas(response.body) : readChatDeltas(response.body);
      for await (const delta of stream) {
        received += delta;
        bubble.innerHTML = renderAssistantContent(received);
        refs.transcript.scrollTop = refs.transcript.scrollHeight;
      }
    } catch (error) {
      if (received || !isStreamLoadFailure(error)) throw error;
      received = await sendBufferedRetry(mode, requestBody);
      bubble.innerHTML = renderAssistantContent(received);
      refs.transcript.scrollTop = refs.transcript.scrollHeight;
    }

    const answer = sanitizeAssistantContent(received);
    if (!answer) throw new Error(`${state.model} returned an empty response.`);
    session.messages.push({ role: "assistant", content: answer });
    session.updatedAt = Date.now();
    saveState();
    pending.classList.remove("is-streaming");
    renderTranscript();
  } catch (error) {
    // Errors are surfaced in a banner, never persisted as assistant content.
    pending.remove();
    renderTranscript();
    showError(error instanceof Error ? error.message : "Unexpected error.");
  } finally {
    setBusy(false);
    renderInspector();
    refs.composer.focus();
  }
}

async function sendRequest(mode: ApiMode, body: Record<string, unknown>): Promise<Response> {
  const response = await fetch(endpointFor(mode), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok) throw await responseError(response);
  return response;
}

async function sendBufferedRetry(mode: ApiMode, body: Record<string, unknown>): Promise<string> {
  const response = await sendRequest(mode, { ...body, stream: false });
  const payload = (await response.json()) as Record<string, unknown>;
  const text = mode === "responses" ? bufferedResponseText(payload) : bufferedChatText(payload);
  if (!text) throw new Error("The retry completed without text.");
  return text;
}

async function responseError(response: Response): Promise<Error> {
  const payload = (await response.json().catch(() => ({}))) as { error?: { message?: string } };
  return new Error(payload.error?.message || `Request failed (${response.status}).`);
}

function isStreamLoadFailure(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return /load failed|networkerror|failed to fetch|network request failed/i.test(error.message);
}

function bufferedChatText(payload: Record<string, unknown>): string {
  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const first = choices[0] as { message?: { content?: unknown } } | undefined;
  return typeof first?.message?.content === "string" ? first.message.content : "";
}

function bufferedResponseText(payload: Record<string, unknown>): string {
  if (typeof payload.output_text === "string") return payload.output_text;
  const output = Array.isArray(payload.output) ? payload.output : [];
  const parts: string[] = [];
  for (const item of output as Array<{ content?: unknown }>) {
    const content = Array.isArray(item.content) ? item.content : [];
    for (const part of content as Array<{ text?: unknown }>) {
      if (typeof part.text === "string") parts.push(part.text);
    }
  }
  return parts.join("");
}

function setBusy(value: boolean): void {
  busy = value;
  refs.send.disabled = value;
  refs.composer.disabled = value;
  refs.attachImage.disabled = value;
  refs.imageInput.disabled = value;
  refs.app.classList.toggle("is-busy", value);
}

function showError(message: string): void {
  refs.errorText.textContent = message;
  refs.error.hidden = false;
}

function clearError(): void {
  refs.error.hidden = true;
  refs.errorText.textContent = "";
}

function autoGrow(): void {
  refs.composer.style.height = "auto";
  refs.composer.style.height = `${Math.min(refs.composer.scrollHeight, 200)}px`;
}

/* ============================================================ image input */

async function addImageFiles(files: File[]): Promise<void> {
  clearError();
  const imageFiles = files.filter((file) => file.type.startsWith("image/"));
  if (!imageFiles.length) return;
  const slots = MAX_ATTACHMENTS - pendingImages.length;
  if (slots <= 0) {
    showError(`Attach up to ${MAX_ATTACHMENTS} images at a time.`);
    return;
  }
  const selected = imageFiles.slice(0, slots);
  try {
    const resized = await Promise.all(selected.map(resizeImageFile));
    pendingImages = [...pendingImages, ...resized];
    renderPendingImages();
    renderInspector();
  } catch (error) {
    showError(error instanceof Error ? error.message : "Could not process that image.");
  }
  if (imageFiles.length > selected.length) {
    showError(`Only ${MAX_ATTACHMENTS} images can be attached at once.`);
  }
}

function renderPendingImages(): void {
  refs.attachmentTray.hidden = pendingImages.length === 0;
  refs.attachmentTray.innerHTML = pendingImages
    .map(
      (image) => `
      <figure class="attachment-chip" data-id="${escapeAttr(image.id)}" style="${imagePreviewStyle(image, 48, 42)}">
        <span class="attachment-thumb">
          <img src="${escapeAttr(image.dataUrl)}" alt="${escapeAttr(image.name)}" />
        </span>
        <figcaption>${escapeHtml(image.name)} <span>${image.width}×${image.height}</span></figcaption>
        <button type="button" aria-label="Remove ${escapeAttr(image.name)}" data-remove-image="${escapeAttr(image.id)}">
          ${icon("X", { width: 13, height: 13 })}
        </button>
      </figure>`
    )
    .join("");
  for (const button of refs.attachmentTray.querySelectorAll<HTMLButtonElement>("[data-remove-image]")) {
    button.addEventListener("click", () => {
      pendingImages = pendingImages.filter((image) => image.id !== button.dataset.removeImage);
      renderPendingImages();
      renderInspector();
      refs.composer.focus();
    });
  }
}

function imagePreviewStyle(image: ChatImage, maxWidth: number, maxHeight: number): string {
  const width = Math.max(1, image.width);
  const height = Math.max(1, image.height);
  const scale = Math.min(1, maxWidth / width, maxHeight / height);
  const previewWidth = Math.max(1, Math.round(width * scale));
  const previewHeight = Math.max(1, Math.round(height * scale));
  return `--image-aspect: ${width} / ${height}; --preview-width: ${previewWidth}px; --preview-height: ${previewHeight}px;`;
}

async function resizeImageFile(file: File): Promise<ChatImage> {
  const { image, dispose } = await loadImage(file);
  try {
    let scale = Math.min(1, IMAGE_MAX_DIMENSION / Math.max(image.naturalWidth, image.naturalHeight));
    let width = Math.max(1, Math.round(image.naturalWidth * scale));
    let height = Math.max(1, Math.round(image.naturalHeight * scale));
    let quality = 0.86;
    let blob = await drawImageToBlob(image, width, height, quality);

    while (blob.size > IMAGE_TARGET_BYTES && quality > 0.5) {
      quality = Math.max(0.5, quality - 0.08);
      blob = await drawImageToBlob(image, width, height, quality);
    }
    while (blob.size > IMAGE_TARGET_BYTES && Math.max(width, height) > 512) {
      scale *= 0.85;
      width = Math.max(1, Math.round(image.naturalWidth * scale));
      height = Math.max(1, Math.round(image.naturalHeight * scale));
      blob = await drawImageToBlob(image, width, height, quality);
    }
    if (blob.size > 1024 * 1024) {
      throw new Error("That image is still over 1MB after resizing. Try a smaller image.");
    }

    return {
      id: uid("img"),
      name: file.name || "image.jpg",
      dataUrl: await blobToDataUrl(blob),
      mimeType: blob.type || IMAGE_OUTPUT_TYPE,
      width,
      height,
      size: blob.size
    };
  } finally {
    dispose();
  }
}

async function loadImage(file: File): Promise<{ image: HTMLImageElement; dispose: () => void }> {
  const url = URL.createObjectURL(file);
  const image = new Image();
  image.src = url;
  const decode = (image as HTMLImageElement & { decode?: () => Promise<void> }).decode;
  if (typeof decode === "function") await decode.call(image);
  else {
    await new Promise<void>((resolve, reject) => {
      image.onload = () => resolve();
      image.onerror = () => reject(new Error("Could not read that image."));
    });
  }
  return { image, dispose: () => URL.revokeObjectURL(url) };
}

async function drawImageToBlob(image: HTMLImageElement, width: number, height: number, quality: number): Promise<Blob> {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("Could not process that image.");
  context.fillStyle = "#ffffff";
  context.fillRect(0, 0, width, height);
  context.drawImage(image, 0, 0, width, height);
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("Could not encode that image."))), IMAGE_OUTPUT_TYPE, quality);
  });
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error("Could not read the resized image."));
    reader.readAsDataURL(blob);
  });
}

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)}KB`;
  return `${bytes}B`;
}

/* ============================================================ SSE parsing */

interface SseFrame {
  event: string;
  data: string;
}

async function* readSseFrames(body: ReadableStream<Uint8Array>): AsyncGenerator<SseFrame> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  const parse = (raw: string): SseFrame | null => {
    let event = "";
    const data: string[] = [];
    for (const line of raw.split(/\r?\n/)) {
      if (line.startsWith(":")) continue;
      if (line.startsWith("event:")) event = line.slice(6).trim();
      else if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
    }
    if (!event && !data.length) return null;
    return { event, data: data.join("\n") };
  };

  const boundary = (text: string): { index: number; length: number } => {
    const lf = text.indexOf("\n\n");
    const crlf = text.indexOf("\r\n\r\n");
    if (lf === -1 && crlf === -1) return { index: -1, length: 0 };
    if (crlf === -1 || (lf !== -1 && lf < crlf)) return { index: lf, length: 2 };
    return { index: crlf, length: 4 };
  };

  for (;;) {
    const { value, done } = await reader.read();
    if (done) {
      buffer += decoder.decode();
      break;
    }
    buffer += decoder.decode(value, { stream: true });
    let edge = boundary(buffer);
    while (edge.index !== -1) {
      const frame = parse(buffer.slice(0, edge.index));
      buffer = buffer.slice(edge.index + edge.length);
      if (frame) yield frame;
      edge = boundary(buffer);
    }
  }
  if (buffer.trim()) {
    const frame = parse(buffer);
    if (frame) yield frame;
  }
}

function errorFromData(data: string, fallback: string): Error {
  if (!data) return new Error(fallback);
  try {
    const parsed = JSON.parse(data) as { error?: { message?: string }; message?: string };
    return new Error(parsed.error?.message || parsed.message || data);
  } catch {
    return new Error(data);
  }
}

/** Chat Completions SSE: `chat.completion.chunk` data frames. */
async function* readChatDeltas(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  for await (const frame of readSseFrames(body)) {
    if (frame.event === "error") throw errorFromData(frame.data, "Cursor stream reported an error.");
    const data = frame.data.trim();
    if (!data || data === "[DONE]") {
      if (data === "[DONE]") return;
      continue;
    }
    let chunk: { choices?: Array<{ delta?: { content?: string } }>; error?: { message?: string } };
    try {
      chunk = JSON.parse(data);
    } catch {
      continue;
    }
    if (chunk.error) throw new Error(chunk.error.message || "Cursor stream reported an error.");
    const content = chunk.choices?.[0]?.delta?.content;
    if (content) yield content;
  }
}

/** Responses API SSE: `response.output_text.delta` / `response.completed` / `error`. */
async function* readResponseDeltas(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  for await (const frame of readSseFrames(body)) {
    if (frame.event === "error") throw errorFromData(frame.data, "Cursor stream reported an error.");
    const data = frame.data.trim();
    if (!data) continue;
    let payload: {
      type?: string;
      delta?: string;
      response?: { error?: { message?: string } | null };
      error?: { message?: string };
    };
    try {
      payload = JSON.parse(data);
    } catch {
      continue;
    }
    const type = payload.type || frame.event;
    if (type === "error" || payload.error) {
      throw new Error(payload.error?.message || "Cursor stream reported an error.");
    }
    if (type === "response.output_text.delta" && typeof payload.delta === "string") {
      yield payload.delta;
    }
    if (type === "response.completed") {
      if (payload.response?.error) throw new Error(payload.response.error.message || "Response failed.");
      return;
    }
    if (type === "response.failed" || type === "response.incomplete") {
      throw new Error(payload.response?.error?.message || "Response did not complete.");
    }
  }
}

/* ============================================================ key modal */

function openKeyModal(): void {
  refs.keyInput.value = apiKey;
  refs.keyError.hidden = true;
  refs.keyModal.hidden = false;
  window.setTimeout(() => refs.keyInput.focus(), 30);
}

function closeKeyModal(): void {
  refs.keyModal.hidden = true;
}

function submitKey(): void {
  const value = refs.keyInput.value.trim();
  if (!value) {
    refs.keyError.textContent = "Enter a Cursor API key to continue.";
    refs.keyError.hidden = false;
    return;
  }
  apiKey = value;
  try {
    if (refs.keyRemember.checked) localStorage.setItem(REMEMBERED_KEY, value);
    else localStorage.removeItem(REMEMBERED_KEY);
  } catch {
    /* storage unavailable - keep key in memory */
  }
  closeKeyModal();
  syncControls();
  refs.composer.focus();
}
