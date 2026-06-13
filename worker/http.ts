const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
};

const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers":
    "authorization,content-type,x-api-key,idempotency-key,x-session-affinity,x-opencode-session-id,x-opencode-session",
  "access-control-max-age": "86400",
};

export function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function optionsResponse(): Response {
  return new Response(null, {
    status: 204,
    headers: CORS_HEADERS,
  });
}

export function json(data: unknown, init: ResponseInit = {}): Response {
  return withCors(
    Response.json(data, {
      ...init,
      headers: {
        ...JSON_HEADERS,
        ...init.headers,
      },
    }),
  );
}

export function openAiError(
  message: string,
  status = 400,
  code = "invalid_request_error",
  param?: string,
): Response {
  return json(
    {
      error: {
        message,
        type: code,
        param: param ?? null,
        code,
      },
    },
    { status },
  );
}

export function unauthorized(message = "Missing or invalid API key"): Response {
  return openAiError(message, 401, "unauthorized");
}

export function notFound(): Response {
  return openAiError("Not found", 404, "not_found");
}

export function bearerToken(request: Request): string | undefined {
  const authorization = request.headers.get("authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  if (match) return match[1].trim();
  const apiKey = request.headers.get("x-api-key");
  return apiKey?.trim() || undefined;
}

export function parseJsonBody<T = unknown>(request: Request): Promise<T> {
  const contentType = request.headers.get("content-type") || "";
  if (contentType && !contentType.toLowerCase().includes("application/json")) {
    throw new HttpError("Content-Type must be application/json", 415);
  }
  return request.json() as Promise<T>;
}

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly param?: string;

  constructor(
    message: string,
    status = 400,
    code = "invalid_request_error",
    param?: string,
  ) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.param = param;
  }
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return openAiError(error.message, error.status, error.code, error.param);
  }
  const message = error instanceof Error ? error.message : "Unexpected error";
  return openAiError(message, 500, "internal_error");
}

export function sseResponse(readable: ReadableStream<Uint8Array>): Response {
  return withCors(
    new Response(readable, {
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform",
        connection: "keep-alive",
        "x-accel-buffering": "no",
      },
    }),
  );
}
