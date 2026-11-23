-- Testy lig: grupy po 30, awanse/spadki, wyjątki Brąz/Legenda, sezon.
\set ON_ERROR_STOP 1

create or replace function test.fill_group(p_prefix text, p_league smallint, p_n int)
returns bigint language plpgsql as $$
declare i int; u uuid; g bigint;
begin
  for i in 1..p_n loop
    u := test.new_user(p_prefix || i);
    update public.users set league_id = p_league, highest_league_id = p_league where id = u;
    -- gracz i zdobywa (p_n - i + 1) * 10 LP → miejsce i w grupie
    perform public.qv_add_league_points(u, (p_n - i + 1) * 10);
    select group_id into g from public.league_members where user_id = u;
  end loop;
  return g;
end $$;

-- cofnij grupę o tydzień, by „zakończyć” bieżący tydzień
create or replace function test.age_week(p_group bigint) returns void language sql as $$
  update public.league_groups set week_start = week_start - 7 where id = p_group;
  update public.league_members set week_start = week_start - 7 where group_id = p_group;
$$;

do $$
declare
  g_silver bigint; g_bronze bigint; g_legend bigint; g_extra bigint;
  r jsonb;
begin
  -- izolacja: rozlicz grupy z wcześniejszych testów
  update public.league_groups set week_start = week_start - 14;
  update public.league_members set week_start = week_start - 14;
  perform public.settle_due_weeks();

  -- 31 graczy w Srebrze → dwie grupy (30 + 1)
  g_silver := test.fill_group('srebro', 2::smallint, 30);
  assert (select size from public.league_groups where id = g_silver) = 30, 'group of 30';
  g_extra := test.fill_group('srebro_extra', 2::smallint, 1);
  assert g_extra <> g_silver, '31st player goes to a new group';

  g_bronze := test.fill_group('braz', 1::smallint, 30);
  g_legend := test.fill_group('legenda', 5::smallint, 30);

  -- tydzień trwa: nic nie jest rozliczane
  r := public.settle_due_weeks();
  assert (r->>'groups')::int = 0, 'nothing to settle mid-week';

  perform test.age_week(g_silver);
  perform test.age_week(g_bronze);
  perform test.age_week(g_legend);
  r := public.settle_due_weeks();
  assert (r->>'groups')::int = 3 and (r->>'players')::int = 90, 'settled 3 groups: ' || r::text;

  -- Srebro: 10 awansów, 13 utrzymań, 7 spadków
  assert (select count(*) from public.league_results where group_id = g_silver and outcome = 'promoted' and new_league_id = 3) = 10, 'silver promotions';
  assert (select count(*) from public.league_results where group_id = g_silver and outcome = 'stayed') = 13, 'silver stays';
  assert (select count(*) from public.league_results where group_id = g_silver and outcome = 'relegated' and new_league_id = 1) = 7, 'silver relegations';
  assert (select rank from public.league_results lr join public.profiles p on p.id = lr.user_id where p.username = 'srebro1') = 1, 'rank by LP';
  assert (select league_id from public.users u join public.profiles p on p.id = u.id where p.username = 'srebro1') = 3, 'user promoted to gold';
  assert (select league_id from public.users u join public.profiles p on p.id = u.id where p.username = 'srebro30') = 1, 'user relegated to bronze';

  -- Brąz: miejsca awansowe = awans, miejsca spadkowe = utrzymanie
  assert (select count(*) from public.league_results where group_id = g_bronze and outcome = 'promoted') = 10, 'bronze promotions';
  assert (select count(*) from public.league_results where group_id = g_bronze and outcome = 'relegated') = 0, 'bronze never relegates';

  -- Legenda: brak awansu, spadek 24–30
  assert (select count(*) from public.league_results where group_id = g_legend and outcome = 'promoted') = 0, 'legend never promotes';
  assert (select count(*) from public.league_results where group_id = g_legend and outcome = 'relegated' and new_league_id = 4) = 7, 'legend relegations';
  assert (select legend_weeks_streak from public.users u join public.profiles p on p.id = u.id where p.username = 'legenda1') = 1, 'legend week streak';

  -- Rozliczenie jest jednorazowe
  r := public.settle_due_weeks();
  assert (r->>'groups')::int = 0, 'idempotent settlement';

  -- Powiadomienia i osiągnięcia ligowe
  assert exists (select 1 from public.notifications n join public.profiles p on p.id = n.user_id
                 where p.username = 'srebro1' and n.kind = 'league_result' and n.title like 'Awans%'), 'promotion notification';
  assert exists (select 1 from public.user_achievements ua join public.achievements a on a.id = ua.achievement_id
                 join public.profiles p on p.id = ua.user_id where p.username = 'srebro1' and a.code = 'gold_league'), 'gold league achievement';
  assert exists (select 1 from public.user_achievements ua join public.achievements a on a.id = ua.achievement_id
                 join public.profiles p on p.id = ua.user_id where p.username = 'srebro1' and a.code = 'week_winner'), 'week winner achievement';

  -- Nowy tydzień: każdy zaczyna od 0 LP (nowa grupa)
  perform public.qv_add_league_points((select id from public.profiles where username = 'srebro1'), 10);
  assert (select lp from public.league_members lm join public.profiles p on p.id = lm.user_id
          where p.username = 'srebro1' and lm.week_start = public.qv_week_start()) = 10, 'fresh week starts at 0';
  assert (select g.league_id from public.league_members lm join public.league_groups g on g.id = lm.group_id
          join public.profiles p on p.id = lm.user_id where p.username = 'srebro1' and lm.week_start = public.qv_week_start()) = 3,
         'new group in the new league';

  raise notice 'test_03_leagues: OK';
end $$;

-- Rozliczenie sezonu
do $$
declare s int; r jsonb;
begin
  select id into s from public.seasons order by id limit 1;
  -- przesuwamy sezon w przeszłość
  update public.seasons set starts_at = starts_at - interval '70 days', ends_at = ends_at - interval '70 days' where id = s;
  r := public.settle_due_weeks();
  assert (r->>'seasons')::int = 1, 'season settled ' || r::text;
  assert (select count(*) from public.season_results where season_id = s) >= 90, 'season results written';
  assert (select reward_badge from public.season_results sr join public.profiles p on p.id = sr.user_id
          where p.username = 'srebro1' and season_id = s) = 'season_' || s || '_platinum',
         'season badge by highest league (srebro1: srebro → złoto → platyna po domknięciu ostatniego tygodnia)';
  assert (select highest_league_id from public.users u join public.profiles p on p.id = u.id where p.username = 'srebro1') = 4,
         'XP, level and history are kept after the season';
  assert exists (select 1 from public.seasons where starts_at <= now() and ends_at > now()), 'current season exists';
  raise notice 'test_03_leagues (season): OK';
end $$;
