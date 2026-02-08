# 캠페인 프로모션 Consumer 구현 체크리스트

> 이 문서는 [IMPLEMENTATION.md](IMPLEMENTATION.md)의 구현 순서를 체크리스트 형식으로 분리한 문서입니다.
> 각 Phase 완료 시 코드 리뷰 및 Git 커밋을 진행합니다.
>
> (Git 커밋 시, `Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"` 문구는 제외)

---

## 구현 시 참고사항

| 참고 문서                                      | 내용                    |
|--------------------------------------------|-----------------------|
| **[IMPLEMENTATION.md](IMPLEMENTATION.md)** | 비즈니스 로직, 코드 예시, 상세 설계 |

**구현 전 반드시 확인할 내용**:
- Consumer 처리 흐름 및 다이어그램 (Section 3)
- Processor Layer 코드 구현 상세 (Section 4.2)
- Entity/Repository 필드 정의 (Section 4.3)
- Kafka 메시지 Payload 구조 (Section 5.4)
- 에러 핸들링 전략 (Section 9)
- 핵심 파일 참조 - 기존 코드 패턴 (Section 7)

---

## Git 브랜치 전략

### Jira 티켓
- **티켓 번호**: PREPAY-954
- **최종 MR 브랜치**: `feature/PREPAY-954`
- **Target 브랜치**: `staging`

### Phase별 브랜치

| Phase | 브랜치명                                   | 기반 브랜치                              | 머지 대상                |
|:-----:|----------------------------------------|-------------------------------------|----------------------|
|   -   | `feature/PREPAY-954`                   | `staging`                           | `staging` (최종 MR)    |
|   1   | `feature/PREPAY-954-phase1-domain`     | `feature/PREPAY-954`                | `feature/PREPAY-954` |
|   2   | `feature/PREPAY-954-phase2-feign`      | `feature/PREPAY-954` (Phase 1 머지 후) | `feature/PREPAY-954` |
|   3   | `feature/PREPAY-954-phase3-cache`      | `feature/PREPAY-954` (Phase 2 머지 후) | `feature/PREPAY-954` |
|   4   | `feature/PREPAY-954-phase4-processor`  | `feature/PREPAY-954` (Phase 3 머지 후) | `feature/PREPAY-954` |
|   5   | `feature/PREPAY-954-phase5-retry`      | `feature/PREPAY-954` (Phase 4 머지 후) | `feature/PREPAY-954` |
|   6   | `feature/PREPAY-954-phase6-listener`   | `feature/PREPAY-954` (Phase 5 머지 후) | `feature/PREPAY-954` |
|   7   | `feature/PREPAY-954-phase7-service`    | `feature/PREPAY-954` (Phase 6 머지 후) | `feature/PREPAY-954` |
|   8   | `feature/PREPAY-954-phase8-retry-svc`  | `feature/PREPAY-954` (Phase 7 머지 후) | `feature/PREPAY-954` |
|   9   | `feature/PREPAY-954-phase9-redis`      | `feature/PREPAY-954` (Phase 8 머지 후) | `feature/PREPAY-954` |
|  10   | `feature/PREPAY-954-phase10-kafka`     | `feature/PREPAY-954` (Phase 9 머지 후) | `feature/PREPAY-954` |

### 브랜치 워크플로우

1. staging에서 feature/PREPAY-954 생성
2. Phase별 브랜치 생성 및 작업:
   - feature/PREPAY-954에서 phase1 브랜치 생성 → 작업 → 머지
   - 머지된 feature/PREPAY-954에서 phase2 브랜치 생성 → 작업 → 머지
   - (반복 ~ phase10까지)
3. 모든 Phase 완료 후 feature/PREPAY-954 → staging MR 생성

### 롤백 전략

- **특정 Phase 수정 필요 시**: 해당 Phase 브랜치 체크아웃 → 수정 → 이후 Phase 순차 재머지
- **이전 상태로 복원 시**: `feature/PREPAY-954`를 원하는 Phase 머지 시점 커밋으로 리셋

### Git 커밋 규칙

- **Co-Authored-By 제외**: 커밋 메시지에 `Co-Authored-By` 라인을 포함하지 않음

---

## Phase 1: Domain Layer (Enum, Entity, Repository) ✅

### 구현 항목

