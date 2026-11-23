-- QUIZVERSE – Universe of Knowledge
-- 0001: schemat relacyjny
-- Wszystkie punkty (XP/LP) nalicza serwer (patrz 0002_game_logic.sql).

create extension if not exists pgcrypto;

-- =====================================================================
-- Typy
-- =====================================================================
create type public.user_role        as enum ('user', 'moderator', 'admin');
create type public.question_status  as enum ('draft', 'pending_review', 'ai_verified', 'approved', 'rejected', 'retired');
create type public.question_source  as enum ('manual', 'ai');
create type public.question_kind    as enum ('standard', 'detective');
create type public.quiz_mode        as enum ('daily', 'quick', 'marathon', 'survival', 'sprint', 'thematic', 'detective', 'review', 'ai');
create type public.attempt_status   as enum ('in_progress', 'finished', 'abandoned', 'flagged');
create type public.mission_period   as enum ('daily', 'weekly', 'special');
create type public.rarity           as enum ('common', 'rare', 'epic', 'legendary');
create type public.badge_tier       as enum ('bronze', 'silver', 'gold', 'platinum');
create type public.league_outcome   as enum ('promoted', 'stayed', 'relegated');
create type public.card_kind        as enum ('person', 'event', 'invention', 'discovery', 'artwork', 'place', 'concept');
create type public.report_status    as enum ('open', 'accepted', 'rejected');

-- =====================================================================
-- Ligi (dokładnie pięć – wymuszone CHECK)
-- =====================================================================
create table public.leagues (
  id           smallint primary key check (id between 1 and 5),
  code         text not null unique,
  name         text not null,
  roman        text not null,
  color_hex    text not null,
  emblem       text not null,           -- nazwa symbolu SF / grafiki
  description  text not null
);

-- =====================================================================
-- Użytkownicy i profile
-- =====================================================================
create table public.users (
  id                    uuid primary key references auth.users(id) on delete cascade,
  role                  public.user_role not null default 'user',
  xp                    bigint  not null default 0 check (xp >= 0),
  level                 int     not null default 1 check (level between 1 and 151),
  league_id             smallint not null default 1 references public.leagues(id),
  highest_league_id     smallint not null default 1 references public.leagues(id),
  legend_weeks_streak   int not null default 0,
  current_streak        int not null default 0,     -- dni z rzędu z ukończonym quizem
  best_streak           int not null default 0,
  last_active_date      date,
  current_answer_streak int not null default 0,     -- poprawne odpowiedzi z rzędu
  best_answer_streak    int not null default 0,
  timezone              text not null default 'Europe/Warsaw',
  created_at            timestamptz not null default now()
);

create table public.profiles (
  id             uuid primary key references public.users(id) on delete cascade,
  username       text not null unique check (username ~ '^[A-Za-z0-9_.]{3,20}$'),
  display_name   text,
  avatar         text not null default 'atom',          -- symbol avatara
  avatar_color   text not null default '#8B5CF6',
  frame          text not null default 'none',
  background     text not null default 'nebula',
  selected_title text,
  bio            text check (char_length(bio) <= 160),
  notifications  jsonb not null default '{"league": true, "missions": true, "reviews": true, "daily": true}',
  updated_at     timestamptz not null default now()
);

create table public.device_tokens (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.users(id) on delete cascade,
  token      text not null unique,
  platform   text not null default 'ios',
  created_at timestamptz not null default now()
);

