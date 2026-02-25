
#### Money 프로젝트 개발 주의 사항
- 개발 시작 전 `project-kbank` 브랜치 병합 후 작업 진행
- business 모듈 개발 최소화
- client 모듈 개발은 함께

## 개발 Task
1. [x] 잔액 조회
	1. [ ] `LINKED_BANK_TYPE` session 값 초기 설정 시점 확인 필요
2. [ ] 상품 사전 조회
	1. [ ] 케이뱅크에서 계좌 개설 완료 후 호출할 `callbackUrl` 중요
	2. [ ] `clientWebViewCode` 검증 로직 중요
3. [ ] 충전 세션 생성
4. [ ] 충전 승인
5. [ ] 충전 프로세스



```
  개요

  api 모듈의 잔액 조회(BalanceServiceImpl) 비즈니스 로직을 public-api 모듈과 동일한 Strategy Pattern 구조로 리팩토링합니다.

  Before: 단일 서비스 클래스에서 일반/케이뱅크 분기 처리
  Controller → BalanceUseCaseImpl → BalanceServiceImpl (내부 if 분기)

  After: Strategy Pattern으로 분리
  Controller → BalanceUseCaseImpl → LinkedBankTypeServiceSelector
                                          ↓
                            GeneralBalanceServiceImpl / KbankBalanceServiceImpl
                                          ↓
                                    BalanceCalculator

  변경 사항

  신규 파일 (6개)

  ┌───────────────────────────────┬────────────────────────────────────────────────────────────────────────┐
  │             파일              │                                  설명                                  │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ LinkedBankTypeServiceSelector │ CustomerInfo + CustomerKbankRepository로 회원 유형 판별 후 서비스 선택 │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ BalanceCalculateCommand       │ 잔액 계산 요청 DTO (record)                                            │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ BalanceResult                 │ 잔액 결과 DTO (BalanceResultDto 대체)                                  │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ BalanceCalculator             │ 잔액 계산 로직 분리 (최대보유금액, 예치금 계산)                        │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ GeneralBalanceServiceImpl     │ 일반 회원 잔액 조회                                                    │
  ├───────────────────────────────┼────────────────────────────────────────────────────────────────────────┤
  │ KbankBalanceServiceImpl       │ K뱅크 회원 잔액 조회 (실시간 잔액 API 호출)                            │
  └───────────────────────────────┴────────────────────────────────────────────────────────────────────────┘

  수정 파일 (5개)

  ┌─────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────┐
  │                파일                 │                                   변경 내용                                    │
  ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ MoneySummary                        │ @Builder 추가, totalAmount() → calculateTotalAmount() 메서드명 변경            │
  ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ BalanceService                      │ Strategy Pattern 인터페이스: getType() 추가, getBalance() 시그니처 변경        │
  ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ BalanceUseCase / BalanceUseCaseImpl │ 반환 타입 변경 + LinkedBankTypeServiceSelector 위임 구조 (고객 검증 로직 유지) │
  ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ BalanceResponseV2                   │ from() 파라미터 타입 변경 (응답 필드 3개 변경 없음)                            │
  ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ BalanceApiControllerV2              │ import 변경만                                                                  │
  └─────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────┘

  삭제 파일 (2개)

  - BalanceServiceImpl → GeneralBalanceServiceImpl + KbankBalanceServiceImpl로 대체
  - BalanceResultDto → BalanceResult로 대체

  테스트 (6개)

  - 신규: GeneralBalanceServiceImplTest, KbankBalanceServiceImplTest, BalanceCalculatorTest, LinkedBankTypeServiceSelectorTest
  - 수정: BalanceUseCaseImplTest, BalanceApiControllerV2Test
  - 삭제: BalanceServiceImplTest

  public-api 대비 차이점

  ┌────────────────┬───────────────────────────────┬───────────────────────────────────────────────────────────────────────────────┐
  │      항목      │          public-api           │                                  api (본 MR)                                  │
  ├────────────────┼───────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ JWT 접근       │ AuthSessionHandler            │ CustomerInfo                                                                  │
  ├────────────────┼───────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ 회원 유형 판별 │ 세션 기반 getLinkedBankType() │ CustomerKbankRepository.existsByCustomerUid()                                 │
  ├────────────────┼───────────────────────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ 고객 검증      │ AOP에서 처리                  │ BalanceUseCaseImpl에서 직접 수행 (상태 조회 + validator + customerUid 동기화) │
  └────────────────┴───────────────────────────────┴───────────────────────────────────────────────────────────────────────────────┘

  API 영향도

  - API 응답 변경 없음: BalanceResponseV2의 memberUid, totalAmount, depositAmount 3개 필드 유지
  - 내부 구조 변경만 해당

  검증

  - ./gradlew :api:compileJava — BUILD SUCCESSFUL
  - ./gradlew :api:test — BUILD SUCCESSFUL (전체 테스트 통과)
```