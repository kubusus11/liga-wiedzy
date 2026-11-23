-- 0004: ligi tygodniowe, awanse/spadki, sezony.
-- Dokładnie pięć lig: 1 Brąz, 2 Srebro, 3 Złoto, 4 Platyna, 5 Legenda.
-- Grupa = maks. 30 graczy tej samej ligi w danym tygodniu.
-- Miejsca 1–10 awans, 11–23 utrzymanie, 24–30 spadek (z wyjątkami Brąz/Legenda).

-- ---------------------------------------------------------------------
-- Wynik ligowy wg miejsca (czysta funkcja – testowalna)
-- ---------------------------------------------------------------------
create or replace function public.qv_league_outcome(p_league smallint, p_rank int, p_lp int)
returns public.league_outcome language sql immutable as $$
  select case
    when p_rank <= 10 and p_lp > 0 and p_league < 5 then 'promoted'::public.league_outcome
    when p_rank >= 24 and p_league > 1 then 'relegated'::public.league_outcome
    else 'stayed'::public.league_outcome
  end
$$;

create or replace function public.qv_league_after(p_league smallint, p_outcome public.league_outcome)
returns smallint language sql immutable as $$
  select (case p_outcome
    when 'promoted'  then least(p_league + 1, 5)
    when 'relegated' then greatest(p_league - 1, 1)
    else p_league end)::smallint
$$;

