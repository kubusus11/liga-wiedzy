-- 0002: funkcje bazowe – czas, sezony, poziomy konta, reguły punktacji.
-- Reguły punktacji są czystymi funkcjami (immutable), więc łatwo je testować.

-- =====================================================================
-- Czas: tydzień ligowy zaczyna się w poniedziałek 00:00 czasu Europe/Warsaw
-- =====================================================================
create or replace function public.qv_week_start(p_ts timestamptz default now())
returns date language sql stable as $$
  select date_trunc('week', p_ts at time zone 'Europe/Warsaw')::date
$$;

create or replace function public.qv_week_end(p_week_start date)
returns timestamptz language sql stable as $$
  select ((p_week_start + 7)::timestamp at time zone 'Europe/Warsaw')
$$;

create or replace function public.qv_today()
returns date language sql stable as $$
  select (now() at time zone 'Europe/Warsaw')::date
$$;

-- =====================================================================
-- Sezony – 8 tygodni, tworzone automatycznie jeden po drugim
-- =====================================================================
create or replace function public.ensure_season(p_ts timestamptz default now())
returns public.seasons
language plpgsql security definer set search_path = public as $$
declare
  s public.seasons;
  v_next_start timestamptz;
  v_next_id int;
begin
  select * into s from public.seasons where starts_at <= p_ts and ends_at > p_ts;
  if found then return s; end if;

  -- pierwszy sezon: poniedziałek 2026-11-23 00:00 Europe/Warsaw
  select coalesce(max(id), 0), coalesce(max(ends_at), ('2026-11-23'::timestamp at time zone 'Europe/Warsaw'))
    into v_next_id, v_next_start from public.seasons;

  if p_ts < v_next_start and v_next_id = 0 then
    -- znacznik przed pierwszym sezonem: przypisz do sezonu 1
    p_ts := v_next_start;
  end if;

  loop
    v_next_id := v_next_id + 1;
    insert into public.seasons(id, name, starts_at, ends_at)
      values (v_next_id, 'Sezon ' || v_next_id, v_next_start, v_next_start + interval '56 days')
      on conflict (id) do nothing;
    v_next_start := v_next_start + interval '56 days';
    exit when v_next_start > p_ts;
  end loop;

  select * into s from public.seasons where starts_at <= p_ts and ends_at > p_ts;
  return s;
end $$;

-- =====================================================================
-- Poziomy konta: 151 poziomów, rosnący próg XP
-- XP potrzebne na przejście z poziomu k na k+1: 100 + 20*(k-1)
-- Łączne XP potrzebne do osiągnięcia poziomu n: 100(n-1) + 10(n-1)(n-2)
-- =====================================================================
create or replace function public.qv_xp_for_level(p_level int)
returns bigint language sql immutable as $$
  select (100 * (greatest(p_level,1) - 1) + 10 * (greatest(p_level,1) - 1) * (greatest(p_level,1) - 2))::bigint
$$;

create or replace function public.qv_level_for_xp(p_xp bigint)
returns int language plpgsql immutable as $$
declare n int := 1;
begin
  while n < 151 and public.qv_xp_for_level(n + 1) <= p_xp loop
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.qv_title_for_level(p_level int)
returns text language sql immutable as $$
  select case
    when p_level <= 10  then 'Nowicjusz'
    when p_level <= 25  then 'Uczeń'
    when p_level <= 40  then 'Odkrywca'
    when p_level <= 60  then 'Badacz'
    when p_level <= 80  then 'Uczony'
    when p_level <= 100 then 'Mędrzec'
    when p_level <= 120 then 'Arcymistrz'
    when p_level <= 140 then 'Geniusz'
    else 'Wszechwiedzący'
  end
$$;

-- =====================================================================
-- Stałe antyfarmingowe
-- =====================================================================
create or replace function public.qv_limits()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'daily_lp_cap',        300,   -- maks. LP z quizów na dzień
    'daily_xp_cap',        3000,  -- maks. XP z quizów na dzień
    'min_lp_accuracy',     0.4,   -- poniżej 40% skuteczności quiz nie daje LP
    'min_avg_answer_ms',   800,   -- szybciej = podejrzenie bota, brak nagród
    'daily_ai_generations', 5,
    'attempt_ttl_hours',   3
  )
$$;

