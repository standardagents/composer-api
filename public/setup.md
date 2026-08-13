# API for Cursor

API for Cursor starts a local OpenAI-compatible server for Cursor models, including Composer 2.5 and Grok 4.6. Coding agents connect to the local `/v1` base URL and keep using their own project folders, shell tools, and file workflows.

## Local Endpoints

Default base URL:

```txt
http://127.0.0.1:8787/v1
```

Endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`

## Models

Local model ids exposed by the app:

- `composer-2.5`
- `composer-2.5-fast`
- `grok-4.6`
- `grok-4.6-fast`
- `grok-4.5`
- `grok-4.5-fast`

Use any of these ids with Chat Completions or Responses. Hosted Cursor models available through your Cursor account may also appear via the Worker `/v1/models` list.

## OpenCode

Use **Agent Setup** to configure OpenCode with a local OpenAI-compatible provider that points at your running server.

The model ids are:

- `composer-2.5`
- `composer-2.5-fast`
- `grok-4.6`
- `grok-4.6-fast`
- `grok-4.5`
- `grok-4.5-fast`

## Codex

Use **Agent Setup** to configure Codex, or add a custom OpenAI-compatible provider manually:

```toml
[model_providers.cursor-composer]
name = "Cursor Composer"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "chat"

[profiles.cursor-composer]
model = "composer-2.5"
model_provider = "cursor-composer"

[profiles.cursor-grok]
model = "grok-4.6"
model_provider = "cursor-composer"
```

## Other Agents

Any client that supports an OpenAI-compatible base URL can use:

```txt
http://127.0.0.1:8787/v1
```

Use a model id such as `composer-2.5` or `grok-4.6`.