create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.users(id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text not null,
  payload    jsonb not null default '{}',
  read_at    timestamptz,
  pushed_at  timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications(user_id, created_at desc);

-- =====================================================================
-- Kategorie, podkategorie (podkategorie tworzą drzewko wiedzy)
-- =====================================================================
create table public.categories (
  id          smallint primary key,
  slug        text not null unique,
  name        text not null,
  icon        text not null,
  color_hex   text not null,
  description text not null,
  sort_order  int not null default 0
);

create table public.subcategories (
  id              int primary key,
  category_id     smallint not null references public.categories(id) on delete cascade,
  slug            text not null,
  name            text not null,
  description     text not null default '',
  tree_parent_id  int references public.subcategories(id),
  unlock_correct  int not null default 0,   -- poprawnych odpowiedzi w gałęzi nadrzędnej, by odblokować
  sort_order      int not null default 0,
  unique (category_id, slug)
);
create index subcategories_category_idx on public.subcategories(category_id);

-- =====================================================================
-- Encyklopedia
-- =====================================================================
create table public.knowledge_articles (
  id              int generated always as identity primary key,
  slug            text not null unique,
  category_id     smallint not null references public.categories(id),
  subcategory_id  int references public.subcategories(id),
  title           text not null,
  summary         text not null,
  body            text not null,
  key_facts       jsonb not null default '[]',   -- ["...", ...]
  dates           jsonb not null default '[]',   -- [{"date": "...", "label": "..."}]
  terms           jsonb not null default '[]',   -- [{"term": "...", "definition": "..."}]
  related_slugs   text[] not null default '{}',
  sources         jsonb not null default '[]',   -- [{"title": "...", "url": "..."}]
  created_at      timestamptz not null default now()
);
create index knowledge_articles_category_idx on public.knowledge_articles(category_id);

create table public.user_favorite_articles (
  user_id    uuid not null references public.users(id) on delete cascade,
  article_id int  not null references public.knowledge_articles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

-- =====================================================================
-- Pytania i odpowiedzi
-- =====================================================================
create table public.questions (
  id              uuid primary key default gen_random_uuid(),
  category_id     smallint not null references public.categories(id),
  subcategory_id  int references public.subcategories(id),
  difficulty      smallint not null check (difficulty between 1 and 6),
  kind            public.question_kind not null default 'standard',
  prompt          text not null check (char_length(prompt) between 5 and 600),
  clues           jsonb,                       -- tryb detektywa: lista wskazówek
  explanation     text not null,
  article_id      int references public.knowledge_articles(id),
  source          public.question_source not null default 'manual',
  sources         jsonb not null default '[]',
  status          public.question_status not null default 'draft',
  quality_score   numeric(4,3),
  content_hash    text not null unique,        -- deduplikacja (buforowanie AI)
  created_by      uuid references public.users(id) on delete set null,
  reviewed_by     uuid references public.users(id) on delete set null,
  reviewed_at     timestamptz,
  times_answered  int not null default 0,
  times_correct   int not null default 0,
  created_at      timestamptz not null default now()
);
create index questions_pool_idx on public.questions(category_id, subcategory_id, difficulty) where status in ('approved', 'ai_verified');
create index questions_status_idx on public.questions(status);

create table public.answers (
  id           uuid primary key default gen_random_uuid(),
  question_id  uuid not null references public.questions(id) on delete cascade,
  body         text not null check (char_length(body) between 1 and 200),
  is_correct   boolean not null default false,
  position     smallint not null check (position between 0 and 3),
  unique (question_id, position)
);
create unique index answers_one_correct on public.answers(question_id) where is_correct;

create table public.question_reports (
  id           bigint generated always as identity primary key,
  question_id  uuid not null references public.questions(id) on delete cascade,
  user_id      uuid not null references public.users(id) on delete cascade,
  reason       text not null check (reason in ('wrong_answer', 'unclear', 'outdated', 'typo', 'offensive', 'other')),
  comment      text check (char_length(comment) <= 500),
  status       public.report_status not null default 'open',
  resolved_by  uuid references public.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (question_id, user_id)
);

create table public.ai_generation_jobs (
  id              bigint generated always as identity primary key,
  user_id         uuid references public.users(id) on delete set null,
  category_id     smallint not null references public.categories(id),
  subcategory_id  int references public.subcategories(id),
  difficulty      smallint not null,
  requested       int not null,
  reused          int not null default 0,
  generated       int not null default 0,
  accepted        int not null default 0,
  model           text,
  error           text,
  created_at      timestamptz not null default now()
);
create index ai_jobs_user_day_idx on public.ai_generation_jobs(user_id, created_at);

-- =====================================================================
-- Quizy i podejścia
-- =====================================================================
create table public.quizzes (
  id              uuid primary key default gen_random_uuid(),
  mode            public.quiz_mode not null,
  title           text not null,
  category_id     smallint references public.categories(id),
  subcategory_id  int references public.subcategories(id),
  difficulty      smallint,
  question_ids    uuid[] not null,
  quiz_date       date,                         -- quiz dnia
  created_at      timestamptz not null default now()
);
create unique index quizzes_daily_unique on public.quizzes(quiz_date) where mode = 'daily';

create table public.seasons (
  id          int primary key,
  name        text not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  settled_at  timestamptz,
  check (ends_at = starts_at + interval '56 days')     -- 8 tygodni
);

create table public.quiz_attempts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  quiz_id         uuid references public.quizzes(id),
  mode            public.quiz_mode not null,
  category_id     smallint references public.categories(id),
  subcategory_id  int references public.subcategories(id),
  difficulty      smallint,
  question_ids    uuid[] not null,
  question_count  int not null,                -- liczba pytań w zestawie (dla maratonu/przetrwania – pula)
  time_limit_s    int,                         -- sprint
  status          public.attempt_status not null default 'in_progress',
  answered        int not null default 0,
  correct         int not null default 0,
  xp_awarded      int not null default 0,
  lp_awarded      int not null default 0,
  reward_breakdown jsonb not null default '{}',
  season_id       int references public.seasons(id),
  week_start      date,
  started_at      timestamptz not null default now(),
  finished_at     timestamptz
);
create index quiz_attempts_user_idx on public.quiz_attempts(user_id, started_at desc);
create unique index quiz_attempts_daily_once on public.quiz_attempts(user_id, quiz_id) where mode = 'daily';

create table public.user_answers (
  id            bigint generated always as identity primary key,
  attempt_id    uuid not null references public.quiz_attempts(id) on delete cascade,
  user_id       uuid not null references public.users(id) on delete cascade,
  question_id   uuid not null references public.questions(id) on delete cascade,
  answer_id     uuid references public.answers(id) on delete set null,   -- null = brak odpowiedzi (czas)
  is_correct    boolean not null,
  time_ms       int not null check (time_ms >= 0),
  answered_at   timestamptz not null default now(),
  unique (attempt_id, question_id)
);
create index user_answers_user_idx on public.user_answers(user_id, answered_at desc);
create index user_answers_question_idx on public.user_answers(question_id);

-- Postęp w kategoriach / podkategoriach (drzewko wiedzy)
create table public.user_progress (
  user_id         uuid not null references public.users(id) on delete cascade,
  category_id     smallint not null references public.categories(id),
  subcategory_id  int not null default 0,      -- 0 = cała kategoria
  answered        int not null default 0,
  correct         int not null default 0,
  quizzes         int not null default 0,
  xp              int not null default 0,
  unlocked_at     timestamptz,
  updated_at      timestamptz not null default now(),
  primary key (user_id, category_id, subcategory_id)
);

-- Inteligentne powtórki (1 / 3 / 7 / 30 dni)
create table public.review_queue (
  user_id      uuid not null references public.users(id) on delete cascade,
  question_id  uuid not null references public.questions(id) on delete cascade,
  stage        smallint not null default 0 check (stage between 0 and 4),   -- 4 = opanowane
  lapses       int not null default 0,
  due_at       timestamptz not null,
  last_result  boolean,
  updated_at   timestamptz not null default now(),
  primary key (user_id, question_id)
);
create index review_queue_due_idx on public.review_queue(user_id, due_at) where stage < 4;

-- Dzienny licznik nagród (limity antyfarmingowe)
create table public.daily_reward_ledger (
  user_id      uuid not null references public.users(id) on delete cascade,
  day          date not null,
  xp           int not null default 0,
  lp           int not null default 0,
  quizzes      int not null default 0,
  ai_generations int not null default 0,
  primary key (user_id, day)
);

-- Dziennik wszystkich przyznanych punktów (audyt, idempotencja)
create table public.point_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.users(id) on delete cascade,
  kind        text not null,                 -- 'quiz', 'mission', 'achievement', ...
  ref         text not null,                 -- np. id podejścia / kod misji + okres
  xp          int not null default 0,
  lp          int not null default 0,
  created_at  timestamptz not null default now(),
  unique (user_id, kind, ref)
);