#### Enum 클래스 (`domain/constant/`)
- [x] 1-1. `PromotionStatus.kt` - READY, IN_PROGRESS, COMPLETED, STOPPED, FAILED
- [x] 1-2. `ProcessStatus.kt` - SUCCESS, RETRYING, FAILED

#### Entity 클래스 (`domain/entity/`)
- [x] 1-3. `CampaignPromotion.kt` - 프로모션 엔티티 (campaign_promotions 테이블)
- [x] 1-4. `CampaignPromotionVoucherResult.kt` - 상품권 처리 결과 엔티티
  - `transactionKey` 필드 추가 (Money API의 moneyKey 저장용)
  - updateSuccess(transactionKey), updateError, updateFailed 메서드 포함
- [x] 1-5. `CampaignPromotionPointResult.kt` - 포인트 처리 결과 엔티티
  - `transactionKey` 필드 추가 (Money API의 moneyKey 저장용)
  - updateSuccess(transactionKey), updateError, updateFailed 메서드 포함

#### Repository Interface (`domain/repository/`)
- [x] 1-6. `CampaignPromotionRepository.kt` - 프로모션 Repository
- [x] 1-7. `CampaignPromotionVoucherResultRepository.kt` - 상품권 결과 Repository (findByVoucherTargetId 포함)
- [x] 1-8. `CampaignPromotionPointResultRepository.kt` - 포인트 결과 Repository (findByPointTargetId 포함)

#### JPA Repository (`infrastructure/persistence/`)
- [x] 1-9. `CampaignPromotionJpaRepository.kt` - JpaRepository 구현
- [x] 1-10. `CampaignPromotionVoucherResultJpaRepository.kt` - JpaRepository 구현
- [x] 1-11. `CampaignPromotionPointResultJpaRepository.kt` - JpaRepository 구현

### Phase 1 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 1: Domain Layer

- Enum: PromotionStatus, ProcessStatus
- Entity: CampaignPromotion, VoucherResult, PointResult
- Repository: 프로모션, 상품권 결과, 포인트 결과 Repository
```

---

## Phase 2: FeignClient + DTO ✅

### 구현 항목

#### FeignClient Interface (`infrastructure/feign/`)
- [x] 2-1. `MoneyCampaignChargeApi.kt` - 상품권/포인트 충전 API 통합 인터페이스
  - `chargeVoucher()` - POST /internal/v1/campaigns/voucher/charge
  - `chargePoint()` - POST /internal/v1/campaigns/point/charge
- [x] 2-2. `MoneyCampaignChargeApiFallbackFactory.kt` - Fallback Factory 구현

#### Request/Response DTO (`infrastructure/feign/dto/`)
- [x] 2-3. `CampaignVoucherChargeRequest.kt` - 상품권 충전 요청 DTO
- [x] 2-4. `CampaignVoucherChargeResponse.kt` - 상품권 충전 응답 DTO
  - `moneyKey` 필드 포함 (result 엔티티의 transactionKey로 저장)
- [x] 2-5. `CampaignPointChargeRequest.kt` - 포인트 충전 요청 DTO
- [x] 2-6. `CampaignPointChargeResponse.kt` - 포인트 충전 응답 DTO
  - `moneyKey` 필드 포함 (result 엔티티의 transactionKey로 저장)

#### 테스트 코드
- [x] 2-7. `MoneyCampaignChargeApiTest.kt` - FeignClient 호출, Fallback 테스트 (6개 테스트)

### Phase 2 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 2: FeignClient + DTO

- MoneyCampaignChargeApi (상품권/포인트 통합)
- MoneyCampaignChargeApiFallbackFactory
- Request/Response DTO 4종
- MoneyCampaignChargeApiTest
```

---

## Phase 3: 캐시 설정 및 서비스 ✅

### 구현 항목

#### 캐시 서비스 (`application/`)
- [x] 3-1. `CampaignPromotionStatusCacheService.kt` - @Cacheable 프로모션 상태 조회 서비스
  - `isPromotionInProgress(promotionId: Long): Boolean` - 캐시 조회
  - `evictCache(promotionId: Long)` - @CacheEvict 캐시 무효화

