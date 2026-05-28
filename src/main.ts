import { hydrateIcons, wireCopyButtons } from "./ui";

const isChatRoute = (): boolean => window.location.pathname.replace(/\/+$/, "") === "/chat";

async function route(): Promise<void> {
  const landing = document.getElementById("landing");
  const chatRoot = document.getElementById("chat-root");
  if (!landing || !chatRoot) return;

  if (isChatRoute()) {
    landing.hidden = true;
    chatRoot.hidden = false;
    document.title = "Cursor Chat - API for Cursor";
    const { mountChat } = await import("./chat");
    mountChat(chatRoot);
    return;
  }

  chatRoot.hidden = true;
  landing.hidden = false;
  document.title = "API for Cursor";
  mountLanding();
}

document.addEventListener("click", (event) => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const anchor = (event.target as HTMLElement | null)?.closest("a");
  if (!anchor) return;
  const href = anchor.getAttribute("href") || "";
  if (href !== "/" && href !== "/chat") return;
  if (anchor.target === "_blank") return;
  event.preventDefault();
  if (window.location.pathname !== href) {
    window.history.pushState({}, "", href);
    void route();
  }
});

window.addEventListener("popstate", () => void route());

let landingReady = false;

function mountLanding(): void {
  hydrateIcons(document);
  wireCopyButtons(document);
  if (landingReady) return;
  landingReady = true;
  bindEndpointModal();
}

function bindEndpointModal(): void {
  const modal = document.querySelector<HTMLElement>("[data-endpoint-modal]");
  const openButtons = document.querySelectorAll<HTMLButtonElement>("[data-endpoint-modal-open]");
  const closeButtons = document.querySelectorAll<HTMLButtonElement>("[data-endpoint-modal-close]");
  if (!modal) return;

  const setOpen = (open: boolean): void => {
    modal.hidden = !open;
    document.body.classList.toggle("modal-open", open);
    if (open) {
      window.setTimeout(() => closeButtons[0]?.focus(), 0);
    }
  };

  for (const button of openButtons) {
    button.addEventListener("click", () => setOpen(true));
  }
  for (const button of closeButtons) {
    button.addEventListener("click", () => setOpen(false));
  }
  modal.addEventListener("click", (event) => {
    if (event.target === modal) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !modal.hidden) setOpen(false);
  });
}

void route();
