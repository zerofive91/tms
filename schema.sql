-- ═══════════════════════════════════════════════════════════════
--  네비게이토 암송 Festival — Supabase 테이블
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여 넣고 Run 하세요.
--  두 번 실행해도 안전합니다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 대회 채점 ───────────────────────────────────────────────
-- 누구나(로그인 없이) 읽고 쓸 수 있습니다. 대회 현장에서 검사자가
-- 로그인 없이 채점해야 하기 때문입니다.

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
  grade       text,
  point       int,
  updated_at  timestamptz not null default now()
);

create index if not exists contest_verses_entry_idx on public.contest_verses (entry_id);

alter table public.contest_entries enable row level security;
alter table public.contest_verses  enable row level security;

drop policy if exists "대회 결과 공개" on public.contest_entries;
create policy "대회 결과 공개" on public.contest_entries
  for all to anon, authenticated using (true) with check (true);

drop policy if exists "대회 구절 공개" on public.contest_verses;
create policy "대회 구절 공개" on public.contest_verses
  for all to anon, authenticated using (true) with check (true);


-- ── 2. 개인 암송 기록 ──────────────────────────────────────────
-- 구글로 로그인한 본인만 자기 기록을 읽고 씁니다.
-- 같은 주소가 두 파트에 있는 경우가 있어(빌 2:3-4, 벧전 1:18-19)
-- 파트까지 합쳐 한 줄로 봅니다.

create table if not exists public.personal_progress (
  user_id     uuid not null references auth.users (id) on delete cascade,
  addr        text not null,
  part_name   text not null,
  series      text,
  part        text,
  topic       text,
  grade       text not null,             -- seed | sprout | leaf | flower | fruit
  point       int,
  updated_at  timestamptz not null default now(),
  primary key (user_id, addr, part_name)
);

alter table public.personal_progress enable row level security;

drop policy if exists "본인 기록만 조회" on public.personal_progress;
create policy "본인 기록만 조회" on public.personal_progress
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "본인 기록만 저장" on public.personal_progress;
create policy "본인 기록만 저장" on public.personal_progress
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "본인 기록만 수정" on public.personal_progress;
create policy "본인 기록만 수정" on public.personal_progress
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "본인 기록만 삭제" on public.personal_progress;
create policy "본인 기록만 삭제" on public.personal_progress
  for delete to authenticated using (auth.uid() = user_id);