#### Redis Entity/Repository (`infrastructure/redis/`)
- [x] 3-2. `CampaignPromotionStatusRedisEntity.kt` - Redis 캐시 엔티티 (TTL 20분)
- [x] 3-3. `RedisCampaignPromotionStatusRepository.kt` - Redis Repository

#### 테스트 코드
- [x] 3-4. `CampaignPromotionStatusCacheServiceTest.kt` - @Cacheable 캐시 히트/미스, @CacheEvict 테스트 (8개 테스트)

### Phase 3 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 3: 캐시 설정 및 서비스

- CampaignPromotionStatusCacheService (@Cacheable, @CacheEvict)
- CampaignPromotionStatusRedisEntity, RedisCampaignPromotionStatusRepository
- CampaignPromotionStatusCacheServiceTest
```

---

## Phase 4: Main Processor (Template Method 패턴) ✅

### 구현 항목

#### 추상 클래스 (`application/processor/`)
- [x] 4-1. `AbstractCampaignPromotionProcessor.kt` - Main Consumer 공통 로직 템플릿
  - `process(messageJson: String)` - 템플릿 메서드
  - `callMoneyApi()` → Money API 호출, 성공 시 `moneyKey` 반환 (String?)
  - `updateSuccess(result, transactionKey)` → result에 transactionKey 저장
  - 기타 추상 메서드: `parseMessage`, `getPromotionId`, `getTargetId`, `createResult`, `saveResult`, `updateError`, `buildRetryMessage`, `getRetryTopic`, `getPromotionType`

#### 구현체 클래스 (`application/processor/`)
- [x] 4-2. `CampaignPromotionVoucherProcessor.kt` - 상품권 처리 구현체
  - String → Long 변환 로직 (promotionId, voucherTargetId, customerUid, amount)
  - `validUntil` → `expiredAt` 필드 매핑 (Money API 필드명)
  - `callMoneyApi()` → 성공 시 `response.data.moneyKey` 반환
  - `updateSuccess()` → `result.updateSuccess(transactionKey)` 호출
- [x] 4-3. `CampaignPromotionPointProcessor.kt` - 포인트 처리 구현체
  - String → Long 변환 로직 (promotionId, pointTargetId, customerUid, amount)
  - `callMoneyApi()` → 성공 시 `response.data.moneyKey` 반환
  - `updateSuccess()` → `result.updateSuccess(transactionKey)` 호출

#### Message DTO (`application/dto/`)
- [x] 4-4. `CampaignPromotionVoucherMessage.kt` - 상품권 Kafka 메시지 DTO
- [x] 4-5. `CampaignPromotionPointMessage.kt` - 포인트 Kafka 메시지 DTO

#### 테스트 코드
- [x] 4-6. `AbstractCampaignPromotionProcessorTest.kt` - 템플릿 메서드 흐름, 멱등성, Retry 발행 테스트
- [x] 4-7. `CampaignPromotionVoucherProcessorTest.kt` - 상품권 전용 로직 테스트
- [x] 4-8. `CampaignPromotionPointProcessorTest.kt` - 포인트 전용 로직 테스트

### Phase 4 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 4: Main Processor

- AbstractCampaignPromotionProcessor (Template Method 패턴)
- CampaignPromotionVoucherProcessor, CampaignPromotionPointProcessor
- CampaignPromotionVoucherMessage, CampaignPromotionPointMessage
- Insert-or-Catch 멱등성 패턴 적용
- Processor 단위 테스트 3종
```

---

## Phase 5: Retry Processor (Template Method 패턴) ✅

### 구현 항목

#### 추상 클래스 (`application/processor/`)
- [x] 5-1. `AbstractCampaignPromotionRetryProcessor.kt` - Retry Consumer 공통 로직 템플릿
  - `processRetry(messageJson: String)` - 템플릿 메서드
  - `callMoneyApi()` → Money API 호출, 성공 시 `moneyKey` 반환 (String?)
  - `updateSuccess(result, transactionKey)` → result에 transactionKey 저장
  - Exponential Backoff 로직 (BASE_DELAY_MS * 2^retryCount)
  - MAX_RETRY_COUNT = 5

#### 구현체 클래스 (`application/processor/`)
- [x] 5-2. `CampaignPromotionVoucherRetryProcessor.kt` - 상품권 재시도 처리 구현체
  - `callMoneyApi()` → 성공 시 `response.data.moneyKey` 반환
  - `updateSuccess()` → `result.updateSuccess(transactionKey)` 호출
