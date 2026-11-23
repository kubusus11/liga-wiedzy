-- Testy przebiegu gry: start → odpowiedzi → zakończenie, nagrody, misje, powtórki, limity.
\set ON_ERROR_STOP 1

create schema if not exists test;

-- Rozegraj quiz jako gracz; p_correct = ile pierwszych odpowiedzi ma być poprawnych
create or replace function test.play(p_user uuid, p_mode public.quiz_mode, p_cat smallint, p_count int,
                                     p_correct int, p_diff int default null, p_time_ms int default 3000)
returns jsonb language plpgsql as $$
declare
  r jsonb; q jsonb; v_attempt uuid; v_ans uuid; i int := 0; s jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  r := public.start_quiz(p_mode, p_cat, null, p_diff, p_count, case when p_mode = 'sprint' then 60 end);
  v_attempt := (r->>'attempt_id')::uuid;
  -- symulacja realnego czasu gry (zabezpieczenie przed botami mierzy tempo)
  update public.quiz_attempts set started_at = now() - case when p_mode = 'sprint' then interval '50 seconds' else interval '10 minutes' end
    where id = v_attempt;

  -- klient nie może zobaczyć poprawnej odpowiedzi
  assert not (r::text like '%is_correct%'), 'start_quiz leaks is_correct';
  assert not (r::text like '%explanation%'), 'start_quiz leaks explanation';

  for q in select * from jsonb_array_elements(r->'questions') loop
    exit when p_mode in ('survival', 'sprint') and i >= p_count;
    if i < p_correct then
      select id into v_ans from public.answers where question_id = (q->>'id')::uuid and is_correct;
    else
      select id into v_ans from public.answers where question_id = (q->>'id')::uuid and not is_correct limit 1;
    end if;
    s := public.submit_answer(v_attempt, (q->>'id')::uuid, v_ans, p_time_ms);
    assert (s->>'correct')::boolean = (i < p_correct), 'grading mismatch at ' || i;
    i := i + 1;
    exit when (s->>'ends_quiz')::boolean;
  end loop;
  return public.finish_quiz(v_attempt);
end $$;

