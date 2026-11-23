-- 0005: misje, osiągnięcia, karty kolekcjonerskie.

-- ---------------------------------------------------------------------
-- Wartość metryki gracza (wspólna dla osiągnięć i misji specjalnych)
-- ---------------------------------------------------------------------
create or replace function public.qv_metric(p_user uuid, p_metric text)
returns bigint language plpgsql stable security definer set search_path = public as $$
declare
  v_key text := split_part(p_metric, ':', 1);
  v_arg text := nullif(split_part(p_metric, ':', 2), '');
  v bigint;
begin
  case v_key
    when 'total_correct' then
      select coalesce(sum(correct), 0) into v from public.user_progress where user_id = p_user and subcategory_id = 0;
    when 'total_answered' then
      select coalesce(sum(answered), 0) into v from public.user_progress where user_id = p_user and subcategory_id = 0;
    when 'quizzes' then
      select count(*) into v from public.quiz_attempts where user_id = p_user and status = 'finished';
    when 'perfect_quizzes' then
      select count(*) into v from public.quiz_attempts where user_id = p_user and status = 'finished'
        and question_count >= 5 and correct = question_count and mode not in ('survival', 'sprint');
    when 'best_streak' then
      select best_streak into v from public.users where id = p_user;
    when 'answer_streak' then
      select best_answer_streak into v from public.users where id = p_user;
    when 'cat_correct' then
      select coalesce(sum(up.correct), 0) into v from public.user_progress up
        join public.categories c on c.id = up.category_id
        where up.user_id = p_user and up.subcategory_id = 0 and c.slug = any(string_to_array(v_arg, ','));
    when 'categories_played' then
      select count(*) into v from public.user_progress where user_id = p_user and subcategory_id = 0 and answered > 0;
    when 'subcategories_played' then
      select count(*) into v from public.user_progress where user_id = p_user and subcategory_id <> 0 and answered > 0;
    when 'highest_league' then
      select highest_league_id into v from public.users where id = p_user;
    when 'legend_weeks' then
      select legend_weeks_streak into v from public.users where id = p_user;
    when 'promotions' then
      select count(*) into v from public.league_results where user_id = p_user and outcome = 'promoted';
    when 'top_rank' then   -- liczba tygodni zakończonych na 1. miejscu
      select count(*) into v from public.league_results where user_id = p_user and rank = 1 and lp > 0;
    when 'level' then
      select level into v from public.users where id = p_user;
    when 'cards' then
      select count(*) into v from public.user_cards where user_id = p_user;
    when 'marathon_perfect' then
      select count(*) into v from public.quiz_attempts where user_id = p_user and status = 'finished'
        and mode = 'marathon' and answered = question_count and correct = question_count;
    when 'survival_best' then
      select coalesce(max(correct), 0) into v from public.quiz_attempts where user_id = p_user and status = 'finished' and mode = 'survival';
    when 'sprint_best' then
      select coalesce(max(correct), 0) into v from public.quiz_attempts where user_id = p_user and status = 'finished' and mode = 'sprint';
    when 'category_mastery' then
      select count(*) into v from public.user_progress where user_id = p_user and subcategory_id = 0
        and correct >= 100 and correct::numeric / greatest(answered, 1) >= 0.8;
    when 'daily_quizzes' then
      select count(*) into v from public.quiz_attempts where user_id = p_user and status = 'finished' and mode = 'daily';
    when 'reviews_mastered' then
      select count(*) into v from public.review_queue where user_id = p_user and stage = 4;
    when 'detective_solved' then
      select coalesce(sum(correct), 0) into v from public.quiz_attempts where user_id = p_user and status = 'finished' and mode = 'detective';
    when 'expert_quizzes' then
      select count(*) into v from public.quiz_attempts where user_id = p_user and status = 'finished' and difficulty >= 5;
    when 'seasons_played' then
      select count(*) into v from public.season_results where user_id = p_user;
    when 'articles_favorited' then
      select count(*) into v from public.user_favorite_articles where user_id = p_user;
    else
      v := 0;
  end case;
  return coalesce(v, 0);
end $$;

