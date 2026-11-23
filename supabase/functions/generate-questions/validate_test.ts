import { assertEquals } from "jsr:@std/assert@1.0.13";
import { validateGenerated } from "./validate.ts";

const ok = { prompt: "Jaka jest stolica Francji?", answers: ["Paryż", "Lyon", "Nicea", "Lille"], correct_index: 0,
             explanation: "Paryż jest stolicą Francji od wieków.", sources: [] };

Deno.test("akceptuje poprawne pytanie", () => assertEquals(validateGenerated(ok), null));
Deno.test("odrzuca duplikaty odpowiedzi", () =>
  assertEquals(validateGenerated({ ...ok, answers: ["Paryż", "paryż ", "Nicea", "Lille"] }), "answers_duplicate"));
Deno.test("odrzuca złą liczbę odpowiedzi", () =>
  assertEquals(validateGenerated({ ...ok, answers: ["A", "B", "C"] }), "answers_count"));
Deno.test("odrzuca indeks spoza zakresu", () => assertEquals(validateGenerated({ ...ok, correct_index: 4 }), "correct_index"));
Deno.test("odrzuca meta-odpowiedzi", () =>
  assertEquals(validateGenerated({ ...ok, answers: ["Paryż", "Lyon", "Nicea", "Wszystkie powyższe"] }), "meta_answer"));
