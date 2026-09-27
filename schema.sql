-- ═══════════════════════════════════════════════════════════════
--  네비게이토 암송 Festival — Supabase 테이블
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여 넣고 Run 하세요.
--  두 번 실행해도 안전합니다. 기존 자료는 지워지지 않습니다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 대회 ────────────────────────────────────────────────────
-- 누구나 대회를 만들 수 있습니다. 만들면 6자리 대회코드가 생기고,
-- 참가자는 그 코드로 들어옵니다. 만든 대회는 고치거나 지울 수 없습니다.

create table if not exists public.contests (
  code        text primary key,          -- 6자리 대회코드 (예: K7M2QX)
  title       text not null check (char_length(title) between 1 and 40),
  scoring     text not null default 'grow' check (scoring in ('grow','medal')),
  n           int  not null default 10  check (n between 1 and 60),
  created_at  timestamptz not null default now()
);

alter table public.contests enable row level security;

drop policy if exists "대회 보기" on public.contests;
create policy "대회 보기" on public.contests
  for select to anon, authenticated using (true);

drop policy if exists "대회 만들기" on public.contests;
create policy "대회 만들기" on public.contests
  for insert to anon, authenticated with check (true);

-- 시작 시각. 이 시각 전에는 구절을 뽑을 수 없습니다. (비어 있으면 잠그지 않음)
alter table public.contests add column if not exists starts_at timestamptz;

-- 서버 시각. 폰 시계가 틀려도 시작 시각을 정확히 판단하려고 씁니다.
create or replace function public.server_now() returns timestamptz
  language sql stable set search_path = '' as $$ select now() $$;
revoke all on function public.server_now() from public;
grant execute on function public.server_now() to anon, authenticated;

-- 결과 공개 범위와 호스트.
--   results  : public(모두 공개) · host(호스트만). 호스트는 나중에 바꿀 수 있습니다.
--   host_hash: 호스트 번호(8자리)의 sha256 지문. 번호 자체는 어디에도 저장하지 않습니다.
--              이 칸은 아래 4번에서 읽기 권한을 주지 않아 앱에서도 보이지 않습니다.
--   has_host : 호스트 번호가 있는 대회인지 (예전 대회는 false)
alter table public.contests add column if not exists results   text not null default 'public';
alter table public.contests add column if not exists host_hash text;
alter table public.contests add column if not exists has_host  boolean
  generated always as (host_hash is not null) stored;
do $$ begin
  alter table public.contests add constraint contests_results_check check (results in ('public','host'));
exception when duplicate_object then null; end $$;

-- 호스트 번호가 맞는지 (다른 기기에서 호스트로 들어올 때)
create or replace function public.contest_host_ok(p_code text, p_key text) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.contests c
                  where c.code = p_code and c.host_hash is not null
                    and c.host_hash = encode(sha256(convert_to(coalesce(p_key,''),'UTF8')),'hex'));
$$;
-- 결과 공개 범위 바꾸기 — 호스트 번호가 맞을 때만
create or replace function public.contest_set_results(p_code text, p_key text, p_results text) returns text
  language plpgsql security definer set search_path = '' as $$
begin
  if p_results is null or p_results not in ('public','host') then
    raise exception '공개 범위가 올바르지 않습니다' using errcode = '22023';
  end if;
  update public.contests set results = p_results
   where code = p_code and host_hash is not null
     and host_hash = encode(sha256(convert_to(coalesce(p_key,''),'UTF8')),'hex');
  if not found then
    raise exception '호스트 번호가 맞지 않습니다' using errcode = '42501';
  end if;
  return p_results;
end $$;
revoke all on function public.contest_host_ok(text,text) from public;
revoke all on function public.contest_set_results(text,text,text) from public;
grant execute on function public.contest_host_ok(text,text) to anon, authenticated;
grant execute on function public.contest_set_results(text,text,text) to anon, authenticated;


-- ── 2. 대회 채점 ───────────────────────────────────────────────
-- 로그인 없이 누구나 읽고 씁니다. 대회 현장에서 검사자가 참가자 폰을
-- 받아 바로 채점해야 하기 때문입니다.