create or replace function test.new_user(p_name text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users(email, raw_user_meta_data) values (p_name || '@test.local', jsonb_build_object('username', p_name))
    returning id into v;
  return v;
end $$;

do $$
declare
  u uuid := test.new_user('ania_test');
  r jsonb; r2 jsonb;
  v_xp bigint; v_attempt uuid;
  v_hist smallint := (select id from public.categories where slug = 'historia');
begin
  assert (select username from public.profiles where id = u) = 'ania_test', 'profile created by trigger';

  -- Szybki quiz 10/10
  r := test.play(u, 'quick', v_hist, 10, 10, 2);
  assert (r->>'xp')::int >= 85, 'quick perfect XP ' || r::text;
  assert (r->>'lp')::int = 20, 'quick LP ' || r::text;
  assert (r->'league'->>'week_lp')::int = 20, 'league LP updated live';
  assert jsonb_array_length(r->'achievements_unlocked') >= 1, 'first quiz achievement';
  assert (select count(*) from public.user_achievements where user_id = u) >= 2, 'first_quiz + perfect_1';
  -- karta za komplet poprawnych
  assert r->'card' is not null and r->'card' <> 'null'::jsonb, 'card for perfect quiz ' || r::text;
  -- misja dzienna „Lekcja historii” wykonana → +20 XP
  assert exists (select 1 from jsonb_array_elements(r->'missions_completed') m where m->>'code' = 'd_history'), 'history mission ' || r::text;

  -- Idempotencja: ponowne zakończenie nie dodaje punktów
  v_attempt := (r->>'attempt_id')::uuid;
  select xp into v_xp from public.users where id = u;
  r2 := public.finish_quiz(v_attempt);
  assert (r2->>'already_finished')::boolean, 'second finish flagged as already finished';
  assert (select xp from public.users where id = u) = v_xp, 'no double XP';
  assert (select count(*) from public.point_events where user_id = u and kind = 'quiz') = 1, 'single point event';

  -- Odpowiedź po zakończeniu jest odrzucona
  begin
    perform public.submit_answer(v_attempt, (select question_ids[1] from public.quiz_attempts where id = v_attempt), null, 1000);
    assert false, 'answer after finish should fail';
  exception when raise_exception then
    assert sqlerrm = 'attempt_closed', 'unexpected error ' || sqlerrm;
  end;

  -- Quiz dnia: tylko raz dziennie
  r := test.play(u, 'daily', null, 10, 8);
  assert (r->>'lp')::int = 25, 'daily LP ' || r::text;
  begin
    perform set_config('request.jwt.claim.sub', u::text, true);
    perform public.start_quiz('daily');
    assert false, 'daily twice should fail';
  exception when raise_exception then
    assert sqlerrm = 'daily_already_played', sqlerrm;
  end;

  -- Błędne odpowiedzi trafiają do powtórek (po 1 dniu)
  r := test.play(u, 'quick', (select id from public.categories where slug = 'geografia'), 10, 4);
  assert (select count(*) from public.review_queue where user_id = u and stage = 0) = 8, 'wrong answers (2 daily + 6 quick) scheduled for review';
  assert (select bool_and(due_at between now() + interval '12 hours' and now() + interval '30 hours')
          from public.review_queue where user_id = u), 'review due ~1 day (x0.7 for weak category)';
  -- nic jeszcze nie jest do powtórki
  begin
    perform set_config('request.jwt.claim.sub', u::text, true);
    perform public.start_quiz('review');
    assert false, 'no reviews due yet';
  exception when raise_exception then assert sqlerrm = 'no_reviews_due', sqlerrm; end;
  -- przesuwamy termin i robimy powtórkę poprawnie → etap 1 (3 dni)
  update public.review_queue set due_at = now() - interval '1 minute' where user_id = u;
  r := test.play(u, 'review', null, 20, 20);
  assert (r->>'lp')::int = 0, 'review gives no LP';
  assert (select count(*) from public.review_queue where user_id = u and stage = 1) = 8, 'review advanced to stage 1';
  assert (select bool_and(due_at > now() + interval '2 days') from public.review_queue where user_id = u), 'next review ~3 days';

  -- Bot: zbyt szybkie odpowiedzi → brak nagród
  r := test.play(u, 'quick', v_hist, 10, 10, null, 100);
  assert (r->>'flagged')::boolean and (r->>'xp')::int = 0 and (r->>'lp')::int = 0, 'fast answers flagged ' || r::text;

  -- Przetrwanie: kończy się po pierwszym błędzie
  r := test.play(u, 'survival', null, 100, 7);
  assert (r->>'answered')::int = 8 and (r->>'correct')::int = 7, 'survival ends on first mistake ' || r::text;
  assert (r->>'lp')::int = 10, 'survival LP ' || r::text;

  -- Maraton 50
  r := test.play(u, 'marathon', null, 50, 45);
  assert (r->>'lp')::int = 100, 'marathon LP ' || r::text;

  -- Statystyki / profil / misje / ranking działają
  perform set_config('request.jwt.claim.sub', u::text, true);
  assert (public.get_my_stats()->>'answered')::int > 50, 'stats';
  assert (public.get_player()->>'level')::int >= 2, 'level up';
  assert jsonb_array_length(public.get_missions()) = 15, 'missions listed';
  assert (public.get_leaderboard('global')->'me'->>'rank')::int = 1, 'global leaderboard';
  assert (public.get_league_overview()->>'joined')::boolean, 'joined weekly group';
  assert jsonb_array_length(public.get_knowledge_tree(v_hist)) = 9, 'history tree has 9 nodes';
  assert jsonb_array_length(public.get_attempt_review(v_attempt)) = 10, 'attempt review after finish';

  raise notice 'test_02_flow: OK';
end $$;

-- Limit dzienny LP (300)
do $$
declare u uuid := test.new_user('farmer'); i int; r jsonb;
begin
  for i in 1..10 loop
    r := test.play(u, 'marathon', null, 50, 50);
  end loop;
  assert (select lp from public.daily_reward_ledger where user_id = u) = 300, 'daily LP cap';
  assert (select lp from public.league_members where user_id = u) <= 300 + 90, 'league LP respects cap (+ weekly missions)';
  raise notice 'test_02_flow (cap): OK';
end $$;

-- Drzewko wiedzy: zablokowana gałąź
do $$
declare u uuid := test.new_user('drzewko'); v_sub int;
begin
  select id into v_sub from public.subcategories where tree_parent_id is not null limit 1;
  perform set_config('request.jwt.claim.sub', u::text, true);
  begin
    perform public.start_quiz('thematic', null, v_sub, null, 5);
    assert false, 'locked subcategory';
  exception when raise_exception then assert sqlerrm = 'subcategory_locked', sqlerrm; end;
  raise notice 'test_02_flow (tree): OK';
end $$;
