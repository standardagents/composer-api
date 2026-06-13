const COMPOSER_MARKER_SOURCE = String.raw`<\/think>|<\s*[|｜]\s*final\s*[|｜]\s*>`;

function lastComposerMarkerEnd(content: string): number {
  let end = 0;
  const pattern = new RegExp(COMPOSER_MARKER_SOURCE, "gi");
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(content))) {
    end = Math.max(end, match.index + match[0].length);
  }
  return end;
}

export function sanitizeAssistantContent(content: string): string {
  const end = lastComposerMarkerEnd(content);
  return content.slice(end).trim();
}

export function assistantDisplayContent(content: string): string {
  const markerEnd = lastComposerMarkerEnd(content);
  if (markerEnd > 0) return content.slice(markerEnd).trim();
  return looksLikeOnlyComposerControl(content) ? "" : content;
}

function looksLikeOnlyComposerControl(content: string): boolean {
  const compact = content
    .trim()
    .replace(/\s+/g, "")
    .replaceAll("｜", "|")
    .toLowerCase();
  if (!compact) return true;
  return "<|final|>".startsWith(compact) || "</think>".startsWith(compact);
}