create table if not exists public.contest_entries (
  id          text primary key,          -- 대회코드|이름|참가번호
  code        text not null,
  name        text not null,
  num         text not null default '',
  parts       text not null default '',
  total       int  not null default 0,
  graded      int  not null default 0,
  fruit       int  not null default 0,
  flower      int  not null default 0,
  leaf        int  not null default 0,
  sprout      int  not null default 0,
  seed        int  not null default 0,
  score       int  not null default 0,
  updated_at  timestamptz not null default now()
);

create index if not exists contest_entries_code_idx on public.contest_entries (code);

-- 처음 뽑은 구절. 뽑는 순간 무작위로 정해져 여기 저장되고, 그 뒤로는
-- 바꿀 수 없습니다(아래 4번에서 이 칸은 고치기 권한을 주지 않습니다).
alter table public.contest_entries add column if not exists picks jsonb;

-- 금·은·동 채점을 위한 칸 (이미 있는 표에도 안전하게 덧붙습니다)
alter table public.contest_entries add column if not exists scoring text not null default 'harvest';
alter table public.contest_entries add column if not exists gold    int  not null default 0;
alter table public.contest_entries add column if not exists silver  int  not null default 0;
alter table public.contest_entries add column if not exists bronze  int  not null default 0;

-- 네 단계(싹·이삭·곡식·추수) 채점 칸. 앱은 이제 이 칸에 적습니다.
-- 위의 fruit/flower/leaf/sprout/seed 는 옛 5단계 기록을 그대로 두기 위해
-- 남겨 둡니다(앱이 읽을 때 네 단계로 옮겨서 보여 줍니다).
alter table public.contest_entries add column if not exists bud     int  not null default 0;
alter table public.contest_entries add column if not exists ear     int  not null default 0;
alter table public.contest_entries add column if not exists grain   int  not null default 0;
alter table public.contest_entries add column if not exists harvest int  not null default 0;

create table if not exists public.contest_verses (
  id          text primary key,          -- 대회코드|이름|참가번호|주소
  entry_id    text not null,
  code        text not null,
  name        text not null,
  num         text not null default '',
  no          int,
  addr        text not null,
  series      text,
  part        text,
  topic       text,
  part_name   text,
  grade       text,                      -- 씨앗·새싹·잎·꽃·열매 또는 금·은·동
  point       int,
  updated_at  timestamptz not null default now()
);

create index if not exists contest_verses_entry_idx on public.contest_verses (entry_id);
create index if not exists contest_verses_code_idx  on public.contest_verses (code);

alter table public.contest_entries enable row level security;
alter table public.contest_verses  enable row level security;

-- 참가 기록: 보기와 채점 갱신은 누구나, 새로 뽑기(참가 등록)는 그 대회의
-- 시작 시각이 지난 뒤에만. 시각은 서버의 now() 로 판단합니다.
-- 참가 기록 id 는 반드시 「대회코드|」로 시작해야 합니다(다른 대회 이름으로
-- 미리 자리를 잡아 두지 못하게).
drop policy if exists "대회 결과 공개" on public.contest_entries;
drop policy if exists "참가 보기"     on public.contest_entries;
drop policy if exists "참가 등록"     on public.contest_entries;
drop policy if exists "채점 갱신"     on public.contest_entries;
create policy "참가 보기" on public.contest_entries
  for select to anon, authenticated using (true);
create policy "참가 등록" on public.contest_entries
  for insert to anon, authenticated
  with check (
    starts_with(contest_entries.id, contest_entries.code || '|')
    and exists (
      select 1 from public.contests c
       where c.code = contest_entries.code
         and (c.starts_at is null or c.starts_at <= now())));
create policy "채점 갱신" on public.contest_entries
  for update to anon, authenticated using (true) with check (true);

drop policy if exists "대회 구절 공개" on public.contest_verses;
create policy "대회 구절 공개" on public.contest_verses
  for all to anon, authenticated using (true) with check (true);


-- ── 3. 개인 암송 기록 ──────────────────────────────────────────
-- 구글 계정으로 들어온 사람만 씁니다. owner 는 'g:<사용자ID>' 형태이고,
-- 접근 규칙상 본인 기록만 읽고 쓸 수 있습니다.
-- 같은 주소가 두 파트에 있는 경우가 있어(빌 2:3-4, 벧전 1:18-19)
-- 파트까지 합쳐 한 줄로 봅니다.

