-- 0007: bezpieczeństwo – RLS, uprawnienia do tabel i funkcji, walidacja personalizacji.
-- Zasada: klient czyta tylko swoje dane (+ publiczne katalogi i rankingi),
-- a wszystkie zapisy wpływające na punkty przechodzą przez funkcje RPC.

-- ---------------------------------------------------------------------
-- Personalizacja profilu: ramki, tła i tytuły trzeba odblokować
-- ---------------------------------------------------------------------
create or replace function public.qv_cosmetic_unlocked(p_user uuid, p_kind text, p_code text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare u public.users;
begin
  select * into u from public.users where id = p_user;
  if p_kind = 'frame' then
    return case p_code
      when 'none' then true
      when 'bronze' then true
      when 'silver' then u.highest_league_id >= 2
      when 'gold' then u.highest_league_id >= 3
      when 'platinum' then u.highest_league_id >= 4
      when 'legend' then u.highest_league_id >= 5
      when 'orbit' then u.level >= 10
      when 'supernova' then u.level >= 50
      when 'singularity' then u.level >= 100
      else false end;
  elsif p_kind = 'background' then
    return case p_code
      when 'nebula' then true
      when 'galaxy' then u.level >= 5
      when 'aurora' then u.level >= 20
      when 'blackhole' then u.level >= 40
      when 'goldendust' then u.highest_league_id >= 3
      when 'legendvoid' then u.highest_league_id >= 5
      else false end;
  elsif p_kind = 'title' then
    return p_code in (
      select public.qv_title_for_level(l) from generate_series(1, u.level) l
    );
  end if;
  return false;
end $$;

create or replace function public.qv_profiles_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.frame is distinct from old.frame and not public.qv_cosmetic_unlocked(new.id, 'frame', new.frame) then
    raise exception 'frame_locked';
  end if;
  if new.background is distinct from old.background and not public.qv_cosmetic_unlocked(new.id, 'background', new.background) then
    raise exception 'background_locked';
  end if;
  if new.selected_title is not null and new.selected_title is distinct from old.selected_title
     and not public.qv_cosmetic_unlocked(new.id, 'title', new.selected_title) then
    raise exception 'title_locked';
  end if;
  if new.avatar_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'invalid_color'; end if;
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_guard before update on public.profiles
  for each row execute function public.qv_profiles_guard();

-- ---------------------------------------------------------------------
-- RLS na wszystkich tabelach
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Katalogi (publiczne do odczytu)
grant select on public.leagues, public.categories, public.subcategories to anon, authenticated;
grant select on public.achievements, public.missions, public.collectible_cards, public.knowledge_articles, public.seasons to authenticated;

create policy leagues_read on public.leagues for select using (true);
create policy categories_read on public.categories for select using (true);
create policy subcategories_read on public.subcategories for select using (true);
create policy achievements_read on public.achievements for select to authenticated using (not is_hidden or exists (
  select 1 from public.user_achievements ua where ua.achievement_id = achievements.id and ua.user_id = auth.uid()));
create policy missions_read on public.missions for select to authenticated using (active);
create policy cards_read on public.collectible_cards for select to authenticated using (true);
create policy articles_read on public.knowledge_articles for select to authenticated using (true);
create policy seasons_read on public.seasons for select to authenticated using (true);

-- Własne konto
grant select on public.users to authenticated;
create policy users_self on public.users for select to authenticated using (id = auth.uid());

-- Profile: publiczne (rankingi), edycja tylko własnego i tylko wybranych kolumn
grant select on public.profiles to authenticated;
grant update (username, display_name, avatar, avatar_color, frame, background, selected_title, bio, notifications)
  on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Dane gracza (tylko odczyt własnych; zapis wyłącznie przez RPC)
grant select on public.quiz_attempts, public.user_answers, public.user_progress, public.review_queue,
               public.user_missions, public.user_achievements, public.user_cards, public.league_results,
               public.season_results, public.point_events, public.daily_reward_ledger, public.mentor_messages,
               public.question_reports, public.user_favorite_articles, public.notifications
  to authenticated;
create policy own_attempts on public.quiz_attempts for select to authenticated using (user_id = auth.uid());
create policy own_answers on public.user_answers for select to authenticated using (user_id = auth.uid());
create policy own_progress on public.user_progress for select to authenticated using (user_id = auth.uid());
create policy own_reviews on public.review_queue for select to authenticated using (user_id = auth.uid());
create policy own_missions on public.user_missions for select to authenticated using (user_id = auth.uid());
create policy own_achievements on public.user_achievements for select to authenticated using (user_id = auth.uid());
create policy own_cards on public.user_cards for select to authenticated using (user_id = auth.uid());
create policy own_league_results on public.league_results for select to authenticated using (user_id = auth.uid());
create policy own_season_results on public.season_results for select to authenticated using (user_id = auth.uid());
create policy own_point_events on public.point_events for select to authenticated using (user_id = auth.uid());
create policy own_ledger on public.daily_reward_ledger for select to authenticated using (user_id = auth.uid());
create policy own_mentor on public.mentor_messages for select to authenticated using (user_id = auth.uid());
create policy own_reports on public.question_reports for select to authenticated using (user_id = auth.uid());
create policy own_favorites on public.user_favorite_articles for select to authenticated using (user_id = auth.uid());
create policy own_notifications on public.notifications for select to authenticated using (user_id = auth.uid());

-- Ligi: składy grup są publiczne (ranking na żywo)
grant select on public.league_groups, public.league_members to authenticated;
create policy groups_read on public.league_groups for select to authenticated using (true);
create policy members_read on public.league_members for select to authenticated using (true);

-- Pytania i odpowiedzi: brak bezpośredniego dostępu dla graczy (tylko przez RPC),
-- pełny dostęp dla administratorów/moderatorów.
grant select, insert, update, delete on public.questions, public.answers, public.question_reports to authenticated;
grant select on public.ai_generation_jobs to authenticated;
create policy questions_admin on public.questions for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy answers_admin on public.answers for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy reports_admin on public.question_reports for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy ai_jobs_admin on public.ai_generation_jobs for select to authenticated using (public.is_admin());

-- quizzes, device_tokens: bez polityk = brak dostępu z klienta

-- ---------------------------------------------------------------------
-- Funkcje: domyślnie nikt z zewnątrz nie może ich wywołać...
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ...poza API aplikacji
grant execute on function
  public.start_quiz(public.quiz_mode, smallint, int, int, int, int),
  public.submit_answer(uuid, uuid, uuid, int),
  public.finish_quiz(uuid),
  public.report_question(uuid, text, text),
  public.get_player(uuid),
  public.get_league_overview(),
  public.get_leaderboard(text, smallint, int),
  public.get_my_stats(),
  public.get_missions(),
  public.get_knowledge_tree(smallint),
  public.get_categories(),
  public.get_attempt_review(uuid),
  public.get_mentor_context(),
  public.toggle_favorite_article(int),
  public.register_device_token(text),
  public.mark_notifications_read(),
  public.delete_my_account(),
  public.admin_review_question(uuid, boolean, text),
  public.admin_review_queue(int),
  public.is_admin(),
  public.qv_xp_for_level(int),
  public.qv_level_for_xp(bigint),
  public.qv_title_for_level(int),
  public.qv_limits()
to authenticated;

-- funkcje pomocnicze używane w politykach / wyrażeniach
grant execute on function public.qv_week_start(timestamptz), public.qv_week_end(date), public.qv_today() to authenticated;

-- rozliczenia: tylko rola serwisowa (Edge Function / pg_cron)
grant execute on function public.settle_due_weeks(), public.settle_season(int), public.ensure_season(timestamptz),
  public.ensure_daily_quiz(date) to service_role;
grant execute on all functions in schema public to service_role;