- [x] 5-3. `CampaignPromotionPointRetryProcessor.kt` - 포인트 재시도 처리 구현체
  - `callMoneyApi()` → 성공 시 `response.data.moneyKey` 반환
  - `updateSuccess()` → `result.updateSuccess(transactionKey)` 호출

#### 테스트 코드
- [x] 5-4. `AbstractCampaignPromotionRetryProcessorTest.kt` - Exponential Backoff, 재시도 횟수 테스트
- [x] 5-5. `CampaignPromotionVoucherRetryProcessorTest.kt` - 상품권 재시도 로직 테스트
- [x] 5-6. `CampaignPromotionPointRetryProcessorTest.kt` - 포인트 재시도 로직 테스트

### Phase 5 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 5: Retry Processor

- AbstractCampaignPromotionRetryProcessor (Exponential Backoff, 최대 5회)
- CampaignPromotionVoucherRetryProcessor, CampaignPromotionPointRetryProcessor
- RetryProcessor 단위 테스트 3종
```

---

## Phase 6: Kafka Listener (Main/Retry Consumer) ✅

### 구현 항목

#### Main Listener (`presentation/listener/`)
- [x] 6-1. `CampaignVoucherPromotionListener.kt` - 상품권 메인 Consumer
  - Topic: `campaign-promotion-voucher-publish`
  - GroupId: `prepay-admin-campaign-voucher`
  - @Retryer AOP 적용
- [x] 6-2. `CampaignPointPromotionListener.kt` - 포인트 메인 Consumer
  - Topic: `campaign-promotion-point-publish`
  - GroupId: `prepay-admin-campaign-point`
  - @Retryer AOP 적용

#### Retry Listener (`presentation/listener/`)
- [x] 6-3. `CampaignVoucherPromotionRetryListener.kt` - 상품권 재시도 Consumer
  - Topic: `campaign-promotion-voucher-retry`
  - GroupId: `prepay-admin-campaign-voucher-retry`
  - @Retryer AOP 적용
- [x] 6-4. `CampaignPointPromotionRetryListener.kt` - 포인트 재시도 Consumer
  - Topic: `campaign-promotion-point-retry`
  - GroupId: `prepay-admin-campaign-point-retry`
  - @Retryer AOP 적용

### Phase 6 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 6: Kafka Listener (Main/Retry)

- CampaignVoucherPromotionListener, CampaignPointPromotionListener
- CampaignVoucherPromotionRetryListener, CampaignPointPromotionRetryListener
- @Retryer AOP 적용
```

---

## Phase 7: Consumer Service + Message DTO ⏭️ SKIP

> **SKIP 사유**: ConsumerService는 단순 Processor 위임만 수행하여 불필요한 레이어로 판단
> - Phase 6에서 Listener → Processor 직접 호출 구조로 구현 완료
> - Message DTO는 Phase 4에서 이미 구현됨 (`CampaignPromotionVoucherMessage`, `CampaignPromotionPointMessage`)

### ~~구현 항목~~ (스킵)

#### ~~Service 클래스 (`application/`)~~
- [x] ~~7-1. `CampaignPromotionConsumerService.kt`~~ → 불필요 (Listener에서 Processor 직접 호출)

#### ~~Message DTO (`application/dto/`)~~
- [x] 7-2. `CampaignPromotionVoucherMessage.kt` → Phase 4에서 구현 완료
- [x] 7-3. `CampaignPromotionPointMessage.kt` → Phase 4에서 구현 완료

### Phase 7 완료 체크
- [x] **SKIP** - 불필요한 레이어로 판단하여 스킵

---

## Phase 8: Retry Listener + Retry Service ⏭️ SKIP

> **SKIP 사유**: Retry Listener는 Phase 6에서 함께 구현, RetryService는 불필요
> - Phase 6에서 Main/Retry Listener 모두 구현 완료
> - RetryService도 단순 위임만 수행하여 불필요

### ~~구현 항목~~ (스킵)

#### ~~Retry Listener (`presentation/listener/`)~~
- [x] 8-1. `CampaignVoucherPromotionRetryListener.kt` → Phase 6에서 구현 완료
- [x] 8-2. `CampaignPointPromotionRetryListener.kt` → Phase 6에서 구현 완료