-- =====================================================================
-- Ligi tygodniowe
-- =====================================================================
create table public.league_groups (
  id          bigint generated always as identity primary key,
  league_id   smallint not null references public.leagues(id),
  season_id   int not null references public.seasons(id),
  week_start  date not null,
  size        int not null default 0 check (size between 0 and 30),
  settled_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index league_groups_open_idx on public.league_groups(league_id, week_start) where settled_at is null;

create table public.league_members (
  group_id      bigint not null references public.league_groups(id) on delete cascade,
  user_id       uuid not null references public.users(id) on delete cascade,
  week_start    date not null,
  lp            int not null default 0 check (lp >= 0),
  last_lp_at    timestamptz,
  joined_at     timestamptz not null default now(),
  primary key (group_id, user_id),
  unique (user_id, week_start)                -- jedna grupa na tydzień
);
create index league_members_rank_idx on public.league_members(group_id, lp desc, last_lp_at asc);

create table public.league_results (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.users(id) on delete cascade,
  group_id        bigint not null references public.league_groups(id) on delete cascade,
  season_id       int not null references public.seasons(id),
  week_start      date not null,
  league_id       smallint not null references public.leagues(id),
  new_league_id   smallint not null references public.leagues(id),
  rank            int not null check (rank between 1 and 30),
  lp              int not null,
  outcome         public.league_outcome not null,
  created_at      timestamptz not null default now(),
  unique (user_id, week_start)
);
create index league_results_user_idx on public.league_results(user_id, week_start desc);

create table public.season_results (
  user_id            uuid not null references public.users(id) on delete cascade,
  season_id          int not null references public.seasons(id),
  final_league_id    smallint not null references public.leagues(id),
  highest_league_id  smallint not null references public.leagues(id),
  total_lp           int not null default 0,
  promotions         int not null default 0,
  relegations        int not null default 0,
  quizzes            int not null default 0,
  xp_earned          int not null default 0,
  reward_badge       text,
  created_at         timestamptz not null default now(),
  primary key (user_id, season_id)
);

-- =====================================================================
-- Osiągnięcia, misje, karty
-- =====================================================================
create table public.achievements (
  id          int primary key,
  code        text not null unique,
  category    text not null check (category in ('knowledge', 'history', 'geography', 'science', 'regularity', 'leagues', 'perfection', 'exploration', 'season')),
  name        text not null,
  description text not null,
  icon        text not null,
  rarity      public.rarity not null,
  tier        public.badge_tier not null,
  metric      text not null,
  threshold   int not null,
  xp_reward   int not null default 0,
  is_hidden   boolean not null default false
);

create table public.user_achievements (
  user_id        uuid not null references public.users(id) on delete cascade,
  achievement_id int  not null references public.achievements(id),
  unlocked_at    timestamptz not null default now(),
  primary key (user_id, achievement_id)
);

create table public.missions (
  id          int primary key,
  code        text not null unique,
  period      public.mission_period not null,
  title       text not null,
  description text not null,
  icon        text not null,
  metric      text not null,
  param       text,                 -- np. slug kategorii
  target      int not null check (target > 0),
  xp_reward   int not null default 0,
  lp_reward   int not null default 0,
  active      boolean not null default true
);

create table public.user_missions (
  user_id      uuid not null references public.users(id) on delete cascade,
  mission_id   int  not null references public.missions(id),
  period_key   text not null,      -- 'D:2026-11-23', 'W:2026-11-23', 'S'
  progress     int not null default 0,
  completed_at timestamptz,
  claimed_at   timestamptz,
  primary key (user_id, mission_id, period_key)
);

create table public.collectible_cards (
  id           int primary key,
  code         text not null unique,
  name         text not null,
  description  text not null,
  kind         public.card_kind not null,
  category_id  smallint not null references public.categories(id),
  rarity       public.rarity not null,
  art          text not null,      -- symbol SF + gradient po stronie klienta
  era          text
);

create table public.user_cards (
  user_id     uuid not null references public.users(id) on delete cascade,
  card_id     int  not null references public.collectible_cards(id),
  copies      int  not null default 1,
  source      text not null,
  obtained_at timestamptz not null default now(),
  primary key (user_id, card_id)
);

-- Mentor AI – historia rozmów (opcjonalna)
create table public.mentor_messages (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.users(id) on delete cascade,
  role        text not null check (role in ('user', 'mentor')),
  content     text not null,
  created_at  timestamptz not null default now()
);
create index mentor_messages_user_idx on public.mentor_messages(user_id, created_at desc);
