import { Copy, Github, KeyRound, PlugZap, RefreshCw, type IconNode } from "lucide";
import "./styles.css";

type SignupResponse = {
  account: {
    id: string;
    cursorEmail?: string;
    cursorName?: string;
  };
  apiKey: string;
  endpoints: {
    baseUrl: string;
    chatCompletions: string;
    responses: string;
    accountBaseUrl: string;
  };
};

const icons = { Copy, Github, KeyRound, PlugZap, RefreshCw };

for (const icon of document.querySelectorAll<HTMLElement>("[data-lucide]")) {
  const name = icon.dataset.lucide || "";
  const pascal = name
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join("") as keyof typeof icons;
  const Icon = icons[pascal];
  if (Icon) icon.outerHTML = iconToSvg(Icon, { width: 18, height: 18, "aria-hidden": "true" });
}

const form = document.querySelector<HTMLFormElement>("#signup-form");
const dashboard = document.querySelector<HTMLElement>("#dashboard");
const status = document.querySelector<HTMLElement>("#status");
const submit = document.querySelector<HTMLButtonElement>("#submit");

form?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const data = new FormData(form);
  setBusy(true);
  setStatus("");

  try {
    const response = await fetch("/api/signup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: String(data.get("name") || ""),
        email: String(data.get("email") || ""),
        cursorApiKey: String(data.get("cursorKey") || ""),
        joinWaitlist: data.get("waitlist") === "on"
      })
    });
    const payload = (await response.json().catch(() => ({}))) as SignupResponse & { error?: { message?: string } };
    if (!response.ok) {
      throw new Error(payload.error?.message || "Could not connect Cursor");
    }
    renderDashboard(payload);
    form.reset();
    setStatus("Connected. Save the generated key now.", "ok");
  } catch (error) {
    setStatus(error instanceof Error ? error.message : "Unexpected error", "err");
  } finally {
    setBusy(false);
  }
});

function setBusy(busy: boolean) {
  if (!submit) return;
  submit.disabled = busy;
  const label = submit.querySelector("span");
  if (label) label.textContent = busy ? "Connecting" : "Connect";
}

function setStatus(message: string, tone?: "ok" | "err") {
  if (!status) return;
  status.textContent = message;
  status.dataset.tone = tone || "";
}

function renderDashboard(data: SignupResponse) {
  if (!dashboard) return;
  dashboard.classList.remove("is-empty");
  const nodeSnippet = `import OpenAI from "openai";

const client = new OpenAI({
  apiKey: "${data.apiKey}",
  baseURL: "${data.endpoints.accountBaseUrl}"
});

const completion = await client.chat.completions.create({
  model: "composer-2.5",
  messages: [{ role: "user", content: "Write a terse TypeScript debounce." }]
});

console.log(completion.choices[0].message.content);`;

  const responseSnippet = `curl ${data.endpoints.responses} \\
  -H "Authorization: Bearer ${data.apiKey}" \\
  -H "Content-Type: application/json" \\
  -d '{"model":"composer-2.5","input":"Summarize this endpoint."}'`;

  dashboard.innerHTML = `
    <div class="panel-heading dashboard-heading">
      <div>
        <h2>${escapeHtml(data.account.cursorName || data.account.cursorEmail || "Cursor account")}</h2>
        <p>${escapeHtml(data.account.id)}</p>
      </div>
    </div>

    <div class="secret-row">
      <span>API key</span>
      <code>${escapeHtml(data.apiKey)}</code>
      <button class="icon-button" data-copy="${escapeAttr(data.apiKey)}" aria-label="Copy API key">
        ${iconToSvg(Copy, { width: 17, height: 17, "aria-hidden": "true" })}
      </button>
    </div>

    <div class="endpoint-list">
      ${endpointRow("Base URL", data.endpoints.accountBaseUrl)}
      ${endpointRow("Chat Completions", data.endpoints.chatCompletions)}
      ${endpointRow("Responses", data.endpoints.responses)}
    </div>

    <div class="snippet-grid">
      <pre><code>${escapeHtml(nodeSnippet)}</code></pre>
      <pre><code>${escapeHtml(responseSnippet)}</code></pre>
    </div>
  `;

  dashboard.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const value = button.dataset.copy || "";
      await navigator.clipboard.writeText(value);
      button.classList.add("copied");
      window.setTimeout(() => button.classList.remove("copied"), 900);
    });
  });
}

function endpointRow(label: string, value: string) {
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
