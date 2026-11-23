-- 0003: przebieg quizu – start, odpowiedź, zakończenie.
-- Klient NIGDY nie dostaje informacji o prawidłowej odpowiedzi przed udzieleniem swojej.
-- Wszystkie nagrody liczone są tutaj, po stronie serwera, dokładnie raz na podejście.

-- ---------------------------------------------------------------------
-- Publiczna reprezentacja pytania (bez is_correct i bez wyjaśnienia)
-- ---------------------------------------------------------------------
create or replace function public.qv_public_question(p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', q.id,
    'prompt', q.prompt,
    'kind', q.kind,
    'clues', q.clues,
    'difficulty', q.difficulty,
    'category_id', q.category_id,
    'subcategory_id', q.subcategory_id,
    'source', q.source,
    'status', q.status,
    'answers', (select jsonb_agg(jsonb_build_object('id', a.id, 'body', a.body) order by md5(a.id::text || q.id::text))
                from public.answers a where a.question_id = q.id)
  )
  from public.questions q where q.id = p_id
$$;

-- ---------------------------------------------------------------------
-- Dobór pytań: najpierw niewidziane w ostatnich 7 dniach, najbliższa trudność, losowo
-- ---------------------------------------------------------------------
create or replace function public.qv_pick_questions(
  p_user uuid, p_count int, p_category smallint, p_subcategory int, p_difficulty int,
  p_kind public.question_kind, p_include_ai boolean
) returns uuid[] language sql volatile security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from (
    select q.id
    from public.questions q
    where (q.status = 'approved' or (p_include_ai and q.status = 'ai_verified'))
      and q.kind = p_kind
      and (p_category is null or q.category_id = p_category)
      and (p_subcategory is null or q.subcategory_id = p_subcategory)
    order by
      exists (select 1 from public.user_answers ua
              where ua.user_id = p_user and ua.question_id = q.id
                and ua.answered_at > now() - interval '7 days'),
      abs(q.difficulty - coalesce(p_difficulty, q.difficulty)),
      random()
    limit p_count
  ) t
$$;

-- ---------------------------------------------------------------------
-- Quiz dnia: jeden wspólny zestaw 10 pytań na dzień (różne kategorie)
-- ---------------------------------------------------------------------
create or replace function public.ensure_daily_quiz(p_day date default public.qv_today())
returns public.quizzes language plpgsql security definer set search_path = public as $$
declare
  qz public.quizzes;
  v_ids uuid[];
begin
  select * into qz from public.quizzes where mode = 'daily' and quiz_date = p_day;
  if found then return qz; end if;

  -- po jednym pytaniu z 10 losowych kategorii, uporządkowane rosnąco wg trudności
  select array_agg(id order by difficulty, id) into v_ids from (
    select * from (
      select distinct on (q.category_id) q.id, q.difficulty, q.category_id
      from public.questions q
      where q.status = 'approved' and q.kind = 'standard'
      order by q.category_id, md5(q.id::text || p_day::text)
    ) per_cat
    order by md5(per_cat.category_id::text || p_day::text)
    limit 10
  ) chosen;

  if v_ids is null or array_length(v_ids, 1) < 10 then
    -- za mało kategorii – dobierz dowolne pytania
    select array_agg(id) into v_ids from (
      select q.id from public.questions q
      where q.status = 'approved' and q.kind = 'standard'
      order by md5(q.id::text || p_day::text) limit 10) t;
  end if;

  if v_ids is null or array_length(v_ids, 1) < 10 then
    raise exception 'not_enough_questions' using hint = 'Baza pytań jest pusta – uruchom seed.';
  end if;

  insert into public.quizzes(mode, title, question_ids, quiz_date)
    values ('daily', 'Quiz dnia ' || to_char(p_day, 'DD.MM.YYYY'), v_ids, p_day)
    on conflict do nothing;
  select * into qz from public.quizzes where mode = 'daily' and quiz_date = p_day;
  return qz;
end $$;