create table if not exists public.personal_records (
  owner       text not null,             -- 'g:' || auth.uid()
  addr        text not null,
  part_name   text not null,
  display     text,
  series      text,
  part        text,
  topic       text,
  grade       text not null,             -- bud | ear | grain | harvest (옛 기록: seed~fruit)
  point       int,
  updated_at  timestamptz not null default now(),
  primary key (owner, addr, part_name)
);

create index if not exists personal_records_owner_idx on public.personal_records (owner);

-- 옛 5단계(씨앗·새싹·잎·꽃·열매)로 남은 개인 기록을 네 단계로 옮깁니다.
-- 여러 번 돌려도 탈이 없습니다. (앱도 읽을 때 옮겨 주지만, 서버 쪽도
--  같이 정리해 두면 나중에 보기에 깔끔합니다.)
update public.personal_records set grade='bud',     point=1 where grade='seed';
update public.personal_records set grade='ear',     point=2 where grade in ('sprout','leaf');
update public.personal_records set grade='grain',   point=3 where grade='flower';
update public.personal_records set grade='harvest', point=4 where grade='fruit';

alter table public.personal_records enable row level security;

-- 예전 버전(이름+번호 방식)에서 쓰던 규칙은 걷어 냅니다.
drop policy if exists "암송 카드 기록" on public.personal_records;
drop policy if exists "로그인 기록"   on public.personal_records;

drop policy if exists "본인 기록만" on public.personal_records;
create policy "본인 기록만" on public.personal_records
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);


-- ── 3-2. 타이핑 기록 ───────────────────────────────────────────
-- 구절을 외워서 쳐 본 결과입니다. 개인 기록과 마찬가지로 로그인한
-- 사람만 쓰고, 본인 것만 읽고 씁니다. 구절 하나에 한 줄이고, 칠 때마다
-- 최고 정확도와 마지막 결과가 갱신됩니다.

create table if not exists public.typing_records (
  owner       text not null,             -- 'g:' || auth.uid()
  addr        text not null,
  part_name   text not null,
  ver         text not null default 'gae',   -- gae(개역개정) | han(개역한글)
  tries       int  not null default 0,       -- 쳐 본 횟수
  best        int  not null default 0,       -- 최고 정확도 %
  last        int  not null default 0,       -- 마지막 정확도 %
  wrong       int  not null default 0,       -- 마지막에 틀린 어절 수
  hints       int  not null default 0,       -- 마지막에 쓴 힌트 수
  seconds     int  not null default 0,       -- 마지막에 걸린 시간
  topic_ok    boolean,                       -- 구절 제목: 맞음/틀림/안 씀(비어 있음)
  updated_at  timestamptz not null default now(),
  primary key (owner, addr, part_name)
);

alter table public.typing_records add column if not exists topic_ok boolean;

create index if not exists typing_records_owner_idx on public.typing_records (owner);

alter table public.typing_records enable row level security;

drop policy if exists "본인 타이핑만" on public.typing_records;
create policy "본인 타이핑만" on public.typing_records
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);


-- ── 3-3. FSRS 암송 ────────────────────────────────────────────
-- 잊을 때쯤 다시 물어보려고, 구절마다 「언제 다시 볼지」를 적어 둡니다.
-- 한 구절에 카드가 셋까지 열립니다.
--   link   제목 ↔ 주소      recite 주소 → 내용      title  제목 → 내용
-- 개인 기록과 같이 로그인한 사람만, 본인 것만 읽고 씁니다.