-- =====================================================================
-- Reguły nagród (czysta funkcja)
-- p_mode: tryb, p_count: liczba pytań w zestawie, p_answered/p_correct: wynik,
-- p_difficulty: 1..6, p_completed: czy quiz został ukończony
-- Zwraca {xp, lp, xp_items:[...], lp_items:[...]}
-- =====================================================================
create or replace function public.qv_compute_rewards(
  p_mode public.quiz_mode, p_count int, p_answered int, p_correct int, p_difficulty int, p_completed boolean
) returns jsonb language plpgsql immutable as $$
declare
  xp int := 0; lp int := 0;
  xp_items jsonb := '[]'; lp_items jsonb := '[]';
  acc numeric := case when p_answered > 0 then p_correct::numeric / p_answered else 0 end;
  lp_allowed boolean := acc >= (public.qv_limits()->>'min_lp_accuracy')::numeric;
  v int;
begin
  -- XP za poprawne odpowiedzi
  if p_correct > 0 then
    xp := xp + 5 * p_correct;
    xp_items := xp_items || jsonb_build_object('key', 'correct', 'label', 'Poprawne odpowiedzi', 'value', 5 * p_correct);
  end if;

  if p_completed and p_answered > 0 then
    xp := xp + 15;
    xp_items := xp_items || jsonb_build_object('key', 'completed', 'label', 'Ukończenie quizu', 'value', 15);

    if p_mode not in ('survival', 'sprint') and p_count >= 5 and p_correct = p_count then
      xp := xp + 20;
      xp_items := xp_items || jsonb_build_object('key', 'perfect', 'label', 'Komplet poprawnych', 'value', 20);
    end if;

    if coalesce(p_difficulty, 0) >= 5 and acc >= 0.5 and p_mode <> 'review' then
      xp := xp + 30;
      xp_items := xp_items || jsonb_build_object('key', 'expert', 'label', 'Quiz ekspercki', 'value', 30);
    end if;

    if p_mode = 'daily' then
      xp := xp + 25;
      xp_items := xp_items || jsonb_build_object('key', 'daily', 'label', 'Quiz dnia', 'value', 25);
    end if;
  end if;

  -- LP (punkty ligowe) – nigdy nie wynikają z XP
  if lp_allowed then
    if p_mode = 'daily' and p_completed then
      lp := 25;
      lp_items := lp_items || jsonb_build_object('key', 'daily', 'label', 'Quiz dnia', 'value', 25);
    elsif p_mode = 'marathon' then
      v := (p_answered / 5) * 10;                     -- 10 LP za każde 5 pytań
      if v > 0 then
        lp := v;
        lp_items := lp_items || jsonb_build_object('key', 'marathon', 'label', 'Maraton (10 LP / 5 pytań)', 'value', v);
      end if;
    elsif p_mode in ('survival', 'sprint') then
      v := least((p_correct / 5) * 10, 60);           -- 10 LP za każde 5 poprawnych, maks. 60
      if v > 0 then
        lp := v;
        lp_items := lp_items || jsonb_build_object('key', p_mode::text, 'label', case when p_mode = 'survival' then 'Przetrwanie' else 'Sprint' end, 'value', v);
      end if;
    elsif p_mode in ('quick', 'thematic', 'detective') and p_completed then
      v := case when p_count >= 20 then 40 when p_count >= 10 then 20 when p_count >= 5 then 10 else 0 end;
      if v > 0 then
        lp := v;
        lp_items := lp_items || jsonb_build_object('key', 'quiz', 'label', 'Quiz ' || p_count || ' pytań', 'value', v);
      end if;
    end if;
    -- 'review' i 'ai' (pytania jeszcze nie zatwierdzone przez redakcję) nie dają LP
  end if;

  return jsonb_build_object('xp', xp, 'lp', lp, 'xp_items', xp_items, 'lp_items', lp_items,
                            'accuracy', round(acc, 4), 'lp_blocked_low_accuracy', not lp_allowed and p_answered > 0);
end $$;

-- =====================================================================
-- Role
-- =====================================================================
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.users where id = auth.uid() and role in ('admin', 'moderator'))
$$;

-- =====================================================================
-- Nowe konto: rekord users + profiles (trigger na auth.users)
-- =====================================================================
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_username text := nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'username', ''), '[^A-Za-z0-9_.]', '', 'g'), '');
begin
  if v_username is null or char_length(v_username) < 3 or exists (select 1 from public.profiles where lower(username) = lower(v_username)) then
    v_username := 'gracz_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  v_username := left(v_username, 20);
  insert into public.users(id) values (new.id) on conflict do nothing;
  insert into public.profiles(id, username, display_name)
    values (new.id, v_username, coalesce(new.raw_user_meta_data->>'display_name', v_username))
    on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
