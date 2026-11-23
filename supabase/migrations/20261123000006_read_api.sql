-- 0006: API odczytu dla aplikacji (RPC) + konto, admin.

-- ---------------------------------------------------------------------
-- Profil gracza (własny lub cudzy – dane publiczne)
-- ---------------------------------------------------------------------
create or replace function public.get_player(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_id uuid := coalesce(p_user, auth.uid());
  u public.users; p public.profiles;
  v_season public.seasons;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into u from public.users where id = v_id;
  if not found then raise exception 'player_not_found'; end if;
  select * into p from public.profiles where id = v_id;
  select * into v_season from public.seasons where starts_at <= now() and ends_at > now();

  return jsonb_build_object(
    'id', u.id,
    'is_me', v_id = auth.uid(),
    'role', case when v_id = auth.uid() then u.role::text else null end,
    'username', p.username,
    'display_name', p.display_name,
    'avatar', p.avatar, 'avatar_color', p.avatar_color, 'frame', p.frame, 'background', p.background,
    'bio', p.bio,
    'notifications', case when v_id = auth.uid() then p.notifications else null end,
    'xp', u.xp,
    'level', u.level,
    'level_xp_start', public.qv_xp_for_level(u.level),
    'level_xp_next', case when u.level >= 151 then null else public.qv_xp_for_level(u.level + 1) end,
    'title', coalesce(p.selected_title, public.qv_title_for_level(u.level)),
    'level_title', public.qv_title_for_level(u.level),
    'league_id', u.league_id,
    'highest_league_id', u.highest_league_id,
    'current_streak', case when u.last_active_date >= public.qv_today() - 1 then u.current_streak else 0 end,
    'best_streak', u.best_streak,
    'best_answer_streak', u.best_answer_streak,
    'created_at', u.created_at,
    'season', case when v_season.id is null then null else jsonb_build_object(
        'id', v_season.id, 'name', v_season.name, 'starts_at', v_season.starts_at, 'ends_at', v_season.ends_at,
        'week', floor(extract(epoch from now() - v_season.starts_at) / 604800)::int + 1) end,
    'week_ends_at', public.qv_week_end(public.qv_week_start()),
    'stats', jsonb_build_object(
        'answered', public.qv_metric(v_id, 'total_answered'),
        'correct', public.qv_metric(v_id, 'total_correct'),
        'quizzes', public.qv_metric(v_id, 'quizzes'),
        'cards', public.qv_metric(v_id, 'cards'),
        'achievements', (select count(*) from public.user_achievements where user_id = v_id)),
    'top_categories', (select coalesce(jsonb_agg(t), '[]') from (
        select up.category_id, c.name, c.icon, c.color_hex, up.correct, up.answered,
               round(up.correct::numeric / greatest(up.answered, 1), 3) as accuracy
        from public.user_progress up join public.categories c on c.id = up.category_id
        where up.user_id = v_id and up.subcategory_id = 0 and up.answered >= 5
        order by up.correct desc limit 3) t),
    'badges', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name, 'icon', a.icon,
                         'tier', a.tier, 'rarity', a.rarity, 'unlocked_at', ua.unlocked_at) order by ua.unlocked_at desc), '[]')
               from public.user_achievements ua join public.achievements a on a.id = ua.achievement_id
               where ua.user_id = v_id)
  );
end $$;

-- ---------------------------------------------------------------------
-- Liga: moja grupa tygodnia, strefy, czas do końca
-- ---------------------------------------------------------------------
create or replace function public.get_league_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_week date := public.qv_week_start();
  v_group bigint;
  u public.users;
  l public.leagues;
