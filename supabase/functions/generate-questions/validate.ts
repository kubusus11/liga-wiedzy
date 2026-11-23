// Automatyczne testy jakości pytań generowanych przez AI.
export interface GeneratedQuestion {
  prompt: string;
  answers: string[];
  correct_index: number;
  explanation: string;
  sources: { title: string; url: string }[];
}

export function normalize(s: string): string {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

export function validateGenerated(q: GeneratedQuestion): string | null {
  if (!q.prompt || q.prompt.length < 10 || q.prompt.length > 400) return "prompt_length";
  if (!Array.isArray(q.answers) || q.answers.length !== 4) return "answers_count";
  if (new Set(q.answers.map(normalize)).size !== 4) return "answers_duplicate";
  if (q.answers.some((a) => !a || a.length > 150)) return "answer_length";
  if (!Number.isInteger(q.correct_index) || q.correct_index < 0 || q.correct_index > 3) return "correct_index";
  if (!q.explanation || q.explanation.length < 15) return "explanation";
  if (q.answers.some((a) => /wszystkie (powyższe|odpowiedzi)|żadna z (powyższych|odpowiedzi)/i.test(a))) return "meta_answer";
  return null;
}

