-- Testy bezpieczeństwa jako rola `authenticated` (tak jak klient przez PostgREST).
\set ON_ERROR_STOP 1

select test.new_user('hacker') as hacker \gset
select test.new_user('ofiara') as victim \gset

set role authenticated;
select set_config('request.jwt.claim.sub', :'hacker', false) \g /dev/null

do $$
declare n int; ok boolean;
begin
  -- brak dostępu do odpowiedzi i pytań
  select count(*) into n from public.answers;
  assert n = 0, 'answers visible to non-admin';
  select count(*) into n from public.questions;
  assert n = 0, 'questions visible to non-admin';

  -- funkcje wewnętrzne niedostępne
  begin perform public.qv_grant_xp(auth.uid(), 100000); assert false, 'qv_grant_xp callable';
  exception when insufficient_privilege then null; end;
  begin perform public.qv_add_league_points(auth.uid(), 1000); assert false, 'qv_add_league_points callable';
  exception when insufficient_privilege then null; end;
  begin perform public.settle_due_weeks(); assert false, 'settle callable';
  exception when insufficient_privilege then null; end;

  -- brak bezpośredniego zapisu punktów
  begin update public.users set xp = 999999 where id = auth.uid(); assert false, 'users writable';
  exception when insufficient_privilege then null; end;
  begin insert into public.quiz_attempts(user_id, mode, question_ids, question_count) values (auth.uid(), 'quick', '{}', 0);
    assert false, 'attempts insertable';
  exception when insufficient_privilege then null; end;

  -- cudze dane niewidoczne
  select count(*) into n from public.users;
  assert n = 1, 'sees only own users row';
  select count(*) into n from public.profiles;
  assert n > 1, 'profiles public for rankings';

  -- edycja profilu: dozwolone pola, zablokowana ramka Legendy
  update public.profiles set bio = 'Cześć!' where id = auth.uid();
  begin update public.profiles set frame = 'legend' where id = auth.uid(); assert false, 'locked frame';
  exception when raise_exception then assert sqlerrm = 'frame_locked'; end;
  -- edycja cudzego profilu nie działa (0 wierszy)
  update public.profiles set bio = 'hacked' where id <> auth.uid();
  get diagnostics n = row_count;
  assert n = 0, 'cannot edit others';

  -- admin API zablokowane
  begin perform public.admin_review_queue(); assert false, 'admin api';
  exception when raise_exception then assert sqlerrm = 'forbidden'; end;

  -- RPC gry działa
  perform public.start_quiz('quick');
  raise notice 'test_04_security: OK';
end $$;

-- cudze podejście nie może zostać zakończone
reset role;
select set_config('request.jwt.claim.sub', :'victim', false) \g /dev/null
select (public.start_quiz('quick')->>'attempt_id') as victim_attempt \gset
set role authenticated;
select set_config('request.jwt.claim.sub', :'hacker', false) \g /dev/null
select set_config('qv.va', :'victim_attempt', false) \g /dev/null
do $$
begin
  perform public.finish_quiz(current_setting('qv.va')::uuid);
  assert false, 'finished someone else''s attempt';
exception when raise_exception then
  assert sqlerrm = 'attempt_not_found', sqlerrm;
  raise notice 'test_04_security (ownership): OK';
end $$;

-- usunięcie konta kasuje dane
select set_config('request.jwt.claim.sub', :'victim', false) \g /dev/null
select public.delete_my_account() \g /dev/null
reset role;
do $$ begin
  assert not exists (select 1 from public.profiles where username = 'ofiara'), 'account deleted';
  assert not exists (select 1 from auth.users where email = 'ofiara@test.local'), 'auth user deleted';
  raise notice 'test_04_security (delete account): OK';
end $$;
