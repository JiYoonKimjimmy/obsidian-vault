
#### Money 프로젝트 개발 주의 사항
- 개발 시작 전 `project-kbank` 브랜치 병합 후 작업 진행
- business 모듈 개발 최소화
- client 모듈 개발은 함께

## 개발 Task
1. [ ] [PREPAY-1048](https://musinsapayments.atlassian.net/browse/PREPAY-1048) 진입 Session 요청 API 기능 고도화
2. [x] [PREPAY-1095](https://musinsapayments.atlassian.net/browse/PREPAY-1095) 잔액 조회 V2 API 신규 개발
3. [x] [PREPAY-1096](https://musinsapayments.atlassian.net/browse/PREPAY-1096) 상품 상품 이용 사전 조회 API 신규 개발
	1. [x] 케이뱅크에서 계좌 개설 완료 후 호출할 `callbackUrl` 중요
	2. [x] `clientWebViewCode` 검증 로직 중요
4. [x] [PREPAY-780](https://musinsapayments.atlassian.net/browse/PREPAY-780) 상품 이용 완료 Callback API 신규 개발
5. [ ] [PREPAY-1120](https://musinsapayments.atlassian.net/browse/PREPAY-1120) `mupay` 계좌 등록 완료 처리 프로세스 - `mupay` 개발 내용 확인 필요
6. [ ] 케이뱅크 계좌 인출 세션 생성
7. [ ] 케이뱅크 계좌 인출 승인 처리
8. [ ] 케이뱅크 계좌 충전 세션 생성
9. [ ] 케이뱅크 계좌 충전 승인 처리

### TODO
1. [ ] `LINKED_BANK_TYPE` session 값 초기 설정 시점 확인 필요: `MoneySessionServiceV1.processSession()` 함수에서 초기 설정 필요
2. [ ] 