begin
  if v_user is null then raise exception 'not_authenticated'; end if;
  select * into u from public.users where id = v_user;
  select * into l from public.leagues where id = u.league_id;
  select group_id into v_group from public.league_members where user_id = v_user and week_start = v_week;

  return jsonb_build_object(
    'league', to_jsonb(l),
    'week_start', v_week,
    'week_ends_at', public.qv_week_end(v_week),
    'joined', v_group is not null,
    'group_id', v_group,
    'zones', jsonb_build_object('promotion_max', case when u.league_id < 5 then 10 else 0 end,
                                'relegation_min', case when u.league_id > 1 then 24 else 31 end),
    'standings', case when v_group is null then '[]'::jsonb else (
      select coalesce(jsonb_agg(row_to_json(t) order by t.rank), '[]') from (
        select row_number() over (order by lm.lp desc, lm.last_lp_at asc nulls last, lm.joined_at asc)::int as rank,
               lm.user_id, p.username, p.avatar, p.avatar_color, p.frame, us.level, lm.lp,
               lm.user_id = v_user as is_me
        from public.league_members lm
        join public.profiles p on p.id = lm.user_id
        join public.users us on us.id = lm.user_id
        where lm.group_id = v_group) t) end,
    'history', (select coalesce(jsonb_agg(row_to_json(h) order by h.week_start desc), '[]') from (
        select week_start, league_id, new_league_id, rank, lp, outcome from public.league_results
        where user_id = v_user order by week_start desc limit 20) h)
  );
end $$;