create table if not exists public.fsrs_cards (
  owner       text not null,             -- 'g:' || auth.uid()
  addr        text not null,
  part_name   text not null,
  kind        text not null check (kind in ('link','recite','title')),
  stability   double precision not null default 0,   -- FSRS 안정도
  difficulty  double precision not null default 0,   -- FSRS 난이도
  due         date not null,                          -- 다시 볼 날
  last_review timestamptz,
  reps        int  not null default 0,
  lapses      int  not null default 0,
  streak      int  not null default 0,   -- 곡식 이상 연속 횟수(다음 단계 열림)
  dir         int  not null default 0,   -- link 카드의 방향(0 주소→제목, 1 제목→주소)
  opened_on   date,                      -- 이 카드를 연 날(하루 새 구절 수를 세는 기준)
  updated_at  timestamptz not null default now(),
  primary key (owner, addr, part_name, kind)
);

alter table public.fsrs_cards add column if not exists opened_on date;

create index if not exists fsrs_cards_due_idx on public.fsrs_cards (owner, due);

alter table public.fsrs_cards enable row level security;

drop policy if exists "본인 암송카드만" on public.fsrs_cards;
create policy "본인 암송카드만" on public.fsrs_cards
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);

-- 설정도 계정에 묶어 둡니다(폰을 바꿔도 그대로).
create table if not exists public.fsrs_settings (
  owner        text primary key,
  parts        text not null default '',      -- '60구절 A · 60구절 B'
  new_per_day  int  not null default 3,
  max_reviews  int  not null default 20,
  use_title    boolean not null default true, -- 제목 → 내용 카드 쓰기
  updated_at   timestamptz not null default now()
);

alter table public.fsrs_settings enable row level security;

drop policy if exists "본인 암송설정만" on public.fsrs_settings;
create policy "본인 암송설정만" on public.fsrs_settings
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);


-- ── 3-4. 수확 기록 ────────────────────────────────────────────
-- 하루에 얼마나 했는지 한 줄씩 쌓습니다(사람당 하루 한 줄). 밭 달력과
-- 「이어 온 날」이 여기서 나옵니다. 나머지 수치는 위 표들에서 셉니다.

create table if not exists public.study_days (
  owner       text not null,             -- 'g:' || auth.uid()
  day         date not null,             -- 하루 경계(앱의 F_CUT, 지금은 밤 12시)로 본 날짜
  reviews     int  not null default 0,   -- 거둔 암송 카드
  opened      int  not null default 0,   -- 새로 연 구절
  typings     int  not null default 0,   -- 타이핑 채점 횟수
  words       int  not null default 0,   -- 타이핑으로 맞힌 어절
  graded      int  not null default 0,   -- 개인 기록에 남긴 채점
  updated_at  timestamptz not null default now(),
  primary key (owner, day)
);

alter table public.study_days enable row level security;

drop policy if exists "본인 수확만" on public.study_days;
create policy "본인 수확만" on public.study_days
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);


-- ── 3-5. 내 구절 ───────────────────────────────────────────────
-- 「내 암송」에 둔 새 구절 · 최근 구절 · 이전 구절입니다. 구절 하나에 한 줄.
-- 로그인한 사람만, 본인 것만 읽고 씁니다.

create table if not exists public.my_verses (
  owner       text not null,             -- 'g:' || auth.uid()
  addr        text not null,             -- 구절 주소
  part_name   text not null,             -- 파트 (같은 주소가 두 파트에 있어 함께 봅니다)
  slot        text not null default 'new'
              check (slot in ('new','recent','prev')),   -- 새 · 최근 · 이전
  pos         double precision not null default 0,       -- 칸 안에서의 순서
  updated_at  timestamptz not null default now(),
  primary key (owner, addr, part_name)
);

alter table public.my_verses enable row level security;

drop policy if exists "본인 구절만" on public.my_verses;
create policy "본인 구절만" on public.my_verses
  for all to authenticated
  using      (owner = 'g:' || auth.uid()::text)
  with check (owner = 'g:' || auth.uid()::text);


-- ── 3-6. 함께 거두는 밭 ────────────────────────────────────────
-- 여럿이 방 번호로 들어와 한 파트를 함께 거둡니다. 로그인 없이 누구나
-- 들어올 수 있어야 해서 대회 표처럼 누구에게나 열려 있습니다. 다만 지우기는
-- 주지 않고, 고치기도 꼭 필요한 칸에만 줍니다.

