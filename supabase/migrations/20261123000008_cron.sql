-- 0008: harmonogram rozliczeń (pg_cron). Co godzinę rozliczamy zakończone tygodnie i sezony.
-- Na projektach bez pg_cron rozliczenie wywołuje Edge Function `settle-week` (patrz README).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('quizverse-settle-weeks', '5 * * * *', 'select public.settle_due_weeks()');
    perform cron.schedule('quizverse-daily-quiz', '1 0 * * *', 'select public.ensure_daily_quiz()');
  else
    raise notice 'pg_cron niedostępny – użyj Edge Function settle-week z zewnętrznym harmonogramem';
  end if;
end $$;