-- ---------------------------------------------------------------------
-- Rankingi: weekly | global | season | category | activity
-- ---------------------------------------------------------------------
create or replace function public.get_leaderboard(p_kind text, p_category smallint default null, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_season_id int;
  v_week date := public.qv_week_start();
begin
  if v_user is null then raise exception 'not_authenticated'; end if;
  if p_kind not in ('weekly', 'global', 'season', 'category', 'activity') then raise exception 'invalid_kind'; end if;
  if p_kind = 'category' and p_category is null then raise exception 'category_required'; end if;
  p_limit := least(greatest(p_limit, 1), 100);
  select id into v_season_id from public.seasons where starts_at <= now() and ends_at > now();

  return (
    with lb as (
      select user_id, lp::bigint as value from public.league_members
        where p_kind = 'weekly' and week_start = v_week and lp > 0
      union all
      select id, xp from public.users where p_kind = 'global' and xp > 0
      union all
      select lm.user_id, sum(lm.lp)::bigint from public.league_members lm
        join public.league_groups g on g.id = lm.group_id
        where p_kind = 'season' and g.season_id = v_season_id group by lm.user_id having sum(lm.lp) > 0
      union all
      select user_id, correct::bigint from public.user_progress
        where p_kind = 'category' and category_id = p_category and subcategory_id = 0 and correct > 0
      union all
      select user_id, count(*)::bigint from public.quiz_attempts
        where p_kind = 'activity' and status = 'finished' and finished_at > now() - interval '7 days' group by user_id
    ), ranked as (
      select lb.*, rank() over (order by lb.value desc)::int as rank from lb
    )
    select jsonb_build_object(
      'kind', p_kind,
      'total', (select count(*) from ranked),
      'me', (select jsonb_build_object('rank', r.rank, 'value', r.value) from ranked r where r.user_id = v_user),
      'rows', (select coalesce(jsonb_agg(row_to_json(t) order by t.rank, t.username), '[]') from (
          select r.rank, r.user_id, p.username, p.avatar, p.avatar_color, u.level, u.league_id, r.value,
                 r.user_id = v_user as is_me
          from ranked r join public.profiles p on p.id = r.user_id join public.users u on u.id = r.user_id
          order by r.rank, p.username limit p_limit) t)
    )
  );
end $$;

-- ---------------------------------------------------------------------
-- Statystyki
-- ---------------------------------------------------------------------
create or replace function public.get_my_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  u public.users;
  v_today date := public.qv_today();
begin
  if v_user is null then raise exception 'not_authenticated'; end if;
  select * into u from public.users where id = v_user;

  return jsonb_build_object(
    'answered', public.qv_metric(v_user, 'total_answered'),
    'correct', public.qv_metric(v_user, 'total_correct'),
    'quizzes', public.qv_metric(v_user, 'quizzes'),
    'perfect_quizzes', public.qv_metric(v_user, 'perfect_quizzes'),
    'avg_time_ms', (select round(avg(time_ms)) from public.user_answers where user_id = v_user),
    'current_streak', case when u.last_active_date >= v_today - 1 then u.current_streak else 0 end,
    'best_streak', u.best_streak,
    'current_answer_streak', u.current_answer_streak,
    'best_answer_streak', u.best_answer_streak,
    'categories', (select coalesce(jsonb_agg(row_to_json(c) order by c.correct desc), '[]') from (
        select up.category_id, cat.name, cat.icon, cat.color_hex, up.answered, up.correct, up.quizzes, up.xp,
               round(up.correct::numeric / greatest(up.answered, 1), 3) as accuracy,
               (select count(*) from public.subcategories s where s.category_id = up.category_id) as subcategories_total,
               (select count(*) from public.user_progress sp where sp.user_id = v_user and sp.category_id = up.category_id
                  and sp.subcategory_id <> 0 and sp.answered > 0) as subcategories_played
        from public.user_progress up join public.categories cat on cat.id = up.category_id
        where up.user_id = v_user and up.subcategory_id = 0) c),
    'best_category', (select row_to_json(b) from (
        select up.category_id, c.name, round(up.correct::numeric / up.answered, 3) as accuracy
        from public.user_progress up join public.categories c on c.id = up.category_id
        where up.user_id = v_user and up.subcategory_id = 0 and up.answered >= 10
        order by up.correct::numeric / up.answered desc, up.answered desc limit 1) b),
    'worst_category', (select row_to_json(w) from (
        select up.category_id, c.name, round(up.correct::numeric / up.answered, 3) as accuracy
        from public.user_progress up join public.categories c on c.id = up.category_id
        where up.user_id = v_user and up.subcategory_id = 0 and up.answered >= 10
        order by up.correct::numeric / up.answered asc, up.answered desc limit 1) w),
    'daily', (select jsonb_agg(row_to_json(d) order by d.day) from (
        select gs::date as day,
               count(ua.id) as answered,
               count(ua.id) filter (where ua.is_correct) as correct,
               coalesce((select sum(qa.xp_awarded) from public.quiz_attempts qa where qa.user_id = v_user
                          and (qa.finished_at at time zone 'Europe/Warsaw')::date = gs::date), 0) as xp
        from generate_series(v_today - 59, v_today, interval '1 day') gs
        left join public.user_answers ua on ua.user_id = v_user and (ua.answered_at at time zone 'Europe/Warsaw')::date = gs::date
        group by gs) d),
    'seasons', (select coalesce(jsonb_agg(row_to_json(s) order by s.season_id desc), '[]') from (
        select sr.*, se.name from public.season_results sr join public.seasons se on se.id = sr.season_id
        where sr.user_id = v_user) s),
    'reviews', jsonb_build_object(
        'due', (select count(*) from public.review_queue where user_id = v_user and stage < 4 and due_at <= now()),
        'scheduled', (select count(*) from public.review_queue where user_id = v_user and stage < 4),
        'mastered', (select count(*) from public.review_queue where user_id = v_user and stage = 4),
        'next_due_at', (select min(due_at) from public.review_queue where user_id = v_user and stage < 4))
  );
end $$;

-- ---------------------------------------------------------------------
-- Misje z bieżącym postępem
-- ---------------------------------------------------------------------
create or replace function public.get_missions()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'code', m.code, 'period', m.period, 'title', m.title, 'description', m.description,
      'icon', m.icon, 'target', m.target, 'xp_reward', m.xp_reward, 'lp_reward', m.lp_reward,
      'progress', coalesce(um.progress, case when m.period = 'special' then least(public.qv_metric(auth.uid(), m.metric), m.target) else 0 end),
      'completed_at', um.completed_at,
      'resets_at', case m.period when 'daily' then ((public.qv_today() + 1)::timestamp at time zone 'Europe/Warsaw')
                                 when 'weekly' then public.qv_week_end(public.qv_week_start()) end
    ) order by m.period, m.id), '[]')
  from public.missions m
  left join public.user_missions um on um.mission_id = m.id and um.user_id = auth.uid()
       and um.period_key = public.qv_period_key(m.period)
  where m.active