create table if not exists public.harvest_rooms (
  code        text primary key,          -- 방 번호 (숫자 4자리)
  parts       text not null,             -- 파트 이름 (' · ' 로 이음)
  goal        int  not null default 10,  -- 목표 구절 수 (0 = 전부)
  status      text not null default 'open',   -- open | done
  host        text,                      -- 만든 사람 (방 안에서 쓰는 이름표)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.harvest_players (
  code        text not null,
  pid         text not null,             -- 기기마다 만든 이름표
  name        text not null,
  joined_at   timestamptz not null default now(),   -- 들어온 순서 = 외우는 순서
  seen_at     timestamptz not null default now(),   -- 자리에 있는지 (15초마다)
  primary key (code, pid)
);

create table if not exists public.harvest_rounds (
  code        text not null,
  no          int  not null,             -- 몇 번째 차례
  addr        text not null,
  part_name   text not null,
  reciter     text not null,             -- 외우는 사람
  relay       text,                      -- 막혔을 때 이어 받은 사람
  said_at     timestamptz,               -- 「다 외웠어요」
  result      text,                      -- bud | ear | grain | harvest | skip
  closed_at   timestamptz,
  created_at  timestamptz not null default now(),
  primary key (code, no)
);

create table if not exists public.harvest_votes (
  code        text not null,
  no          int  not null,
  pid         text not null,             -- 들은 사람
  grade       text not null,             -- bud | ear | grain | harvest
  updated_at  timestamptz not null default now(),
  primary key (code, no, pid)
);

alter table public.harvest_rooms   enable row level security;
alter table public.harvest_players enable row level security;
alter table public.harvest_rounds  enable row level security;
alter table public.harvest_votes   enable row level security;

drop policy if exists "밭 함께 쓰기" on public.harvest_rooms;
create policy "밭 함께 쓰기" on public.harvest_rooms
  for all to anon, authenticated using (true) with check (true);
drop policy if exists "밭 사람" on public.harvest_players;
create policy "밭 사람" on public.harvest_players
  for all to anon, authenticated using (true) with check (true);
drop policy if exists "밭 차례" on public.harvest_rounds;
create policy "밭 차례" on public.harvest_rounds
  for all to anon, authenticated using (true) with check (true);
drop policy if exists "밭 매김" on public.harvest_votes;
create policy "밭 매김" on public.harvest_votes
  for all to anon, authenticated using (true) with check (true);


-- ── 4. 권한 열어 주기 ──────────────────────────────────────────
-- 2026년 5월 30일 이후에 만든 Supabase 프로젝트는, public 스키마에 표를
-- 새로 만들어도 웹에서 쓰는 역할(anon·authenticated)에게 자동으로 권한을
-- 주지 않습니다. 그래서 SQL Editor 에서는 되는데 사이트에서는
-- "permission denied for table ... [42501]" 이 납니다.
--
-- 먼저 두 역할의 권한을 싹 걷어 낸 다음, 앱이 실제로 쓰는 것만 정확히
-- 다시 줍니다. 몇 번을 실행해도 늘 같은 상태가 됩니다.
-- (service_role 은 Supabase 가 관리하니 건드리지 않습니다.)

revoke all on public.contests         from anon, authenticated;
revoke all on public.contest_entries  from anon, authenticated;
revoke all on public.contest_verses   from anon, authenticated;
revoke all on public.personal_records from anon, authenticated;
revoke all on public.typing_records   from anon, authenticated;
revoke all on public.fsrs_cards       from anon, authenticated;
revoke all on public.fsrs_settings    from anon, authenticated;
revoke all on public.study_days       from anon, authenticated;
revoke all on public.my_verses        from anon, authenticated;
revoke all on public.harvest_rooms    from anon, authenticated;
revoke all on public.harvest_players  from anon, authenticated;
revoke all on public.harvest_rounds   from anon, authenticated;
revoke all on public.harvest_votes    from anon, authenticated;

grant usage on schema public to anon, authenticated;

-- 대회 — 누구나 보고 만들 수 있지만, 만든 뒤 고치거나 지울 수는 없습니다.
--   읽기는 칸을 골라 줍니다. 호스트 번호의 지문(host_hash)은 누구도 읽을 수 없습니다.
--   결과 공개 범위는 위의 contest_set_results 함수로만(호스트 번호가 맞을 때) 바뀝니다.
grant insert on public.contests to anon, authenticated;
grant select (code, title, scoring, n, created_at, starts_at, results, has_host)
  on public.contests to anon, authenticated;

-- 대회 기록 — 검사자가 로그인 없이 읽고 써야 합니다.
--   지우기(delete)는 주지 않습니다. 앱이 쓰지도 않고, 주소를 아는 사람이
--   순위표를 통째로 지울 수 있게 둘 이유가 없습니다.
--   참가 기록은 고치기를 점수 칸에만 줍니다. 이름·파트·뽑은 구절(picks)은
--   한 번 등록하면 누구도 바꿀 수 없습니다.
grant select, insert on public.contest_entries to anon, authenticated;
grant update (total, graded, score, scoring, fruit, flower, leaf, sprout, seed,
              bud, ear, grain, harvest, gold, silver, bronze, updated_at)
  on public.contest_entries to anon, authenticated;
grant select, insert, update on public.contest_verses  to anon, authenticated;

-- 개인 기록 — 로그인한 사람만. 채점을 되돌릴 수 있어야 하니 지우기 포함.
--   어차피 접근 규칙이 "본인 것만"으로 막고 있습니다.
grant select, insert, update, delete on public.personal_records to authenticated;

-- 타이핑 기록 — 개인 기록과 같습니다. 로그인한 사람만, 본인 것만.
grant select, insert, update, delete on public.typing_records to authenticated;

-- FSRS 암송 — 역시 로그인한 사람만, 본인 것만.
grant select, insert, update, delete on public.fsrs_cards    to authenticated;
grant select, insert, update, delete on public.fsrs_settings to authenticated;
grant select, insert, update, delete on public.study_days   to authenticated;
grant select, insert, update, delete on public.my_verses    to authenticated;

-- 함께 거두는 밭 — 로그인 없이 누구나. 지우기는 주지 않습니다.
--   방은 「끝남」 표시만, 사람은 이름과 「자리에 있음」만, 차례는 이어 받기 ·
--   다 외움 · 결과만 고칠 수 있습니다. 매김은 자기 것을 바꿀 수 있어야 해서 통째로.
grant select, insert on public.harvest_rooms   to anon, authenticated;
grant update (status, updated_at) on public.harvest_rooms to anon, authenticated;
grant select, insert on public.harvest_players to anon, authenticated;
grant update (name, seen_at) on public.harvest_players to anon, authenticated;
grant select, insert on public.harvest_rounds  to anon, authenticated;
grant update (relay, said_at, result, closed_at) on public.harvest_rounds to anon, authenticated;
grant select, insert, update on public.harvest_votes to anon, authenticated;

-- 표를 더 만들 일이 생기면 그 표에도 위와 같은 grant 를 한 줄 적어 주세요.


-- ── 5. 반영 ────────────────────────────────────────────────────
-- 바뀐 내용을 API가 바로 알아보게 합니다. (안 해도 1~2분 뒤 반영됩니다)

notify pgrst, 'reload schema';


-- ── 6. 확인 ────────────────────────────────────────────────────
-- 아래처럼 나오면 정상입니다. 권한 이름이 그대로 보입니다.
--
--   표                접근규칙 RLS  anon                      로그인
--   contest_entries      3     1   INSERT, SELECT, UPDATE(일부 칸만)  (로그인도 같음)
--   contest_verses       1     1   INSERT, SELECT, UPDATE    INSERT, SELECT, UPDATE
--   contests             2     1   INSERT, SELECT(일부 칸만)  INSERT, SELECT(일부 칸만)
--   personal_records     1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   typing_records       1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   fsrs_cards           1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   fsrs_settings        1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   study_days           1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   my_verses            1     1   없음                      DELETE, INSERT, SELECT, UPDATE
--   harvest_players      1     1   INSERT, SELECT, UPDATE(일부 칸만)  (로그인도 같음)
--   harvest_rooms        1     1   INSERT, SELECT, UPDATE(일부 칸만)  (로그인도 같음)
--   harvest_rounds       1     1   INSERT, SELECT, UPDATE(일부 칸만)  (로그인도 같음)
--   harvest_votes        1     1   INSERT, SELECT, UPDATE    INSERT, SELECT, UPDATE
--
-- contest_entries 의 「일부 칸만」은 점수 칸, 함께 거두는 밭의 「일부 칸만」은
-- 이어 받기 · 다 외움 · 결과 같은 칸입니다. contests 의 SELECT(일부 칸만)은
-- 호스트 번호 지문(host_hash)만 빼고 읽을 수 있다는 뜻입니다.
-- 개인 기록 · 타이핑 · FSRS · 내 구절 표의 anon 이 "없음" 인 것은 정상입니다.
-- 개인 기록은 로그인한 사람만 쓰라고 일부러 그렇게 둔 것입니다.

select t.table_name as "표",
       (select count(*) from pg_policies p
         where p.schemaname='public' and p.tablename=t.table_name) as "접근규칙",
       (select count(*) from pg_class c
          join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relname=t.table_name and c.relrowsecurity) as "RLS",
       coalesce((select string_agg(x.p, ', ' order by x.p) from (
           select distinct g.privilege_type as p from information_schema.role_table_grants g
            where g.table_schema='public' and g.table_name=t.table_name and g.grantee='anon'
           union
           select 'UPDATE(일부 칸만)' from information_schema.column_privileges cp
            where cp.table_schema='public' and cp.table_name=t.table_name and cp.grantee='anon'
              and cp.privilege_type='UPDATE'
              and not exists (select 1 from information_schema.role_table_grants g2
                               where g2.table_schema='public' and g2.table_name=t.table_name
                                 and g2.grantee='anon' and g2.privilege_type='UPDATE')
           union
           select 'SELECT(일부 칸만)' from information_schema.column_privileges cp
            where cp.table_schema='public' and cp.table_name=t.table_name and cp.grantee='anon'
              and cp.privilege_type='SELECT'
              and not exists (select 1 from information_schema.role_table_grants g2
                               where g2.table_schema='public' and g2.table_name=t.table_name
                                 and g2.grantee='anon' and g2.privilege_type='SELECT')
         ) x),'없음') as "anon",
       coalesce((select string_agg(x.p, ', ' order by x.p) from (
           select distinct g.privilege_type as p from information_schema.role_table_grants g
            where g.table_schema='public' and g.table_name=t.table_name and g.grantee='authenticated'
           union
           select 'UPDATE(일부 칸만)' from information_schema.column_privileges cp
            where cp.table_schema='public' and cp.table_name=t.table_name and cp.grantee='authenticated'
              and cp.privilege_type='UPDATE'
              and not exists (select 1 from information_schema.role_table_grants g2
                               where g2.table_schema='public' and g2.table_name=t.table_name
                                 and g2.grantee='authenticated' and g2.privilege_type='UPDATE')
           union
           select 'SELECT(일부 칸만)' from information_schema.column_privileges cp
            where cp.table_schema='public' and cp.table_name=t.table_name and cp.grantee='authenticated'
              and cp.privilege_type='SELECT'
              and not exists (select 1 from information_schema.role_table_grants g2
                               where g2.table_schema='public' and g2.table_name=t.table_name
                                 and g2.grantee='authenticated' and g2.privilege_type='SELECT')
         ) x),'없음') as "로그인"
  from information_schema.tables t
 where t.table_schema='public'
   and t.table_name in ('contests','contest_entries','contest_verses',
                        'personal_records','typing_records','fsrs_cards','fsrs_settings',
                        'study_days','my_verses','harvest_rooms','harvest_players','harvest_rounds',
                        'harvest_votes')
 order by t.table_name;


-- ── 7. 정리 (선택) ─────────────────────────────────────────────
-- 예전 버전에서 쓰던 것들입니다. 남겨 두어도 아무 지장 없지만,
-- 깨끗이 지우고 싶으면 아래 두 줄의 -- 를 떼고 실행하세요.
--
--   이름+번호 방식으로 쌓였던 기록 (owner 가 'c:' 로 시작하는 줄)
-- delete from public.personal_records where owner like 'c:%';
--
--   더 예전의 구글 전용 표
-- drop table if exists public.personal_progress;
