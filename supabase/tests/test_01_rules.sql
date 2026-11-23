-- Testy czystych reguł: punktacja, poziomy, wyniki ligowe.
\set ON_ERROR_STOP 1
do $$
declare r jsonb;
begin
  -- XP: 10 pytań, 10 poprawnych, quiz szybki, trudność 3
  r := public.qv_compute_rewards('quick', 10, 10, 10, 3, true);
  assert (r->>'xp')::int = 50 + 15 + 20, 'quick perfect XP: ' || r::text;
  assert (r->>'lp')::int = 20, 'quick 10q LP';

  -- 5 pytań = 10 LP, 20 pytań = 40 LP
  assert (public.qv_compute_rewards('thematic', 5, 5, 3, 2, true)->>'lp')::int = 10, 'thematic 5q LP';
  assert (public.qv_compute_rewards('thematic', 20, 20, 12, 2, true)->>'lp')::int = 40, 'thematic 20q LP';

  -- Quiz dnia: 25 LP i +25 XP
  r := public.qv_compute_rewards('daily', 10, 10, 7, null, true);
  assert (r->>'lp')::int = 25, 'daily LP';
  assert (r->>'xp')::int = 35 + 15 + 25, 'daily XP: ' || r::text;

  -- Ekspert: +30 XP przy trudności >= 5 i skuteczności >= 50%
  r := public.qv_compute_rewards('thematic', 10, 10, 6, 5, true);
  assert (r->>'xp')::int = 30 + 15 + 30, 'expert XP: ' || r::text;
  r := public.qv_compute_rewards('thematic', 10, 10, 4, 6, true);
  assert (r->>'xp')::int = 20 + 15, 'expert bonus requires 50%: ' || r::text;

  -- Maraton: 10 LP za każde 5 pytań
  assert (public.qv_compute_rewards('marathon', 50, 50, 40, 3, true)->>'lp')::int = 100, 'marathon 50';
  assert (public.qv_compute_rewards('marathon', 100, 23, 20, 3, true)->>'lp')::int = 40, 'marathon partial 23 answered';

  -- Antyfarming: poniżej 40% skuteczności brak LP (XP za poprawne zostaje)
  r := public.qv_compute_rewards('quick', 10, 10, 3, 3, true);
  assert (r->>'lp')::int = 0 and (r->>'lp_blocked_low_accuracy')::boolean, 'low accuracy blocks LP';
  assert (r->>'xp')::int = 15 + 15, 'low accuracy keeps XP';

  -- Nieukończony quiz szybki: brak LP i brak XP za ukończenie
  r := public.qv_compute_rewards('quick', 10, 6, 6, 3, false);
  assert (r->>'lp')::int = 0 and (r->>'xp')::int = 30, 'unfinished quiz';

  -- Powtórki i AI nie dają LP
  assert (public.qv_compute_rewards('review', 10, 10, 10, 3, true)->>'lp')::int = 0, 'review no LP';
  assert (public.qv_compute_rewards('ai', 10, 10, 10, 3, true)->>'lp')::int = 0, 'ai no LP';

  -- Sprint/przetrwanie: 10 LP za 5 poprawnych, maks. 60
  assert (public.qv_compute_rewards('sprint', 40, 22, 17, 3, true)->>'lp')::int = 30, 'sprint LP';
  assert (public.qv_compute_rewards('survival', 100, 50, 49, 3, true)->>'lp')::int = 60, 'survival LP cap';

  -- Poziomy: 151, próg rosnący
  assert public.qv_xp_for_level(1) = 0 and public.qv_xp_for_level(2) = 100 and public.qv_xp_for_level(3) = 220, 'level thresholds';
  assert public.qv_level_for_xp(0) = 1 and public.qv_level_for_xp(99) = 1 and public.qv_level_for_xp(100) = 2, 'level for xp';
  assert public.qv_level_for_xp(10000000) = 151, 'max level 151';
  assert public.qv_title_for_level(1) = 'Nowicjusz' and public.qv_title_for_level(151) = 'Wszechwiedzący', 'titles';
  assert (select count(distinct public.qv_title_for_level(l)) from generate_series(1, 151) l) = 9, '9 titles';

  -- Ligi: dokładnie pięć
  assert (select count(*) from public.leagues) = 5, 'five leagues';
  -- Awans 1–10, utrzymanie 11–23, spadek 24–30
  assert public.qv_league_outcome(2::smallint, 1, 50) = 'promoted';
  assert public.qv_league_outcome(2::smallint, 10, 50) = 'promoted';
  assert public.qv_league_outcome(2::smallint, 11, 50) = 'stayed';
  assert public.qv_league_outcome(2::smallint, 23, 50) = 'stayed';
  assert public.qv_league_outcome(2::smallint, 24, 50) = 'relegated';
  assert public.qv_league_outcome(2::smallint, 30, 0) = 'relegated';
  -- Wyjątki: Brąz nie spada, Legenda nie awansuje
  assert public.qv_league_outcome(1::smallint, 30, 0) = 'stayed', 'bronze never relegates';
  assert public.qv_league_outcome(5::smallint, 1, 999) = 'stayed', 'legend never promotes';
  assert public.qv_league_outcome(5::smallint, 25, 10) = 'relegated', 'legend relegates';
  assert public.qv_league_after(5::smallint, 'promoted') = 5 and public.qv_league_after(1::smallint, 'relegated') = 1;

  raise notice 'test_01_rules: OK';
end $$;