$$;

-- ---------------------------------------------------------------------
-- Drzewko wiedzy kategorii
-- ---------------------------------------------------------------------
create or replace function public.get_knowledge_tree(p_category smallint)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'slug', s.slug, 'name', s.name, 'description', s.description,
      'parent_id', s.tree_parent_id, 'unlock_correct', s.unlock_correct,
      'unlocked', public.qv_subcategory_unlocked(auth.uid(), s.id),
      'parent_correct', coalesce((select up.correct from public.user_progress up where up.user_id = auth.uid()
                                  and up.category_id = s.category_id and up.subcategory_id = s.tree_parent_id), 0),
      'answered', coalesce(up.answered, 0), 'correct', coalesce(up.correct, 0),
      'questions', (select count(*) from public.questions q where q.subcategory_id = s.id and q.status = 'approved')
    ) order by s.sort_order, s.id), '[]')
  from public.subcategories s
  left join public.user_progress up on up.user_id = auth.uid() and up.category_id = s.category_id and up.subcategory_id = s.id
  where s.category_id = p_category
$$;

-- Katalog kategorii z liczbą pytań i moim postępem
create or replace function public.get_categories()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'slug', c.slug, 'name', c.name, 'icon', c.icon, 'color_hex', c.color_hex, 'description', c.description,
      'questions', (select count(*) from public.questions q where q.category_id = c.id and q.status = 'approved'),
      'answered', coalesce(up.answered, 0), 'correct', coalesce(up.correct, 0),
      'subcategories', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name,
                              'parent_id', s.tree_parent_id, 'unlock_correct', s.unlock_correct) order by s.sort_order), '[]')
                        from public.subcategories s where s.category_id = c.id)
    ) order by c.sort_order), '[]')
  from public.categories c
  left join public.user_progress up on up.user_id = auth.uid() and up.category_id = c.id and up.subcategory_id = 0
$$;

-- ---------------------------------------------------------------------
-- Podgląd odpowiedzi po zakończeniu quizu (dopiero wtedy!)
-- ---------------------------------------------------------------------
create or replace function public.get_attempt_review(p_attempt uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.quiz_attempts;
begin
  select * into a from public.quiz_attempts where id = p_attempt and user_id = auth.uid();
  if not found then raise exception 'attempt_not_found'; end if;
  if a.status = 'in_progress' then raise exception 'attempt_in_progress'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'question_id', q.id, 'prompt', q.prompt, 'explanation', q.explanation,
            'your_answer_id', ua.answer_id, 'is_correct', ua.is_correct, 'time_ms', ua.time_ms,
            'answers', (select jsonb_agg(jsonb_build_object('id', an.id, 'body', an.body, 'is_correct', an.is_correct) order by an.position)
                        from public.answers an where an.question_id = q.id),
            'article_slug', ka.slug) order by ua.answered_at), '[]')
          from public.user_answers ua
          join public.questions q on q.id = ua.question_id
          left join public.knowledge_articles ka on ka.id = q.article_id
          where ua.attempt_id = p_attempt);
end $$;