#### ~~Retry Service (`application/`)~~
- [x] ~~8-3. `CampaignPromotionRetryService.kt`~~ → 불필요 (Listener에서 RetryProcessor 직접 호출)

### Phase 8 완료 체크
- [x] **SKIP** - Phase 6에서 Retry Listener 구현 완료, RetryService 불필요

---

## Phase 9: Redis Cache (현황 집계) ✅

### 구현 항목

#### Redis Entity (`infrastructure/redis/`)
- [x] 9-1. `CampaignPromotionSummaryRedisEntity.kt` - Redis Hash 엔티티
  - 필드: `promotionId`, `successCount`, `retrySuccessCount`, `failCount`, `lastCompletedAt`
  - TTL: 24시간

#### Redis Repository (`infrastructure/redis/`)
- [ ] 9-2. `RedisCampaignPromotionSummaryRepository.kt` - RedisTemplateHashRepository 상속
  - `incrementSuccessCount(promotionId: Long)`
  - `incrementRetrySuccessCount(promotionId: Long)`
  - `incrementFailCount(promotionId: Long)`
  - `updateLastCompletedAt(promotionId: Long)`

#### 테스트 코드
- [ ] 9-3. `RedisCampaignPromotionSummaryRepositoryTest.kt` - increment/update 테스트 (14개 테스트)
  - incrementSuccessCount 테스트 (3개)
  - incrementRetrySuccessCount 테스트 (2개)
  - incrementFailCount 테스트 (3개)
  - updateLastCompletedAt 테스트 (2개)
  - ensureKeyExists 테스트 (4개)

### Phase 9 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`) - 14개 테스트 통과
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 9: Redis Cache

- CampaignPromotionSummaryRedisEntity (Redis Hash)
- RedisCampaignPromotionSummaryRepository (increment, update)
- RedisCampaignPromotionSummaryRepositoryTest
```

---

## Phase 10: Kafka 설정 + 테스트 ✅

### 구현 항목

#### Kafka 설정 (`application-kafka.yml`)
- [x] 10-1. Consumer Topic 설정 추가
  - `campaign-promotion-voucher-publish`
  - `campaign-promotion-point-publish`
- [x] 10-2. Retry Topic 설정 추가
  - `campaign-promotion-voucher-retry`
  - `campaign-promotion-point-retry`

#### Listener 테스트 코드
- [x] 10-3. `CampaignVoucherPromotionListenerTest.kt` - 상품권 메인 Listener 테스트
- [x] 10-4. `CampaignPointPromotionListenerTest.kt` - 포인트 메인 Listener 테스트
- [x] 10-5. `CampaignVoucherPromotionRetryListenerTest.kt` - 상품권 Retry Listener 테스트
- [x] 10-6. `CampaignPointPromotionRetryListenerTest.kt` - 포인트 Retry Listener 테스트

### Phase 10 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 전체 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-954 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-954 Phase 10: Kafka 설정 + Listener 테스트

- application-kafka.yml Topic 설정 추가
- Listener 테스트 4종 (Main 2종 + Retry 2종)
```

---

## 최종 완료 체크리스트

### 전체 Phase 완료 확인
- [x] Phase 1: Domain Layer 완료
- [x] Phase 2: FeignClient + DTO + 테스트 완료
- [x] Phase 3: 캐시 설정 및 서비스 + 테스트 완료
- [x] Phase 4: Main Processor + Message DTO + 테스트 완료
- [x] Phase 5: Retry Processor + 테스트 완료
- [x] Phase 6: Kafka Listener (Main/Retry) 완료
- [x] Phase 7: ~~Consumer Service + Message DTO~~ → **SKIP** (불필요한 레이어)
- [x] Phase 8: ~~Retry Listener + Service~~ → **SKIP** (Phase 6에서 구현 완료)
- [x] Phase 9: Redis Cache + 테스트 완료
- [x] Phase 10: Kafka 설정 + Listener 테스트 완료

### 최종 MR 준비
- [ ] feature/PREPAY-954 → staging MR 생성
- [ ] 전체 빌드 성공 확인
- [ ] 전체 테스트 통과 확인
- [ ] 코드 리뷰 완료
- [ ] MR 승인 및 머지