-- ---------------------------------------------------------------------
-- Dołączenie do grupy tygodnia (przy pierwszych LP w tygodniu)
-- ---------------------------------------------------------------------
create or replace function public.qv_ensure_league_membership(p_user uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_week date := public.qv_week_start();
  v_group bigint;
  v_league smallint;
  v_season public.seasons := public.ensure_season();
begin
  select group_id into v_group from public.league_members where user_id = p_user and week_start = v_week;
  if found then return v_group; end if;

  select league_id into v_league from public.users where id = p_user;

  -- serializacja przydziału w obrębie ligi i tygodnia
  perform pg_advisory_xact_lock(hashtext('qv_league_' || v_league || '_' || v_week));

  select id into v_group from public.league_groups
    where league_id = v_league and week_start = v_week and settled_at is null and size < 30
    order by size desc, id
    limit 1 for update;

  if v_group is null then
    insert into public.league_groups(league_id, season_id, week_start)
      values (v_league, v_season.id, v_week) returning id into v_group;
  end if;

  insert into public.league_members(group_id, user_id, week_start) values (v_group, p_user, v_week);
  update public.league_groups set size = size + 1 where id = v_group;
  return v_group;
end $$;

create or replace function public.qv_add_league_points(p_user uuid, p_lp int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_group bigint := public.qv_ensure_league_membership(p_user);
  v_week date := public.qv_week_start();
  v_lp int; v_rank int;
begin
  update public.league_members set lp = lp + p_lp, last_lp_at = now()
    where group_id = v_group and user_id = p_user returning lp into v_lp;
  select r into v_rank from (
    select user_id, row_number() over (order by lp desc, last_lp_at asc nulls last, joined_at asc) r
    from public.league_members where group_id = v_group) t where user_id = p_user;
  return jsonb_build_object('group_id', v_group, 'week_lp', v_lp, 'rank', v_rank, 'week_start', v_week);
end $$;

-- ---------------------------------------------------------------------
-- Rozliczenie jednej grupy
-- ---------------------------------------------------------------------
create or replace function public.qv_settle_group(p_group bigint)
returns int language plpgsql security definer set search_path = public as $$
declare
  g public.league_groups;
  m record;
  v_outcome public.league_outcome;
  v_new smallint;
  v_count int := 0;
  v_names text[] := array['Brąz', 'Srebro', 'Złoto', 'Platyna', 'Legenda'];
begin
  select * into g from public.league_groups where id = p_group for update;
  if g.settled_at is not null then return 0; end if;

  for m in
    select lm.user_id, lm.lp,
           row_number() over (order by lm.lp desc, lm.last_lp_at asc nulls last, lm.joined_at asc)::int as rnk
    from public.league_members lm where lm.group_id = p_group
  loop
    v_outcome := public.qv_league_outcome(g.league_id, m.rnk, m.lp);
    v_new := public.qv_league_after(g.league_id, v_outcome);

    insert into public.league_results(user_id, group_id, season_id, week_start, league_id, new_league_id, rank, lp, outcome)
      values (m.user_id, p_group, g.season_id, g.week_start, g.league_id, v_new, m.rnk, m.lp, v_outcome)
      on conflict (user_id, week_start) do nothing;

    update public.users set
      league_id = v_new,
      highest_league_id = greatest(highest_league_id, v_new),
      legend_weeks_streak = case when g.league_id = 5 and v_new = 5 then legend_weeks_streak + 1 else 0 end
      where id = m.user_id;

    insert into public.notifications(user_id, kind, title, body, payload)
    values (m.user_id, 'league_result',
      case v_outcome when 'promoted' then 'Awans! Witaj w lidze ' || v_names[v_new]
                     when 'relegated' then 'Spadek do ligi ' || v_names[v_new]
                     else 'Utrzymanie w lidze ' || v_names[v_new] end,
      'Tydzień zakończony na ' || m.rnk || '. miejscu z wynikiem ' || m.lp || ' LP.',
      jsonb_build_object('rank', m.rnk, 'lp', m.lp, 'outcome', v_outcome, 'league_id', v_new));

    -- specjalne misje i osiągnięcia ligowe
    perform public.qv_refresh_special_missions(m.user_id);
    perform public.qv_check_achievements(m.user_id);
    v_count := v_count + 1;
  end loop;

  update public.league_groups set settled_at = now() where id = p_group;
  return v_count;
end $$;

-- ---------------------------------------------------------------------
-- Rozliczenie wszystkich zakończonych tygodni (wywoływane z crona)
-- ---------------------------------------------------------------------
create or replace function public.settle_due_weeks()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g record;
  v_groups int := 0; v_players int := 0;
  s record;
  v_seasons int := 0;
begin
  for g in
    select id from public.league_groups
    where settled_at is null and public.qv_week_end(week_start) <= now()
    order by week_start, id
  loop
    v_players := v_players + public.qv_settle_group(g.id);
    v_groups := v_groups + 1;
  end loop;

  for s in select id from public.seasons where settled_at is null and ends_at <= now() order by id loop
    perform public.settle_season(s.id);
    v_seasons := v_seasons + 1;
  end loop;

  perform public.ensure_season();
  return jsonb_build_object('groups', v_groups, 'players', v_players, 'seasons', v_seasons);
end $$;

-- ---------------------------------------------------------------------
-- Rozliczenie sezonu: podsumowanie, nagrody, odznaka sezonowa
-- Gracz zachowuje XP, poziom, osiągnięcia, karty i historię.
-- ---------------------------------------------------------------------
create or replace function public.settle_season(p_season int)
returns int language plpgsql security definer set search_path = public as $$
declare
  s public.seasons;
  r record;
  v_count int := 0;
  v_codes text[] := array['bronze', 'silver', 'gold', 'platinum', 'legend'];
  v_names text[] := array['Brąz', 'Srebro', 'Złoto', 'Platyna', 'Legenda'];
  v_bonus int[] := array[100, 200, 300, 400, 500];
begin
  select * into s from public.seasons where id = p_season for update;
  if s.settled_at is not null then return 0; end if;

  -- najpierw domknij grupy z tego sezonu
  perform public.qv_settle_group(id) from public.league_groups where season_id = p_season and settled_at is null;

  for r in
    select lr.user_id,
           max(greatest(lr.league_id, lr.new_league_id)) as highest,
           (array_agg(lr.new_league_id order by lr.week_start desc))[1] as final_league,
           sum(lr.lp) as total_lp,
           count(*) filter (where lr.outcome = 'promoted') as promos,
           count(*) filter (where lr.outcome = 'relegated') as relegs
    from public.league_results lr where lr.season_id = p_season
    group by lr.user_id
  loop
    insert into public.season_results(user_id, season_id, final_league_id, highest_league_id, total_lp,
                                      promotions, relegations, quizzes, xp_earned, reward_badge)
    values (r.user_id, p_season, r.final_league, r.highest, r.total_lp, r.promos, r.relegs,
            (select count(*) from public.quiz_attempts where user_id = r.user_id and season_id = p_season and status = 'finished'),
            (select coalesce(sum(xp_awarded), 0) from public.quiz_attempts where user_id = r.user_id and season_id = p_season),
            'season_' || p_season || '_' || v_codes[r.highest])
    on conflict do nothing;

    -- nagroda sezonowa: XP wg najwyższej osiągniętej ligi (jednorazowo)
    insert into public.point_events(user_id, kind, ref, xp) values (r.user_id, 'season', p_season::text, v_bonus[r.highest])
      on conflict do nothing;
    if found then
      perform public.qv_grant_xp(r.user_id, v_bonus[r.highest]);
    end if;

    insert into public.notifications(user_id, kind, title, body, payload)
    values (r.user_id, 'season_end', s.name || ' zakończony!',
            'Najwyższa liga: ' || v_names[r.highest] || '. Zdobyte LP: ' || r.total_lp || '. Nagroda: ' || v_bonus[r.highest] || ' XP i odznaka sezonu.',
            jsonb_build_object('season_id', p_season, 'highest_league', r.highest));
    perform public.qv_check_achievements(r.user_id);
    v_count := v_count + 1;
  end loop;

  update public.seasons set settled_at = now() where id = p_season;
  return v_count;
end $$;