-- ---------------------------------------------------------------------
-- Dane dla Mentora AI (analiza wyników)
-- ---------------------------------------------------------------------
create or replace function public.get_mentor_context()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'player', public.get_player(),
    'stats', public.get_my_stats() - 'daily',
    'recent_mistakes', (select coalesce(jsonb_agg(row_to_json(m)), '[]') from (
        select q.prompt, c.name as category, s.name as subcategory, q.explanation,
               (select body from public.answers where question_id = q.id and is_correct) as correct_answer,
               (select body from public.answers where id = ua.answer_id) as given_answer
        from public.user_answers ua join public.questions q on q.id = ua.question_id
        join public.categories c on c.id = q.category_id left join public.subcategories s on s.id = q.subcategory_id
        join public.quiz_attempts qa on qa.id = ua.attempt_id and qa.status <> 'in_progress'
        where ua.user_id = auth.uid() and not ua.is_correct
        order by ua.answered_at desc limit 12) m),
    'weak_subcategories', (select coalesce(jsonb_agg(row_to_json(w)), '[]') from (
        select c.name as category, s.name as subcategory, up.answered, up.correct,
               round(up.correct::numeric / greatest(up.answered, 1), 2) as accuracy, s.id as subcategory_id, c.id as category_id
        from public.user_progress up join public.subcategories s on s.id = up.subcategory_id
        join public.categories c on c.id = up.category_id
        where up.user_id = auth.uid() and up.subcategory_id <> 0 and up.answered >= 3
        order by up.correct::numeric / greatest(up.answered, 1) asc limit 5) w)
  )
$$;

-- ---------------------------------------------------------------------
-- Encyklopedia: ulubione
-- ---------------------------------------------------------------------
create or replace function public.toggle_favorite_article(p_article int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from public.user_favorite_articles where user_id = auth.uid() and article_id = p_article;
  if found then return false; end if;
  insert into public.user_favorite_articles(user_id, article_id) values (auth.uid(), p_article);
  perform public.qv_check_achievements(auth.uid());
  return true;
end $$;

-- ---------------------------------------------------------------------
-- Powiadomienia i urządzenia
-- ---------------------------------------------------------------------
create or replace function public.register_device_token(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_token !~ '^[0-9a-fA-F]{64,200}$' then raise exception 'invalid_token'; end if;
  insert into public.device_tokens(user_id, token) values (auth.uid(), p_token)
    on conflict (token) do update set user_id = excluded.user_id;
end $$;

create or replace function public.mark_notifications_read()
returns void language sql security definer set search_path = public as $$
  update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null
$$;

-- ---------------------------------------------------------------------
-- Usunięcie konta (RODO) – kaskadowo usuwa wszystkie dane gracza
-- ---------------------------------------------------------------------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not_authenticated'; end if;
  -- zwolnij miejsce w grupie ligowej bieżącego tygodnia
  update public.league_groups g set size = size - 1
    from public.league_members lm where lm.group_id = g.id and lm.user_id = v_user and g.settled_at is null;
  delete from auth.users where id = v_user;
end $$;

-- ---------------------------------------------------------------------
-- Panel administratora: weryfikacja pytań i zgłoszeń
-- ---------------------------------------------------------------------
create or replace function public.admin_review_question(p_question uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.questions set
    status = case when p_approve then 'approved'::public.question_status else 'rejected'::public.question_status end,
    reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_question;
  update public.question_reports set status = case when p_approve then 'rejected'::public.report_status else 'accepted'::public.report_status end,
    resolved_by = auth.uid()
    where question_id = p_question and status = 'open';
end $$;

create or replace function public.admin_review_queue(p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (select coalesce(jsonb_agg(row_to_json(t)), '[]') from (
    select q.id, q.prompt, q.explanation, q.difficulty, q.source, q.status, q.quality_score, q.sources,
           c.name as category, s.name as subcategory,
           (select jsonb_agg(jsonb_build_object('body', a.body, 'is_correct', a.is_correct) order by a.position)
              from public.answers a where a.question_id = q.id) as answers,
           (select jsonb_agg(jsonb_build_object('reason', r.reason, 'comment', r.comment))
              from public.question_reports r where r.question_id = q.id and r.status = 'open') as reports
    from public.questions q join public.categories c on c.id = q.category_id
    left join public.subcategories s on s.id = q.subcategory_id
    where q.status in ('pending_review', 'ai_verified')
    order by (select count(*) from public.question_reports r where r.question_id = q.id and r.status = 'open') desc, q.created_at
    limit least(p_limit, 200)) t);
end $$;
