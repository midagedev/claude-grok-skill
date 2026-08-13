# claude-grok-skill

**Claude Code에서 grok CLI를 구현 서브에이전트로 부리는 스킬** — 리드 세션(Claude)은 오케스트레이션·스펙 작성·diff 리뷰·커밋만 하고, 코드 구현·기계적 수정·스크린샷 판정은 로컬 `grok` CLI에 위임해 토큰을 아낍니다.

A Claude Code skill that delegates implementation and vision-verdict work to the local **grok CLI** as a cheap headless sub-agent, while the lead Claude session stays orchestration-only.

## Why

- grok 구독이 있으면 구현 토큰이 사실상 무료입니다. 판단이 필요한 지점(스펙·리뷰·게이트·커밋)에만 Claude 토큰을 씁니다.
- 스킬에 담긴 운영 규칙은 전부 실측입니다: 동일 스펙을 Claude(Opus/Fable)와 grok에게 병렬로 주고 블라인드 판정(비전 + 코드 리뷰)으로 비교하는 실험을 9회 돌려, **품질 격차를 프롬프트 장치로 좁히는 방법**을 찾았습니다.
  - 자기 저작 게이트 깊이: 계약↔단언 매핑 표를 의무화하자 단언 수가 4배로 (10 → 42 → 67).
  - 시각 품질: "자기 캡처를 직접 열어 계약과 대조 + **정체성 가독**('X로 읽히는가, 무엇으로 오독되는가')을 체크리스트 1번으로" — 도입 후 grok이 블라인드 비전 비교에서 상위 모델을 이기기 시작.
  - 로직 설계: derive-don't-store 등 설계 원칙 4항을 지시하면 상태 기계 품질이 리뷰어가 인정할 수준으로 상승 (완전히 닫히지는 않음 — 한계도 README 하단에).

## Install

```bash
git clone https://github.com/midagedev/claude-grok-skill
cd claude-grok-skill

# user scope (~/.claude/skills/grok-delegate/)
./install.sh

# or project scope (./.claude/skills/grok-delegate/ in your repo)
./install.sh --project
```

전제 조건 / Prerequisites:
- [Claude Code](https://claude.com/claude-code)
- `grok` CLI installed and authenticated (a grok subscription)

설치 후 Claude Code 세션에서 `/grok-delegate`를 입력하거나, "이거 grok으로 돌려줘"라고 말하면 스킬이 로드됩니다.

## What's inside

| File | Purpose |
|---|---|
| `skills/grok-delegate/SKILL.md` | 스킬 본문 — 호출 레시피(검증된 플래그 조합), 품질 번들, 리드 검수 체크리스트 |
| `skills/grok-delegate/references/spec-preamble.md` | 모든 위임 스펙 앞에 붙이는 공통 규칙 — 전부 실제 사고에서 나온 8개 조항 + 자기검증 8문항 보고 형식 |
| `skills/grok-delegate/references/spec-template.md` | 작업별 스펙 템플릿 — 계약·깊이 요구·시각 자기검증 프로토콜 골격 |

## The quality bundle (요약)

grok에게 위임할 때 스펙에 넣는 다섯 장치 — 각각이 실험에서 측정 가능한 품질 상승을 만들었습니다:

1. **계약↔단언 매핑 표** + FAIL-first 증거 (게이트 깊이 4배)
2. **깊이의 정량화** — "꼼꼼히" 대신 "조항당 단언 2개, 커버리지 표, 발견한 결함은 네 범위 안에서 방어까지"
3. **셀프 리뷰 패스** — "놓쳤을 결함 클래스 3개를 나열하고 각각 단언화"
4. **시각 자기검증** — 자기 캡처를 열어 계약과 대조, 1번 항목은 항상 정체성 가독
5. **로직 설계 원칙 4항** — derive-don't-store · 로드 시 재정규화 · 입력 3분류 방어 · 적대적 API 셀프 리뷰

플래그는 `--reasoning-effort xhigh --max-turns 1200 --always-approve --deny 'Bash(git *)'` 조합이 실측 기준입니다 (근거는 SKILL.md 참조).

## Known limits (정직하게)

- 탐색적 문제(스펙을 쓸 수 없는 원인 축소)는 위임 대상이 아닙니다 — 리드가 먼저 좁히세요.
- 상태 기계의 미묘한 설계(라이브/재유도 이중 구현 회피, "수선 vs 거절" 경계)는 원칙 지시로도 완전히 닫히지 않았습니다. 설계 무게가 있는 코어는 Claude가 짜고 grok이 리뷰받는 편이 안전합니다.
- 참조 이미지는 과제와 **같은 이펙트 유형**일 때만 도움이 됩니다. 다른 유형의 "모범 캡처"를 주면 형태 언어가 오염되어 오히려 나빠졌습니다.
- grok 보고서는 대체로 정직하지만, 문제는 **보고에 없는 것**입니다 — SKILL.md의 리드 검수 체크리스트 8항을 따르세요.

## License

MIT
