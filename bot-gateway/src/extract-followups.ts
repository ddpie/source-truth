/**
 * Extract follow-up question suggestions from the Agent's answer text.
 *
 * The system prompt instructs the Agent to end answers with:
 *   ---
 *   💡 你可能还想问：
 *   - question 1
 *   - question 2
 *
 * We parse these out and return them as strings for the card buttons.
 */

export function extractFollowUps(answer: string): string[] {
  // Find the section after "你可能还想问" (tolerant of formatting variations).
  const marker = answer.indexOf("你可能还想问");
  if (marker === -1) return [];

  const afterMarker = answer.slice(marker);
  // Extract lines starting with "- " or "· " or numbered "1. " etc.
  const lines = afterMarker.split("\n");
  const questions: string[] = [];
  for (const line of lines) {
    const trimmed = line.replace(/^[\s\-·•*\d.]+/, "").trim();
    if (trimmed.length > 4 && trimmed.length < 80 && !trimmed.startsWith("💡")) {
      questions.push(trimmed);
    }
    if (questions.length >= 3) break;
  }
  return questions;
}
