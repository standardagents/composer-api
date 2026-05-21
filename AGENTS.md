# Repository Instructions

- Use Conventional Commits for every commit message: `<type>: <summary>`.
- Keep commit subjects factual and neutral. Prefer wording like `chore: move endpoint configuration to secrets`.
- Do not commit private Cursor backend origins, endpoint paths, or service names. Keep them in Worker secrets or local environment files only.
- Before force-pushing rewritten history, scan all reachable commits for private endpoint strings.
