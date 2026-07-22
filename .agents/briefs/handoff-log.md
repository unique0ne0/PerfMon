# Handoff Log — 라우터

## Dispatch
1. 사용자가 작업 ID를 지정했으면(예: "작업 PM001 구현해") → 그 패킷 파일(`packets/PM<NNN>-<slug>.md`)로 직행.
2. 지정이 없으면 → 아래 표에서 상태 ACTIVE이고 "다음 단계" 담당이 자신(또는 미지정)인 패킷을 찾는다.
3. 패킷 파일 열기 → `## Amendments`(있으면 우선) → `## Pipeline Status`의 첫 미체크 `- [ ]`가 역할.

> Task ID 접두 `PM` = PerfMon 프로젝트 전용 (다른 프로젝트의 번호 체계와 구분).

## Packets
| ID | 제목 | 상태 | 다음 단계(담당) | Blocked by | 갱신일 |
|----|------|------|----------------|-----------|--------|
| PF001 | 4개 팀 리뷰 findings 종합 수정 | DONE | 완료 — ⑤ 최종 리뷰 + Integration(기획팀/Claude) | - | 2026-07-22 |

> 주: PF001은 사용자 지정 ID(기본 프리픽스 PM과 별개로 이번 작업에 한해 사용). 패킷: `packets/PF001-team-review-fixes.md`
