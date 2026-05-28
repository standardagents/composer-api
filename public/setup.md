# API for Cursor

API for Cursor is now distributed as a local macOS app. The local app starts an OpenAI-compatible server on your machine, stores your Cursor API key locally, and configures agent tools like OpenCode, Codex, VS Code, Cline, Kilo Code, Continue, Aider, and Roo.

Download the latest DMG:

```txt
https://api-for-composer.standardagents.ai/download
```

After installing, open the app, add your Cursor API key, and start the local API.

## Local Endpoints

Default base URL:

```txt
http://127.0.0.1:8787/v1
```

Endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`

## OpenCode

Use the app's OpenCode installer from **Agent Setup**. It writes a local OpenAI-compatible provider that points at your local server.

The model ids are:

- `composer-2.5`
- `composer-2.5-fast`

## Codex

Use the app's Codex installer from **Agent Setup**, or configure a custom OpenAI-compatible provider manually:

```toml
[model_providers.cursor-composer]
name = "Cursor Composer"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "chat"

[profiles.cursor-composer]
model = "composer-2.5"
model_provider = "cursor-composer"
```

## Hosted Endpoint Status

Cursor asked us to take down the hosted API endpoint. The old hosted routes remain online temporarily while the local app is verified, but the production path is the local app.

The local app is safer and more capable: your key stays on your machine, local agent tools can work against your real project folders, and Sparkle auto-updates keep the app current after install.
