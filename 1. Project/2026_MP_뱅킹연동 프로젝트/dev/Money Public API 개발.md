
#### Money 프로젝트 개발 주의 사항
- 개발 시작 전 `project-kbank` 브랜치 병합 후 작업 진행
- business 모듈 개발 최소화
- client 모듈 개발은 함께

## 개발 Task
1. [ ] 잔액 조회
	1. [ ] `LINKED_BANK_TYPE` session 값 초기 설정 필요
2. [ ] 상품 사전 조회
	1. [ ] 케이뱅크에서 계좌 개설 완료 후 호출할 `callbackUrl` 중요
	2. [ ] `clientWebViewCode` 검증 로직 중요
3. [ ] 충전 세션 생성
4. [ ] 충전 승인
5. [ ] 충전 프로세스