-- ---------------------------------------------------------------------
-- Czy podkategoria (węzeł drzewka wiedzy) jest odblokowana dla gracza
-- ---------------------------------------------------------------------
create or replace function public.qv_subcategory_unlocked(p_user uuid, p_sub int)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when s.tree_parent_id is null or s.unlock_correct = 0 then true
    else coalesce((select up.correct from public.user_progress up
                   where up.user_id = p_user and up.category_id = s.category_id
                     and up.subcategory_id = s.tree_parent_id), 0) >= s.unlock_correct
  end
  from public.subcategories s where s.id = p_sub
$$;

-- ---------------------------------------------------------------------
-- START QUIZU
-- p_mode: daily | quick | marathon | survival | sprint | thematic | detective | review | ai
-- p_count: liczba pytań (quick/thematic/ai: 5|10|20, marathon: 50|100)
-- p_time_limit: sprint 60|120 s
-- ---------------------------------------------------------------------
create or replace function public.start_quiz(
  p_mode public.quiz_mode,
  p_category smallint default null,
  p_subcategory int default null,
  p_difficulty int default null,
  p_count int default 10,
  p_time_limit int default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_ids uuid[];
  v_quiz public.quizzes;
  v_attempt public.quiz_attempts;
  v_season public.seasons;
  v_count int := p_count;
  v_limit int := null;
begin
  if v_user is null then raise exception 'not_authenticated'; end if;
  if p_difficulty is not null and p_difficulty not between 1 and 6 then raise exception 'invalid_difficulty'; end if;

  -- jedno aktywne podejście naraz: poprzednie oznaczamy jako porzucone
  update public.quiz_attempts set status = 'abandoned', finished_at = now()
    where user_id = v_user and status = 'in_progress';

  if p_subcategory is not null then
    if not exists (select 1 from public.subcategories where id = p_subcategory and (p_category is null or category_id = p_category)) then
      raise exception 'invalid_subcategory';
    end if;
    if not public.qv_subcategory_unlocked(v_user, p_subcategory) then
      raise exception 'subcategory_locked';
    end if;
    if p_category is null then
      select category_id into p_category from public.subcategories where id = p_subcategory;
    end if;
  end if;

  case p_mode
    when 'daily' then
      v_quiz := public.ensure_daily_quiz();
      if exists (select 1 from public.quiz_attempts where user_id = v_user and quiz_id = v_quiz.id and mode = 'daily') then
        raise exception 'daily_already_played';
      end if;
      v_ids := v_quiz.question_ids;
      p_category := null; p_subcategory := null; p_difficulty := null;
    when 'quick' then
      v_count := 10;
      v_ids := public.qv_pick_questions(v_user, v_count, p_category, p_subcategory, p_difficulty, 'standard', false);
    when 'thematic' then
      if p_category is null then raise exception 'category_required'; end if;
      if v_count not in (5, 10, 20) then raise exception 'invalid_count'; end if;
      v_ids := public.qv_pick_questions(v_user, v_count, p_category, p_subcategory, p_difficulty, 'standard', false);
    when 'ai' then
      if p_category is null then raise exception 'category_required'; end if;
      if v_count not in (5, 10, 20) then raise exception 'invalid_count'; end if;
      v_ids := public.qv_pick_questions(v_user, v_count, p_category, p_subcategory, p_difficulty, 'standard', true);
    when 'marathon' then
      if v_count not in (50, 100) then raise exception 'invalid_count'; end if;
      v_ids := public.qv_pick_questions(v_user, v_count, p_category, p_subcategory, p_difficulty, 'standard', false);
    when 'survival' then
      v_ids := public.qv_pick_questions(v_user, 100, p_category, p_subcategory, p_difficulty, 'standard', false);
    when 'sprint' then
      v_limit := coalesce(p_time_limit, 60);
      if v_limit not in (60, 120) then raise exception 'invalid_time_limit'; end if;
      v_ids := public.qv_pick_questions(v_user, case when v_limit = 60 then 40 else 80 end, p_category, p_subcategory, p_difficulty, 'standard', false);
    when 'detective' then
      v_count := 5;
      v_ids := public.qv_pick_questions(v_user, v_count, p_category, null, p_difficulty, 'detective', false);
    when 'review' then
      select coalesce(array_agg(question_id), '{}') into v_ids from (
        select rq.question_id from public.review_queue rq
        join public.questions q on q.id = rq.question_id and q.status in ('approved', 'ai_verified')
        where rq.user_id = v_user and rq.stage < 4 and rq.due_at <= now()
        order by rq.due_at limit 20) t;
      if array_length(v_ids, 1) is null then raise exception 'no_reviews_due'; end if;
  end case;

  if v_ids is null or array_length(v_ids, 1) is null
     or (p_mode in ('quick', 'thematic', 'ai', 'detective', 'daily') and array_length(v_ids, 1) < least(v_count, 5)) then
    raise exception 'not_enough_questions';
  end if;

  -- liczba pytań w zestawie = faktycznie dobrane (np. mniejsza pula w kategorii)
  v_count := array_length(v_ids, 1);
  v_season := public.ensure_season();

  insert into public.quiz_attempts(user_id, quiz_id, mode, category_id, subcategory_id, difficulty,
                                   question_ids, question_count, time_limit_s, season_id, week_start)
  values (v_user, v_quiz.id, p_mode, p_category, p_subcategory, p_difficulty,
          v_ids, v_count, v_limit, v_season.id, public.qv_week_start())
  returning * into v_attempt;

  return jsonb_build_object(
    'attempt_id', v_attempt.id,
    'mode', p_mode,
    'question_count', v_count,
    'time_limit_s', v_limit,
    'started_at', v_attempt.started_at,
    'questions', (select jsonb_agg(public.qv_public_question(qid) order by ord)
                  from unnest(v_ids) with ordinality as u(qid, ord))
  );
end $$;

-- ---------------------------------------------------------------------
-- Powtórki: interwały 1 / 3 / 7 / 30 dni, skalowane skutecznością gracza w kategorii
-- ---------------------------------------------------------------------
create or replace function public.qv_review_factor(p_user uuid, p_category smallint)
returns numeric language sql stable security definer set search_path = public as $$
  select case
    when up.answered is null or up.answered < 10 then 1.0
    when up.correct::numeric / up.answered < 0.5  then 0.7    -- słabo: częściej
    when up.correct::numeric / up.answered > 0.85 then 1.25   -- bardzo dobrze: rzadziej
    else 1.0 end
  from (select 1) d
  left join public.user_progress up on up.user_id = p_user and up.category_id = p_category and up.subcategory_id = 0
$$;

create or replace function public.qv_update_review(p_user uuid, p_question uuid, p_category smallint, p_correct boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  r public.review_queue;
  intervals int[] := array[1, 3, 7, 30];
  f numeric := public.qv_review_factor(p_user, p_category);
begin
  select * into r from public.review_queue where user_id = p_user and question_id = p_question for update;
  if not p_correct then
    insert into public.review_queue(user_id, question_id, stage, lapses, due_at, last_result)
      values (p_user, p_question, 0, 1, now() + make_interval(secs => intervals[1] * 86400 * f), false)
      on conflict (user_id, question_id) do update
        set stage = 0, lapses = review_queue.lapses + 1,
            due_at = now() + make_interval(secs => intervals[1] * 86400 * f),
            last_result = false, updated_at = now();
  elsif found and r.stage < 4 and r.due_at <= now() then
    -- poprawna odpowiedź w terminie powtórki: kolejny etap
    update public.review_queue
      set stage = r.stage + 1,
          due_at = case when r.stage + 1 >= 4 then now() + interval '3650 days'
                        else now() + make_interval(secs => intervals[r.stage + 2] * 86400 * f) end,
          last_result = true, updated_at = now()
      where user_id = p_user and question_id = p_question;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- ODPOWIEDŹ NA PYTANIE
-- ---------------------------------------------------------------------
create or replace function public.submit_answer(
  p_attempt uuid, p_question uuid, p_answer uuid, p_time_ms int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  a public.quiz_attempts;
  q public.questions;
  v_correct_id uuid;
  v_is_correct boolean;
  v_time_over boolean := false;
  v_ends boolean := false;
  v_article text;
begin
  if v_user is null then raise exception 'not_authenticated'; end if;

  select * into a from public.quiz_attempts where id = p_attempt for update;
  if not found or a.user_id <> v_user then raise exception 'attempt_not_found'; end if;
  if a.status <> 'in_progress' then raise exception 'attempt_closed'; end if;
  if not (p_question = any(a.question_ids)) then raise exception 'question_not_in_attempt'; end if;
  if exists (select 1 from public.user_answers where attempt_id = p_attempt and question_id = p_question) then
    raise exception 'already_answered';
  end if;
  if now() > a.started_at + make_interval(hours => (public.qv_limits()->>'attempt_ttl_hours')::int) then
    raise exception 'attempt_expired';
  end if;

  -- sprint: odpowiedzi po czasie (z 3 s tolerancji na sieć) nie są liczone
  if a.time_limit_s is not null and now() > a.started_at + make_interval(secs => a.time_limit_s + 3) then
    return jsonb_build_object('time_over', true, 'ends_quiz', true);
  end if;

  -- przetrwanie: po błędnej odpowiedzi nie można odpowiadać dalej
  if a.mode = 'survival' and a.answered > a.correct then raise exception 'attempt_closed'; end if;

  select * into q from public.questions where id = p_question;
  select id into v_correct_id from public.answers where question_id = p_question and is_correct;

  if p_answer is not null and not exists (select 1 from public.answers where id = p_answer and question_id = p_question) then
    raise exception 'answer_not_in_question';
  end if;
  v_is_correct := p_answer is not null and p_answer = v_correct_id;

  insert into public.user_answers(attempt_id, user_id, question_id, answer_id, is_correct, time_ms)
    values (p_attempt, v_user, p_question, p_answer, v_is_correct, greatest(0, least(coalesce(p_time_ms, 0), 600000)));

  update public.quiz_attempts
    set answered = answered + 1, correct = correct + (v_is_correct)::int
    where id = p_attempt returning * into a;

  update public.questions
    set times_answered = times_answered + 1, times_correct = times_correct + (v_is_correct)::int
    where id = p_question;

  -- seria poprawnych odpowiedzi
  update public.users set
    current_answer_streak = case when v_is_correct then current_answer_streak + 1 else 0 end,
    best_answer_streak = greatest(best_answer_streak, case when v_is_correct then current_answer_streak + 1 else 0 end)
    where id = v_user;

  -- postęp w kategorii i podkategorii (drzewko wiedzy)
  insert into public.user_progress(user_id, category_id, subcategory_id, answered, correct)
    values (v_user, q.category_id, 0, 1, v_is_correct::int)
    on conflict (user_id, category_id, subcategory_id) do update
      set answered = user_progress.answered + 1, correct = user_progress.correct + excluded.correct, updated_at = now();
  if q.subcategory_id is not null then
    insert into public.user_progress(user_id, category_id, subcategory_id, answered, correct, unlocked_at)
      values (v_user, q.category_id, q.subcategory_id, 1, v_is_correct::int, now())
      on conflict (user_id, category_id, subcategory_id) do update
        set answered = user_progress.answered + 1, correct = user_progress.correct + excluded.correct, updated_at = now();
  end if;

  -- inteligentne powtórki
  perform public.qv_update_review(v_user, p_question, q.category_id, v_is_correct);

  v_ends := (a.mode = 'survival' and not v_is_correct)
            or a.answered >= a.question_count;

  select slug into v_article from public.knowledge_articles where id = q.article_id;

  return jsonb_build_object(
    'correct', v_is_correct,
    'correct_answer_id', v_correct_id,
    'explanation', q.explanation,
    'article_slug', v_article,
    'sources', q.sources,
    'answered', a.answered,
    'correct_total', a.correct,
    'ends_quiz', v_ends,
    'time_over', v_time_over
  );
end $$;

-- ---------------------------------------------------------------------
-- ZAKOŃCZENIE QUIZU – naliczenie XP/LP (idempotentne)
-- ---------------------------------------------------------------------
create or replace function public.finish_quiz(p_attempt uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  a public.quiz_attempts;
  u public.users;
  v_completed boolean;
  v_rewards jsonb;
  v_xp int; v_lp int;
  v_led public.daily_reward_ledger;
  v_caps jsonb := public.qv_limits();
  v_flag boolean := false;
  v_avg_ms numeric;
  v_level_before int; v_level_after int;
  v_new_category boolean := false;
  v_missions jsonb := '[]';
  v_achievements jsonb := '[]';
  v_card jsonb := null;
  v_league jsonb := null;
  v_capped jsonb := '{}';
  v_result jsonb;
  v_today date := public.qv_today();
begin
  if v_user is null then raise exception 'not_authenticated'; end if;

  select * into a from public.quiz_attempts where id = p_attempt for update;
  if not found or a.user_id <> v_user then raise exception 'attempt_not_found'; end if;

  -- idempotencja: drugie wywołanie zwraca zapisany wynik
  if a.status in ('finished', 'flagged') then
    return a.reward_breakdown || jsonb_build_object('already_finished', true);
  end if;
  if a.status = 'abandoned' then raise exception 'attempt_closed'; end if;

  select * into u from public.users where id = v_user for update;
  v_level_before := u.level;

  v_completed := case
    when a.mode in ('survival', 'sprint') then a.answered >= 1
    when a.mode = 'marathon' then a.answered >= 5
    else a.answered >= a.question_count end;

  -- weryfikacja wyniku: tempo odpowiedzi
  select avg(time_ms) into v_avg_ms from public.user_answers where attempt_id = p_attempt;
  if a.answered >= 3 and (
       coalesce(v_avg_ms, 0) < (v_caps->>'min_avg_answer_ms')::numeric
       or extract(epoch from (now() - a.started_at)) * 1000 / a.answered < (v_caps->>'min_avg_answer_ms')::numeric
     ) then
    v_flag := true;
  end if;

  -- czy to pierwszy quiz w tej kategorii (misja "nowa kategoria")
  if a.category_id is not null then
    select coalesce(max(quizzes), 0) = 0 into v_new_category
      from public.user_progress where user_id = v_user and category_id = a.category_id and subcategory_id = 0;
  end if;

  v_rewards := public.qv_compute_rewards(a.mode, a.question_count, a.answered, a.correct,
                                          coalesce(a.difficulty, (select round(avg(difficulty))::int from public.questions where id = any(a.question_ids))),
                                          v_completed);
  v_xp := (v_rewards->>'xp')::int;
  v_lp := (v_rewards->>'lp')::int;

  if v_flag then
    v_xp := 0; v_lp := 0;
  end if;

  -- dzienne limity
  insert into public.daily_reward_ledger(user_id, day) values (v_user, v_today) on conflict do nothing;
  select * into v_led from public.daily_reward_ledger where user_id = v_user and day = v_today for update;
  if v_led.lp + v_lp > (v_caps->>'daily_lp_cap')::int then
    v_capped := v_capped || jsonb_build_object('lp', v_lp - greatest(0, (v_caps->>'daily_lp_cap')::int - v_led.lp));
    v_lp := greatest(0, (v_caps->>'daily_lp_cap')::int - v_led.lp);
  end if;
  if v_led.xp + v_xp > (v_caps->>'daily_xp_cap')::int then
    v_capped := v_capped || jsonb_build_object('xp', v_xp - greatest(0, (v_caps->>'daily_xp_cap')::int - v_led.xp));
    v_xp := greatest(0, (v_caps->>'daily_xp_cap')::int - v_led.xp);
  end if;
  update public.daily_reward_ledger set xp = xp + v_xp, lp = lp + v_lp, quizzes = quizzes + 1
    where user_id = v_user and day = v_today;

  -- dziennik punktów: unikalny (user, 'quiz', attempt) blokuje podwójne naliczenie
  insert into public.point_events(user_id, kind, ref, xp, lp) values (v_user, 'quiz', p_attempt::text, v_xp, v_lp);

  -- statystyki kategorii (liczba quizów, XP)
  if a.category_id is not null then
    update public.user_progress set quizzes = quizzes + 1, xp = xp + v_xp
      where user_id = v_user and category_id = a.category_id and subcategory_id = 0;
    if a.subcategory_id is not null then
      update public.user_progress set quizzes = quizzes + 1
        where user_id = v_user and category_id = a.category_id and subcategory_id = a.subcategory_id;
    end if;
  end if;

  -- seria dni
  update public.users set
    current_streak = case
      when last_active_date = v_today then current_streak
      when last_active_date = v_today - 1 then current_streak + 1
      else 1 end,
    last_active_date = v_today
    where id = v_user;
  update public.users set best_streak = greatest(best_streak, current_streak) where id = v_user;

  -- XP i poziom
  perform public.qv_grant_xp(v_user, v_xp);

  -- LP i liga tygodniowa
  if v_lp > 0 then
    v_league := public.qv_add_league_points(v_user, v_lp);
  end if;

  update public.quiz_attempts set
    status = case when v_flag then 'flagged'::public.attempt_status else 'finished'::public.attempt_status end,
    finished_at = now(), xp_awarded = v_xp, lp_awarded = v_lp
    where id = p_attempt returning * into a;

  if not v_flag then
    v_missions := public.qv_progress_missions(v_user, a, v_xp, v_new_category);
    v_card := public.qv_maybe_award_card(v_user, a);
  end if;
  v_achievements := public.qv_check_achievements(v_user);

  select level into v_level_after from public.users where id = v_user;

  v_result := jsonb_build_object(
    'attempt_id', a.id,
    'mode', a.mode,
    'answered', a.answered,
    'correct', a.correct,
    'question_count', a.question_count,
    'accuracy', v_rewards->'accuracy',
    'completed', v_completed,
    'flagged', v_flag,
    'xp', v_xp,
    'lp', v_lp,
    'xp_items', v_rewards->'xp_items',
    'lp_items', v_rewards->'lp_items',
    'lp_blocked_low_accuracy', v_rewards->'lp_blocked_low_accuracy',
    'capped', v_capped,
    'level_before', v_level_before,
    'level_after', v_level_after,
    'title', public.qv_title_for_level(v_level_after),
    'missions_completed', v_missions,
    'achievements_unlocked', v_achievements,
    'card', v_card,
    'league', v_league
  );
  update public.quiz_attempts set reward_breakdown = v_result where id = p_attempt;
  return v_result;
end $$;

-- ---------------------------------------------------------------------
-- XP → poziom (wewnętrzne; wywoływane przez quizy, misje, osiągnięcia)
-- ---------------------------------------------------------------------
create or replace function public.qv_grant_xp(p_user uuid, p_xp int)
returns int language plpgsql security definer set search_path = public as $$
declare v_level int; v_old int;
begin
  if p_xp <= 0 then
    select level into v_level from public.users where id = p_user;
    return v_level;
  end if;
  select level into v_old from public.users where id = p_user;
  update public.users set xp = xp + p_xp, level = public.qv_level_for_xp(xp + p_xp)
    where id = p_user returning level into v_level;
  if v_level > v_old then
    insert into public.notifications(user_id, kind, title, body, payload)
      values (p_user, 'level_up', 'Nowy poziom: ' || v_level,
              'Twój tytuł: ' || public.qv_title_for_level(v_level) || '. Tak trzymaj!',
              jsonb_build_object('level', v_level));
  end if;
  return v_level;
end $$;

-- Zgłoszenie błędu w pytaniu; 3 otwarte zgłoszenia zdejmują pytanie do weryfikacji
create or replace function public.report_question(p_question uuid, p_reason text, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  -- zgłaszać można tylko pytania, na które się odpowiadało
  if not exists (select 1 from public.user_answers where user_id = auth.uid() and question_id = p_question) then
    raise exception 'question_not_answered';
  end if;
  insert into public.question_reports(question_id, user_id, reason, comment)
    values (p_question, auth.uid(), p_reason, left(p_comment, 500))
    on conflict (question_id, user_id) do update set reason = excluded.reason, comment = excluded.comment, status = 'open';
  if (select count(*) from public.question_reports where question_id = p_question and status = 'open') >= 3 then
    update public.questions set status = 'pending_review' where id = p_question and status in ('approved', 'ai_verified');
  end if;
end $$;