-- ---------------------------------------------------------------------
-- Osiągnięcia: sprawdź i odblokuj (z jednorazową nagrodą XP)
-- ---------------------------------------------------------------------
create or replace function public.qv_check_achievements(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ach record;
  v_new jsonb := '[]';
begin
  for ach in
    select a.* from public.achievements a
    where not exists (select 1 from public.user_achievements ua where ua.user_id = p_user and ua.achievement_id = a.id)
    order by a.id
  loop
    if public.qv_metric(p_user, ach.metric) >= ach.threshold then
      insert into public.user_achievements(user_id, achievement_id) values (p_user, ach.id) on conflict do nothing;
      if found then
        if ach.xp_reward > 0 then
          insert into public.point_events(user_id, kind, ref, xp) values (p_user, 'achievement', ach.code, ach.xp_reward)
            on conflict do nothing;
          if found then perform public.qv_grant_xp(p_user, ach.xp_reward); end if;
        end if;
        insert into public.notifications(user_id, kind, title, body, payload)
          values (p_user, 'achievement', 'Osiągnięcie: ' || ach.name, ach.description,
                  jsonb_build_object('code', ach.code, 'rarity', ach.rarity, 'tier', ach.tier));
        v_new := v_new || jsonb_build_object('code', ach.code, 'name', ach.name, 'description', ach.description,
                                             'icon', ach.icon, 'rarity', ach.rarity, 'tier', ach.tier, 'xp', ach.xp_reward);
      end if;
    end if;
  end loop;
  return v_new;
end $$;

-- ---------------------------------------------------------------------
-- Misje
-- ---------------------------------------------------------------------
create or replace function public.qv_period_key(p_period public.mission_period)
returns text language sql stable as $$
  select case p_period
    when 'daily'  then 'D:' || public.qv_today()
    when 'weekly' then 'W:' || public.qv_week_start()
    else 'S' end
$$;

create or replace function public.qv_complete_mission(p_user uuid, p_mission public.missions, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.user_missions set completed_at = now(), claimed_at = now()
    where user_id = p_user and mission_id = p_mission.id and period_key = p_key and completed_at is null;
  if not found then return null; end if;

  insert into public.point_events(user_id, kind, ref, xp, lp)
    values (p_user, 'mission', p_mission.code || '@' || p_key, p_mission.xp_reward, p_mission.lp_reward)
    on conflict do nothing;
  if not found then return null; end if;

  perform public.qv_grant_xp(p_user, p_mission.xp_reward);
  if p_mission.lp_reward > 0 then
    perform public.qv_add_league_points(p_user, p_mission.lp_reward);
  end if;
  insert into public.notifications(user_id, kind, title, body, payload)
    values (p_user, 'mission', 'Misja wykonana: ' || p_mission.title,
            'Nagroda: ' || concat_ws(' + ', nullif(p_mission.xp_reward, 0) || ' XP', nullif(p_mission.lp_reward, 0) || ' LP'),
            jsonb_build_object('code', p_mission.code));
  return jsonb_build_object('code', p_mission.code, 'title', p_mission.title, 'period', p_mission.period,
                            'xp', p_mission.xp_reward, 'lp', p_mission.lp_reward);
end $$;

-- ustaw postęp (absolutny) i ewentualnie zakończ
create or replace function public.qv_set_mission_progress(p_user uuid, p_mission public.missions, p_value int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_key text := public.qv_period_key(p_mission.period);
begin
  insert into public.user_missions(user_id, mission_id, period_key, progress)
    values (p_user, p_mission.id, v_key, least(p_value, p_mission.target))
    on conflict (user_id, mission_id, period_key) do update
      set progress = greatest(user_missions.progress, least(excluded.progress, p_mission.target));
  if p_value >= p_mission.target then
    return public.qv_complete_mission(p_user, p_mission, v_key);
  end if;
  return null;
end $$;

-- zwiększ postęp o delta
create or replace function public.qv_bump_mission(p_user uuid, p_mission public.missions, p_delta int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_key text := public.qv_period_key(p_mission.period);
  v_progress int;
begin
  if p_delta <= 0 then return null; end if;
  insert into public.user_missions(user_id, mission_id, period_key, progress)
    values (p_user, p_mission.id, v_key, least(p_delta, p_mission.target))
    on conflict (user_id, mission_id, period_key) do update
      set progress = least(user_missions.progress + p_delta, p_mission.target)
    returning progress into v_progress;
  if v_progress >= p_mission.target then
    return public.qv_complete_mission(p_user, p_mission, v_key);
  end if;
  return null;
end $$;

create or replace function public.qv_refresh_special_missions(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.missions;
  r jsonb;
  v_done jsonb := '[]';
begin
  for m in select * from public.missions where period = 'special' and active loop
    r := public.qv_set_mission_progress(p_user, m, public.qv_metric(p_user, m.metric)::int);
    if r is not null then v_done := v_done || r; end if;
  end loop;
  return v_done;
end $$;

create or replace function public.qv_progress_missions(p_user uuid, a public.quiz_attempts, p_xp int, p_new_category boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.missions;
  r jsonb;
  v_done jsonb := '[]';
  v_acc numeric := case when a.answered > 0 then a.correct::numeric / a.answered else 0 end;
  v_cat_slug text;
  v_delta int;
  v_completed boolean := a.answered >= least(a.question_count, 5);
begin
  select slug into v_cat_slug from public.categories where id = a.category_id;

  for m in select * from public.missions where period in ('daily', 'weekly') and active order by id loop
    r := null;
    case m.metric
      when 'quizzes_completed' then
        r := public.qv_bump_mission(p_user, m, case when v_completed then 1 else 0 end);
      when 'correct_answers' then
        r := public.qv_bump_mission(p_user, m, a.correct);
      when 'accuracy_quiz' then
        r := public.qv_bump_mission(p_user, m, case when a.answered >= 5 and v_acc >= coalesce(m.param, '80')::numeric / 100 then 1 else 0 end);
      when 'category_quiz' then
        -- liczy się quiz z wybraną kategorią albo quiz mieszany, w którym ta kategoria stanowi połowę pytań
        r := public.qv_bump_mission(p_user, m, case when v_completed and (
               v_cat_slug = m.param
               or (a.category_id is null and (
                     select count(*) filter (where c.slug = m.param) * 2 >= count(*)
                     from public.questions q join public.categories c on c.id = q.category_id
                     where q.id = any(a.question_ids)))
             ) then 1 else 0 end);
      when 'new_category' then
        r := public.qv_bump_mission(p_user, m, case when p_new_category and v_completed then 1 else 0 end);
      when 'xp_earned' then
        r := public.qv_bump_mission(p_user, m, p_xp);
      when 'distinct_categories' then
        select count(distinct category_id) into v_delta from public.quiz_attempts
          where user_id = p_user and status = 'finished' and week_start = a.week_start and category_id is not null;
        r := public.qv_set_mission_progress(p_user, m, v_delta);
      when 'expert_quiz' then
        r := public.qv_bump_mission(p_user, m, case when v_completed and coalesce(a.difficulty, 0) >= 5 then 1 else 0 end);
      else null;
    end case;
    if r is not null then v_done := v_done || r; end if;
  end loop;

  v_done := v_done || public.qv_refresh_special_missions(p_user);
  return v_done;
end $$;

-- ---------------------------------------------------------------------
-- Karty kolekcjonerskie – za aktywność edukacyjną (nigdy za pieniądze)
-- Zasady: komplet poprawnych (min. 5 pytań), co 5. ukończony quiz,
-- lub min. 15 poprawnych w przetrwaniu / sprincie.
-- ---------------------------------------------------------------------
create or replace function public.qv_maybe_award_card(p_user uuid, a public.quiz_attempts)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_finished bigint;
  v_eligible boolean;
  v_reason text;
  v_cat smallint := a.category_id;
  v_roll numeric := random();
  v_rarity public.rarity;
  v_hard boolean := coalesce(a.difficulty, 0) >= 5;
  c public.collectible_cards;
  v_copies int;
begin
  select count(*) into v_finished from public.quiz_attempts where user_id = p_user and status = 'finished';

  if a.question_count >= 5 and a.correct = a.question_count and a.mode not in ('survival', 'sprint') then
    v_eligible := true; v_reason := 'perfect';
  elsif a.mode in ('survival', 'sprint') and a.correct >= 15 then
    v_eligible := true; v_reason := a.mode::text;
  elsif v_finished > 0 and v_finished % 5 = 0 then
    v_eligible := true; v_reason := 'activity';
  else
    return null;
  end if;

  -- jedna karta na podejście
  insert into public.point_events(user_id, kind, ref) values (p_user, 'card', a.id::text) on conflict do nothing;
  if not found then return null; end if;

  if v_cat is null then
    select q.category_id into v_cat from public.questions q where q.id = any(a.question_ids) order by random() limit 1;
  end if;

  v_rarity := case
    when v_roll < case when v_hard then 0.05 else 0.02 end then 'legendary'
    when v_roll < case when v_hard then 0.20 else 0.10 end then 'epic'
    when v_roll < case when v_hard then 0.55 else 0.38 end then 'rare'
    else 'common' end;

  select * into c from public.collectible_cards cc
    where cc.category_id = v_cat and cc.rarity = v_rarity
    order by exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = cc.id), random()
    limit 1;
  if not found then
    select * into c from public.collectible_cards cc
      where cc.category_id = v_cat
      order by exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = cc.id),
               cc.rarity, random()
      limit 1;
  end if;
  if not found then
    select * into c from public.collectible_cards cc
      order by exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = cc.id), cc.rarity, random()
      limit 1;
  end if;
  if not found then return null; end if;

  insert into public.user_cards(user_id, card_id, source) values (p_user, c.id, v_reason)
    on conflict (user_id, card_id) do update set copies = user_cards.copies + 1
    returning copies into v_copies;

  return jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'description', c.description,
                            'rarity', c.rarity, 'kind', c.kind, 'art', c.art, 'category_id', c.category_id,
                            'duplicate', v_copies > 1, 'reason', v_reason);
end $$;
