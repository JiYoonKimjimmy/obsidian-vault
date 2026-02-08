# 캠페인 프로모션 Consumer 구현 계획

## 1. 개요

### 1.1 목적

prepay-batch Publisher가 발행한 Kafka 메시지를 수신하여 Money API를 호출하고 결과를 저장하는 **Consumer** 역할을 구현합니다.

### 1.2 구현 범위

| 구분              | 범위                                                                 | 비고           |
|-----------------|--------------------------------------------------------------------|--------------|
| **해당 프로젝트**     | Kafka Consumer, Retry Consumer, Money API FeignClient, Redis Cache | prepay-admin |
| **제외 (타 프로젝트)** | Publisher Batch Job, Partitioner, 대상자 메시지 발행                       | prepay-batch |

### 1.3 설계 원칙

- **JPA Repository 사용** - prepay-admin 프로젝트 방향성에 따라 JPA 기반으로 구현
- **기존 패턴 준수** - `@Retryer` AOP, FeignClient Fallback Factory, RedisTemplateHashRepository 패턴 활용
- **멱등성 보장** - PK 기반 중복 처리 방지

---

## 2. 모듈 구조

### 2.1 프로젝트 패키지 구조

```
src/main/kotlin/com/musinsapayments/prepay/application/prepay/admin/
└── campaign/
    └── promotion/
        ├── application/                          # Service Layer
        │   ├── CampaignPromotionConsumerService.kt
        │   ├── CampaignPromotionRetryService.kt
        │   ├── CampaignPromotionStatusCacheService.kt  # 프로모션 상태 캐싱 서비스
        │   ├── processor/                        # Template Method 패턴 적용
        │   │   ├── AbstractPromotionProcessor.kt     # 추상 클래스 (Main Consumer 공통 로직)
        │   │   ├── VoucherPromotionProcessor.kt      # 상품권 처리 구현체
        │   │   ├── PointPromotionProcessor.kt        # 포인트 처리 구현체
        │   │   ├── AbstractPromotionRetryProcessor.kt         # 추상 클래스 (Retry Consumer 공통 로직)
        │   │   ├── VoucherRetryProcessor.kt          # 상품권 재시도 구현체
        │   │   └── PointRetryProcessor.kt            # 포인트 재시도 구현체
        │   └── dto/
        │       ├── CampaignVoucherPromotionMessage.kt   # Main + Retry 공용 (retryCount 포함)
        │       └── CampaignPointPromotionMessage.kt     # Main + Retry 공용 (retryCount 포함)
        │
        ├── domain/                               # Entity, Repository Interface
        │   ├── entity/
        │   │   ├── CampaignPromotion.kt
        │   │   ├── CampaignPromotionVoucherResult.kt
        │   │   └── CampaignPromotionPointResult.kt
        │   ├── repository/
        │   │   ├── CampaignPromotionRepository.kt
        │   │   ├── CampaignPromotionVoucherResultRepository.kt
        │   │   └── CampaignPromotionPointResultRepository.kt
        │   └── constant/
        │       ├── PromotionStatus.kt
        │       └── ProcessStatus.kt
        │
        ├── infrastructure/                       # JPA, FeignClient, Redis
        │   ├── persistence/
        │   │   ├── CampaignPromotionJpaRepository.kt
        │   │   ├── CampaignPromotionVoucherResultJpaRepository.kt
        │   │   └── CampaignPromotionPointResultJpaRepository.kt
        │   ├── feign/
        │   │   ├── MoneyCampaignChargeApi.kt              # 통합 인터페이스
        │   │   ├── MoneyCampaignChargeApiFallbackFactory.kt  # 통합 Fallback
        │   │   └── dto/
        │   │       ├── CampaignVoucherChargeRequest.kt
        │   │       ├── CampaignVoucherChargeResponse.kt
        │   │       ├── CampaignPointChargeRequest.kt
        │   │       └── CampaignPointChargeResponse.kt
        │   └── redis/
        │       ├── CampaignPromotionSummaryCache.kt
        │       └── CampaignPromotionSummaryCacheRepository.kt
        │
        └── presentation/                         # Kafka Listener
            └── listener/
                ├── CampaignVoucherPromotionListener.kt
                ├── CampaignPointPromotionListener.kt
                ├── CampaignVoucherRetryListener.kt
                └── CampaignPointRetryListener.kt
```

### 2.2 도메인 계층 구조

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Presentation Layer                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  CampaignVoucherPromotionListener    CampaignPointPromotionListener         │
│  CampaignVoucherRetryListener        CampaignPointRetryListener             │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Application Layer                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  CampaignPromotionConsumerService    CampaignPromotionRetryService          │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Processor Layer (Template Method)                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────┐    ┌─────────────────────────────────┐ │
│  │ AbstractPromotionProcessor<M,R> │    │ AbstractPromotionRetryProcessor<R>     │ │
│  │       (Main Consumer 흐름)       │    │     (Retry Consumer 흐름)        │ │
│  │    ┌──────────┴──────────┐      │    │    ┌──────────┴──────────┐      │ │
│  │    ▼                     ▼      │    │    ▼                     ▼      │ │
│  │ Voucher              Point      │    │ Voucher               Point     │ │
│  │ Promotion            Promotion  │    │ Retry                 Retry     │ │
│  │ Processor            Processor  │    │ Processor             Processor │ │
│  └─────────────────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
┌─────────────────────────┐ ┌─────────────────────┐ ┌─────────────────────────┐
│     Domain Layer        │ │  Infrastructure     │ │   Infrastructure        │
│                         │ │  (FeignClient)      │ │   (Redis)               │
├─────────────────────────┤ ├─────────────────────┤ ├─────────────────────────┤
│ CampaignPromotion       │ │ MoneyCampaignCharge │ │ CampaignPromotionSummary│
│ VoucherResult           │ │ Api                 │ │ CacheRepository         │
│ PointResult             │ │                     │ │                         │
└─────────────────────────┘ └─────────────────────┘ └─────────────────────────┘
```

---

## 3. Consumer 처리 흐름

### 3.1 전체 흐름 다이어그램

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                        Campaign Promotion Consumer Flow                               │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 1. Kafka Message 수신 (Main Consumer)                                        │    │
│  │    - VoucherPromotionListener: campaign-promotion-voucher-publish           │    │
│  │    - PointPromotionListener: campaign-promotion-point-publish               │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                       │                                              │
│                                       ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 2. 프로모션 상태 확인                                                          │    │
│  │    - campaign_promotions 테이블 조회                                          │    │
│  │    - promotion_status == 'IN_PROGRESS' 확인                                  │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                       │                                              │
│                                       ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 3. 처리 결과 저장 (멱등성 - Insert-or-Catch)                                    │    │
│  │    - campaign_promotion_voucher_results / point_results INSERT               │    │
│  │    - PK 중복 시 DataIntegrityViolationException → Skip                       │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                       │                                              │
│                                       ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 4. Money API 호출                                                            │    │
│  │    - 상품권: /internal/v1/campaigns/voucher/charge                           │    │
│  │    - 포인트: /internal/v1/campaigns/point/charge                             │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                       │                                              │
│                    ┌──────────────────┴──────────────────┐                          │
│                    ▼                                     ▼                          │
│  ┌─────────────────────────────┐        ┌─────────────────────────────┐             │
│  │ 5a. 성공 처리                 │        │ 5b. 실패 처리                 │             │
│  │ - process_status = SUCCESS  │        │ - process_status = RETRYING │             │
│  │ - Redis success_count++     │        │ - Retry Topic 메시지 발행     │             │
│  │ - Redis last_completed_at   │        │   (retry_count = 1)         │             │
│  └─────────────────────────────┘        └─────────────────────────────┘             │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 메인 Consumer 처리 흐름

시퀀스 다이어그램의 **3단계 (Consumer - 메시지 소비 및 API 호출)** 기준:

| 순서 | 발신자      | 수신자       | 동작                                                                                                                                                                                       |
|:--:|----------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 13 | Kafka    | Consumer  | 프로모션 대상 정보 메시지 수신                                                                                                                                                                        |
| 14 | Consumer | MySQL DB  | 프로모션 진행 상태 조회 및 확인<br>`campaign_promotions`<br>WHERE `promotion_id = ?`, CHECK `promotion_status = 'IN_PROGRESS'`                                                                        |
| 15 | Consumer | MySQL DB  | 프로모션 처리 결과 정보 저장 - Insert-or-Catch 패턴<br>`campaign_promotion_voucher_results` / `campaign_promotion_point_results`<br>INSERT 시도 → PK 중복 시 `DataIntegrityViolationException` catch → Skip |
| 16 | Consumer | Money API | 프로모션 상품권/포인트 충전 API 요청                                                                                                                                                                   |

#### 성공 시:

| 순서 | 발신자       | 수신자      | 동작                                                                                                                                |
|:--:|-----------|----------|-----------------------------------------------------------------------------------------------------------------------------------|
| 17 | Money API | Consumer | 성공 응답                                                                                                                             |
| 18 | Consumer  | MySQL DB | 프로모션 처리 결과 정보 변경<br>`campaign_promotion_voucher_results` / `campaign_promotion_point_results`<br>SET `process_status = 'SUCCESS'` |
| 19 | Consumer  | Redis    | 프로모션 현황 캐시 `success_count` 업데이트                                                                                                   |
| 20 | Consumer  | Redis    | 프로모션 현황 캐시 `last_completed_at` 업데이트                                                                                               |

#### 실패 시:

| 순서 | 발신자       | 수신자      | 동작                                                                                                                                 |
|:--:|-----------|----------|------------------------------------------------------------------------------------------------------------------------------------|
| 17 | Money API | Consumer | 실패 응답                                                                                                                              |
| 18 | Consumer  | MySQL DB | 프로모션 처리 결과 정보 변경<br>`campaign_promotion_voucher_results` / `campaign_promotion_point_results`<br>SET `process_status = 'RETRYING'` |
| 19 | Consumer  | Kafka    | Retry Topic으로 메시지 발행 (`retry_count = 1`)                                                                                           |

#### 중복 요청 시:

| 순서 | 발신자      | 수신자 | 동작                   |
|:--:|----------|-----|----------------------|
| -  | Consumer | -   | 중복 요청으로 처리 종료 (Skip) |

### 3.3 Retry Consumer 처리 흐름

시퀀스 다이어그램의 **4단계 (Retry Consumer - 재시도 처리)** 기준:

| 순서 | 발신자            | 수신자            | 동작                          |
|:--:|----------------|----------------|-----------------------------|
| 21 | Kafka          | Retry Consumer | Retry 메시지 수신                |
| 22 | Retry Consumer | -              | 지연 대기 (Exponential Backoff) |
| 23 | Retry Consumer | Money API      | 프로모션 처리 API 재요청             |

#### 재시도 성공 시:

| 순서 | 발신자            | 수신자            | 동작                                                                                                                                |
|:--:|----------------|----------------|-----------------------------------------------------------------------------------------------------------------------------------|
| 24 | Money API      | Retry Consumer | 성공 응답                                                                                                                             |
| 25 | Retry Consumer | MySQL DB       | 프로모션 처리 결과 정보 변경<br>`campaign_promotion_voucher_results` / `campaign_promotion_point_results`<br>SET `process_status = 'SUCCESS'` |
| 26 | Retry Consumer | Redis          | 프로모션 현황 캐시 `retry_success_count` 업데이트                                                                                             |
| 27 | Retry Consumer | Redis          | 프로모션 현황 캐시 `last_completed_at` 업데이트                                                                                               |

#### 재시도 실패 시 (5회 미만):

| 순서 | 발신자            | 수신자            | 동작                              |
|:--:|----------------|----------------|---------------------------------|
| 24 | Money API      | Retry Consumer | 실패 응답                           |
| 25 | Retry Consumer | Kafka          | Retry 메시지 재발행 (`retry_count++`) |

#### 최종 실패 시 (5회 이상):

| 순서 | 발신자            | 수신자            | 동작                                                                                                                               |
|:--:|----------------|----------------|----------------------------------------------------------------------------------------------------------------------------------|
| 24 | Money API      | Retry Consumer | 실패 응답                                                                                                                            |
| 25 | Retry Consumer | MySQL DB       | 프로모션 처리 결과 정보 변경<br>`campaign_promotion_voucher_results` / `campaign_promotion_point_results`<br>SET `process_status = 'FAILED'` |
| 26 | Retry Consumer | Kafka DLT      | 최종 실패 DLT 메시지 발행                                                                                                                 |
| 27 | Retry Consumer | Redis          | 프로모션 현황 캐시 `fail_count` 업데이트                                                                                                     |
| 28 | Retry Consumer | Redis          | 프로모션 현황 캐시 `last_completed_at` 업데이트                                                                                              |

### 3.4 상태 전이 다이어그램

#### ProcessStatus 상태 전이 (Consumer 처리 결과)

```
    ┌─────────────────────────────────────────┐
    │              (초기 상태 없음)              │
    │     Consumer가 메시지 수신 후 결과 INSERT    │
    └─────────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
    ┌───────────┐           ┌───────────┐
    │  SUCCESS  │           │ RETRYING  │
    │ (처리 성공) │           │ (재시도중)  │
    └───────────┘           └───────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                    ▼                           ▼
            ┌───────────┐               ┌───────────┐
            │  SUCCESS  │               │  FAILED   │
            │(재시도 성공) │               │ (최종 실패) │
            └───────────┘               └───────────┘
```

---

## 4. 코드 구현 상세

### 4.1 Kafka Listener (Consumer)

**참조 패턴**: `voucher/campaign/presentation/listener/CampaignIssueCompletedListener.kt`

#### 4.1.1 CampaignVoucherPromotionListener.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.presentation.listener

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionConsumerService
import com.musinsapayments.prepay.application.prepay.admin.core.aop.Retryer
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.kafka.support.Acknowledgment
import org.springframework.kafka.support.KafkaHeaders
import org.springframework.messaging.handler.annotation.Header
import org.springframework.stereotype.Component

@Component
class CampaignVoucherPromotionListener(
    private val consumerService: CampaignPromotionConsumerService
) {
    private val log = KotlinLogging.logger {}

    @Retryer
    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-voucher-publish}"],
        groupId = "prepay-admin-campaign-voucher"
    )
    fun consume(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "CampaignVoucherPromotionListener - key: $key" }
        log.debug { "CampaignVoucherPromotionListener - message: $message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "Missing key or message: key=$key" }
            return
        }

        consumerService.processVoucherPromotion(message)
    }
}
```

#### 4.1.2 CampaignPointPromotionListener.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.presentation.listener

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionConsumerService
import com.musinsapayments.prepay.application.prepay.admin.core.aop.Retryer
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.kafka.support.Acknowledgment
import org.springframework.kafka.support.KafkaHeaders
import org.springframework.messaging.handler.annotation.Header
import org.springframework.stereotype.Component

@Component
class CampaignPointPromotionListener(
    private val consumerService: CampaignPromotionConsumerService
) {
    private val log = KotlinLogging.logger {}

    @Retryer
    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-point-publish}"],
        groupId = "prepay-admin-campaign-point"
    )
    fun consume(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "CampaignPointPromotionListener - key: $key" }
        log.debug { "CampaignPointPromotionListener - message: $message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "Missing key or message: key=$key" }
            return
        }

        consumerService.processPointPromotion(message)
    }
}
```

#### 4.1.3 CampaignVoucherRetryListener.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.presentation.listener

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionRetryService
import com.musinsapayments.prepay.application.prepay.admin.core.aop.Retryer
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.kafka.support.Acknowledgment
import org.springframework.kafka.support.KafkaHeaders
import org.springframework.messaging.handler.annotation.Header
import org.springframework.stereotype.Component

@Component
class CampaignVoucherRetryListener(
    private val retryService: CampaignPromotionRetryService
) {
    private val log = KotlinLogging.logger {}

    @Retryer
    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-voucher-retry}"],
        groupId = "prepay-admin-campaign-voucher-retry"
    )
    fun consume(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "CampaignVoucherRetryListener - key: $key" }
        log.debug { "CampaignVoucherRetryListener - message: $message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "Missing key or message: key=$key" }
            return
        }

        retryService.retryVoucherPromotion(message)
    }
}
```

#### 4.1.4 CampaignPointRetryListener.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.presentation.listener

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionRetryService
import com.musinsapayments.prepay.application.prepay.admin.core.aop.Retryer
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.kafka.support.Acknowledgment
import org.springframework.kafka.support.KafkaHeaders
import org.springframework.messaging.handler.annotation.Header
import org.springframework.stereotype.Component

@Component
class CampaignPointRetryListener(
    private val retryService: CampaignPromotionRetryService
) {
    private val log = KotlinLogging.logger {}

    @Retryer
    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-point-retry}"],
        groupId = "prepay-admin-campaign-point-retry"
    )
    fun consume(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "CampaignPointRetryListener - key: $key" }
        log.debug { "CampaignPointRetryListener - message: $message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "Missing key or message: key=$key" }
            return
        }

        retryService.retryPointPromotion(message)
    }
}
```

### 4.2 Processor Layer (Template Method 패턴)

공통 비즈니스 로직을 추상화하여 코드 중복을 제거합니다.

- **Main Processor**: `AbstractPromotionProcessor<M, R>` - Kafka 메시지 수신 → Money API 호출 → 결과 저장
- **Retry Processor**: `AbstractPromotionRetryProcessor<R>` - Exponential Backoff → Money API 재호출 → 성공/최종실패 처리

#### 4.2.0 클래스 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              AbstractPromotionProcessor<M, R>                               │
│              (추상 클래스 - 공통 처리 흐름 정의)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  + process(message: String)              ← 템플릿 메서드 (final)              │
│  # parseMessage(json: String): M         ← 추상 메서드                       │
│  # getPromotionId(message: M): Long      ← 추상 메서드                       │
│  # getTargetId(message: M): Long         ← 추상 메서드                       │
│  # createResult(message: M): R           ← 추상 메서드                       │
│  # saveResult(result: R)                 ← 추상 메서드                       │
│  # existsResult(targetId: Long): Boolean ← 추상 메서드                       │
│  # callMoneyApi(message: M): Boolean     ← 추상 메서드                       │
│  # updateSuccess(result: R)              ← 추상 메서드                       │
│  # buildRetryMessage(message: M): Retry  ← 추상 메서드                       │
│  # getRetryTopic(): String               ← 추상 메서드                       │
│  # getPromotionType(): String            ← 추상 메서드                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    △
            ┌───────────────────────┴───────────────────────┐
            │                                               │
┌───────────────────────────────┐           ┌───────────────────────────────┐
│   VoucherPromotionProcessor   │           │    PointPromotionProcessor    │
├───────────────────────────────┤           ├───────────────────────────────┤
│ M = CampaignVoucherPromotion  │           │ M = CampaignPointPromotion    │
│     Message                   │           │     Message                   │
│ R = CampaignPromotionVoucher  │           │ R = CampaignPromotionPoint    │
│     Result                    │           │     Result                    │
├───────────────────────────────┤           ├───────────────────────────────┤
│ - voucherResultRepository     │           │ - pointResultRepository       │
│ - chargeVoucher() 호출         │           │ - chargePoint() 호출           │
│ - voucher-retry topic         │           │ - point-retry topic           │
└───────────────────────────────┘           └───────────────────────────────┘
```

#### 4.2.1 AbstractPromotionProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionStatusCacheService
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

/**
 * 프로모션 처리 공통 로직을 정의하는 추상 클래스 (Template Method 패턴)
 *
 * @param M 메시지 타입 (CampaignVoucherPromotionMessage, CampaignPointPromotionMessage)
 * @param R 결과 엔티티 타입 (CampaignPromotionVoucherResult, CampaignPromotionPointResult)
 */
abstract class AbstractPromotionProcessor<M, R>(
    protected val objectMapper: ObjectMapper,
    protected val promotionStatusCacheService: CampaignPromotionStatusCacheService,
    protected val summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    protected val kafkaTemplate: KafkaTemplate<String, String>
) {
    protected val log = KotlinLogging.logger {}

    /**
     * 템플릿 메서드 - 프로모션 처리 공통 흐름 정의
     * 하위 클래스에서 오버라이드 불가 (final)
     */
    @Transactional
    fun process(messageJson: String) {
        // 1. 메시지 파싱
        val message = parseMessage(messageJson)
        val promotionId = getPromotionId(message)
        val targetId = getTargetId(message)

        log.info { "Processing ${getPromotionType()} promotion - promotionId: $promotionId, targetId: $targetId" }

        // 2. 프로모션 상태 확인 (캐시 조회)
        if (!promotionStatusCacheService.isPromotionInProgress(promotionId)) {
            log.warn { "Promotion not in progress - promotionId: $promotionId (Skip)" }
            return
        }

        // 3. 처리 결과 INSERT (멱등성 - PK 중복 시 Skip)
        val result = createResult(message)
        try {
            saveResult(result)
        } catch (e: DataIntegrityViolationException) {
            log.info { "Already processed - targetId: $targetId (Skip due to duplicate key)" }
            return
        }

        // 4. Money API 호출
        try {
            val moneyKey = callMoneyApi(message)

            if (moneyKey != null) {
                // 성공 처리 - moneyKey를 transactionKey로 저장
                updateSuccess(result, moneyKey)
                saveResult(result)

                // Redis 캐시 업데이트
                summaryCacheRepository.incrementSuccessCount(promotionId)
                summaryCacheRepository.updateLastCompletedAt(promotionId, LocalDateTime.now())

                log.info { "${getPromotionType()} charge success - targetId: $targetId, transactionKey: $moneyKey" }
            } else {
                // 실패 처리 -> Retry Topic 발행
                handleFailure(message, result, "API returned failure")
            }
        } catch (e: Exception) {
            log.error(e) { "${getPromotionType()} charge failed - targetId: $targetId" }
            handleFailure(message, result, e.message)
        }
    }

    /**
     * 실패 처리 - 에러 업데이트 및 Retry 메시지 발행
     */
    protected fun handleFailure(message: M, result: R, errorMessage: String?) {
        updateError(result, errorMessage)
        saveResult(result)

        // Retry 메시지 발행
        val retryMessage = buildRetryMessage(message)
        kafkaTemplate.send(
            getRetryTopic(),
            getTargetId(message).toString(),
            objectMapper.writeValueAsString(retryMessage)
        )

        log.info { "${getPromotionType()} retry message sent - targetId: ${getTargetId(message)}, retryCount: 1" }
    }

    // ===== 추상 메서드 (하위 클래스에서 구현) =====

    /** 메시지 JSON을 객체로 파싱 */
    protected abstract fun parseMessage(json: String): M

    /** 메시지에서 프로모션 ID 추출 */
    protected abstract fun getPromotionId(message: M): Long

    /** 메시지에서 대상자 ID 추출 */
    protected abstract fun getTargetId(message: M): Long

    /** 처리 결과 엔티티 생성 */
    protected abstract fun createResult(message: M): R

    /** 처리 결과 저장 */
    protected abstract fun saveResult(result: R)

    /** Money API 호출 (성공 시 moneyKey 반환, 실패 시 null) */
    protected abstract fun callMoneyApi(message: M): String?

    /** 성공 상태로 업데이트 (transactionKey 저장) */
    protected abstract fun updateSuccess(result: R, transactionKey: String?)

    /** 에러 상태로 업데이트 */
    protected abstract fun updateError(result: R, errorMessage: String?)

    /** Retry 메시지 생성 (retryCount 증가된 동일 타입 메시지 반환) */
    protected abstract fun buildRetryMessage(message: M): M

    /** Retry Topic 이름 반환 */
    protected abstract fun getRetryTopic(): String

    /** 프로모션 타입 반환 (로깅용) */
    protected abstract fun getPromotionType(): String
}
```

#### 4.2.2 VoucherPromotionProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionStatusCacheService
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto.CampaignVoucherPromotionMessage
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.ProcessStatus
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionVoucherResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionVoucherResultRepository
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.MoneyCampaignChargeApi
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.stereotype.Component

@Component
class VoucherPromotionProcessor(
    objectMapper: ObjectMapper,
    promotionStatusCacheService: CampaignPromotionStatusCacheService,
    summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    kafkaTemplate: KafkaTemplate<String, String>,
    private val voucherResultRepository: CampaignPromotionVoucherResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi
) : AbstractPromotionProcessor<CampaignVoucherPromotionMessage, CampaignPromotionVoucherResult>(
    objectMapper, promotionStatusCacheService, summaryCacheRepository, kafkaTemplate
) {
    companion object {
        private const val RETRY_TOPIC = "campaign-promotion-voucher-retry"
    }

    override fun parseMessage(json: String): CampaignVoucherPromotionMessage {
        return objectMapper.readValue(json, CampaignVoucherPromotionMessage::class.java)
    }

    override fun getPromotionId(message: CampaignVoucherPromotionMessage): Long {
        return message.promotionId.toLong()
    }

    override fun getTargetId(message: CampaignVoucherPromotionMessage): Long {
        return message.voucherTargetId.toLong()
    }

    override fun createResult(message: CampaignVoucherPromotionMessage): CampaignPromotionVoucherResult {
        return CampaignPromotionVoucherResult(
            voucherTargetId = message.voucherTargetId.toLong(),
            promotionId = message.promotionId.toLong(),
            processStatus = ProcessStatus.RETRYING
        )
    }

    override fun saveResult(result: CampaignPromotionVoucherResult) {
        voucherResultRepository.save(result)
    }

    override fun callMoneyApi(message: CampaignVoucherPromotionMessage): String? {
        val request = CampaignVoucherChargeRequest(
            customerUid = message.customerUid.toLong(),
            merchantCode = message.merchantCode,
            campaignCode = message.campaignCode,
            amount = message.amount.toLong(),
            voucherNumber = message.voucherNumber,
            description = message.description,
            expiredAt = message.validUntil,      // validUntil → expiredAt (Money API 필드명)
            isWithdrawal = message.isWithdrawal
        )

        val response = moneyCampaignChargeApi.chargeVoucher(request)
        return if (response.meta?.result == "SUCCESS") {
            response.data?.moneyKey  // 성공 시 moneyKey 반환 (transactionKey로 저장됨)
        } else {
            null
        }
    }

    override fun updateSuccess(result: CampaignPromotionVoucherResult, transactionKey: String?) {
        result.updateSuccess(transactionKey)
    }

    override fun updateError(result: CampaignPromotionVoucherResult, errorMessage: String?) {
        result.updateError(errorMessage)
    }

    override fun buildRetryMessage(message: CampaignVoucherPromotionMessage): CampaignVoucherPromotionMessage {
        return message.copy(retryCount = message.retryCount + 1)
    }

    override fun getRetryTopic(): String = RETRY_TOPIC

    override fun getPromotionType(): String = "Voucher"
}
```

#### 4.2.3 PointPromotionProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.CampaignPromotionStatusCacheService
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto.CampaignPointPromotionMessage
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.ProcessStatus
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionPointResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionPointResultRepository
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.MoneyCampaignChargeApi
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.stereotype.Component

@Component
class PointPromotionProcessor(
    objectMapper: ObjectMapper,
    promotionStatusCacheService: CampaignPromotionStatusCacheService,
    summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    kafkaTemplate: KafkaTemplate<String, String>,
    private val pointResultRepository: CampaignPromotionPointResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi
) : AbstractPromotionProcessor<CampaignPointPromotionMessage, CampaignPromotionPointResult>(
    objectMapper, promotionStatusCacheService, summaryCacheRepository, kafkaTemplate
) {
    companion object {
        private const val RETRY_TOPIC = "campaign-promotion-point-retry"
    }

    override fun parseMessage(json: String): CampaignPointPromotionMessage {
        return objectMapper.readValue(json, CampaignPointPromotionMessage::class.java)
    }

    override fun getPromotionId(message: CampaignPointPromotionMessage): Long {
        return message.promotionId.toLong()
    }

    override fun getTargetId(message: CampaignPointPromotionMessage): Long {
        return message.pointTargetId.toLong()
    }

    override fun createResult(message: CampaignPointPromotionMessage): CampaignPromotionPointResult {
        return CampaignPromotionPointResult(
            pointTargetId = message.pointTargetId.toLong(),
            promotionId = message.promotionId.toLong(),
            processStatus = ProcessStatus.RETRYING
        )
    }

    override fun saveResult(result: CampaignPromotionPointResult) {
        pointResultRepository.save(result)
    }

    override fun callMoneyApi(message: CampaignPointPromotionMessage): String? {
        val request = CampaignPointChargeRequest(
            customerUid = message.customerUid.toLong(),
            merchantCode = message.merchantCode,
            campaignCode = message.campaignCode,
            amount = message.amount.toLong(),
            description = message.description,
            expiredAt = message.expiredAt
        )

        val response = moneyCampaignChargeApi.chargePoint(request)
        return if (response.meta?.result == "SUCCESS") {
            response.data?.moneyKey  // 성공 시 moneyKey 반환 (transactionKey로 저장됨)
        } else {
            null
        }
    }

    override fun updateSuccess(result: CampaignPromotionPointResult, transactionKey: String?) {
        result.updateSuccess(transactionKey)
    }

    override fun updateError(result: CampaignPromotionPointResult, errorMessage: String?) {
        result.updateError(errorMessage)
    }

    override fun buildRetryMessage(message: CampaignPointPromotionMessage): CampaignPointPromotionMessage {
        return message.copy(retryCount = message.retryCount + 1)
    }

    override fun getRetryTopic(): String = RETRY_TOPIC

    override fun getPromotionType(): String = "Point"
}
```

#### 4.2.4 AbstractPromotionRetryProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import kotlin.math.pow

/**
 * 재시도 처리 공통 로직을 정의하는 추상 클래스 (Template Method 패턴)
 *
 * @param M 메시지 타입 (CampaignVoucherPromotionMessage, CampaignPointPromotionMessage)
 * @param R 결과 엔티티 타입 (CampaignPromotionVoucherResult, CampaignPromotionPointResult)
 */
abstract class AbstractPromotionRetryProcessor<M : Any, R>(
    protected val objectMapper: ObjectMapper,
    protected val summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    protected val kafkaTemplate: KafkaTemplate<String, String>
) {
    protected val log = KotlinLogging.logger {}

    companion object {
        private const val MAX_RETRY_COUNT = 5
        private const val BASE_DELAY_MS = 1000L
    }

    /**
     * 템플릿 메서드 - 재시도 처리 공통 흐름 정의
     */
    @Transactional
    fun processRetry(messageJson: String) {
        // 1. 메시지 파싱
        val message = objectMapper.readValue(messageJson, getMessageClass())
        val targetId = getTargetId(message)
        val retryCount = getRetryCount(message)
        val promotionId = getPromotionId(message)

        log.info { "Retry ${getPromotionType()} promotion - targetId: $targetId, retryCount: $retryCount" }

        // 2. Exponential Backoff 지연
        runBlocking {
            val delayMs = BASE_DELAY_MS * 2.0.pow(retryCount.toDouble()).toLong()
            log.debug { "Delay before retry - delayMs: $delayMs" }
            delay(delayMs)
        }

        // 3. 기존 결과 레코드 조회
        val result = findResult(targetId)
            ?: run {
                log.error { "${getPromotionType()} result not found - targetId: $targetId" }
                return
            }

        // 4. Money API 호출
        try {
            val moneyKey = callMoneyApi(message)

            if (moneyKey != null) {
                // 재시도 성공 - moneyKey를 transactionKey로 저장
                updateSuccess(result, moneyKey)
                saveResult(result)

                summaryCacheRepository.incrementRetrySuccessCount(promotionId)
                summaryCacheRepository.updateLastCompletedAt(promotionId, LocalDateTime.now())

                log.info { "${getPromotionType()} retry success - targetId: $targetId, transactionKey: $moneyKey" }
            } else {
                handleRetryFailure(message, result, "API returned failure")
            }
        } catch (e: Exception) {
            log.error(e) { "${getPromotionType()} retry failed - targetId: $targetId" }
            handleRetryFailure(message, result, e.message)
        }
    }

    /**
     * 재시도 실패 처리 - 재발행 또는 최종 실패
     */
    protected fun handleRetryFailure(message: M, result: R, errorMessage: String?) {
        val targetId = getTargetId(message)
        val promotionId = getPromotionId(message)
        val newRetryCount = getRetryCount(message) + 1

        if (newRetryCount >= MAX_RETRY_COUNT) {
            // 최종 실패 처리
            updateFailed(result, errorMessage)
            saveResult(result)

            summaryCacheRepository.incrementFailCount(promotionId)
            summaryCacheRepository.updateLastCompletedAt(promotionId, LocalDateTime.now())

            log.warn { "${getPromotionType()} final failure - targetId: $targetId, errorMessage: $errorMessage" }
            // DLT 발행은 @Retryer AOP에서 자동 처리됨
        } else {
            // 재시도 메시지 재발행
            updateError(result, errorMessage)
            saveResult(result)

            val newRetryMessage = incrementRetryCount(message)
            kafkaTemplate.send(
                getRetryTopic(),
                targetId.toString(),
                objectMapper.writeValueAsString(newRetryMessage)
            )

            log.info { "${getPromotionType()} retry message re-sent - targetId: $targetId, retryCount: $newRetryCount" }
        }
    }

    // ===== 추상 메서드 (하위 클래스에서 구현) =====

    /** 메시지 클래스 반환 */
    protected abstract fun getMessageClass(): Class<M>

    /** 메시지에서 targetId 추출 */
    protected abstract fun getTargetId(message: M): Long

    /** 메시지에서 promotionId 추출 */
    protected abstract fun getPromotionId(message: M): Long

    /** 메시지에서 retryCount 추출 */
    protected abstract fun getRetryCount(message: M): Int

    /** retryCount를 증가시킨 새 메시지 반환 */
    protected abstract fun incrementRetryCount(message: M): M

    /** 기존 결과 레코드 조회 */
    protected abstract fun findResult(targetId: Long): R?

    /** Money API 호출 (성공 시 moneyKey 반환, 실패 시 null) */
    protected abstract fun callMoneyApi(message: M): String?

    /** 성공 상태로 업데이트 (transactionKey 저장) */
    protected abstract fun updateSuccess(result: R, transactionKey: String?)

    /** 에러 상태로 업데이트 */
    protected abstract fun updateError(result: R, errorMessage: String?)

    /** 최종 실패 상태로 업데이트 */
    protected abstract fun updateFailed(result: R, errorMessage: String?)

    /** 결과 저장 */
    protected abstract fun saveResult(result: R)

    /** Retry Topic 이름 반환 */
    protected abstract fun getRetryTopic(): String

    /** 프로모션 타입 반환 (로깅용) */
    protected abstract fun getPromotionType(): String
}
```

#### 4.2.5 VoucherRetryProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto.CampaignVoucherPromotionMessage
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionVoucherResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionVoucherResultRepository
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.MoneyCampaignChargeApi
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.stereotype.Component

@Component
class VoucherRetryProcessor(
    objectMapper: ObjectMapper,
    summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    kafkaTemplate: KafkaTemplate<String, String>,
    private val voucherResultRepository: CampaignPromotionVoucherResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi
) : AbstractPromotionRetryProcessor<CampaignVoucherPromotionMessage, CampaignPromotionVoucherResult>(
    objectMapper, summaryCacheRepository, kafkaTemplate
) {
    companion object {
        private const val RETRY_TOPIC = "campaign-promotion-voucher-retry"
    }

    override fun getMessageClass(): Class<CampaignVoucherPromotionMessage> =
        CampaignVoucherPromotionMessage::class.java

    override fun getTargetId(message: CampaignVoucherPromotionMessage): Long = message.voucherTargetId.toLong()

    override fun getPromotionId(message: CampaignVoucherPromotionMessage): Long = message.promotionId.toLong()

    override fun getRetryCount(message: CampaignVoucherPromotionMessage): Int = message.retryCount

    override fun incrementRetryCount(message: CampaignVoucherPromotionMessage): CampaignVoucherPromotionMessage =
        message.copy(retryCount = message.retryCount + 1)

    override fun findResult(targetId: Long): CampaignPromotionVoucherResult? {
        return voucherResultRepository.findByVoucherTargetId(targetId)
    }

    override fun callMoneyApi(message: CampaignVoucherPromotionMessage): String? {
        val request = CampaignVoucherChargeRequest(
            customerUid = message.customerUid.toLong(),
            merchantCode = message.merchantCode,
            campaignCode = message.campaignCode,
            amount = message.amount.toLong(),
            voucherNumber = message.voucherNumber,
            description = message.description,
            expiredAt = message.validUntil,      // validUntil → expiredAt (Money API 필드명)
            isWithdrawal = message.isWithdrawal
        )

        val response = moneyCampaignChargeApi.chargeVoucher(request)
        return if (response.meta?.result == "SUCCESS") {
            response.data?.moneyKey  // 성공 시 moneyKey 반환 (transactionKey로 저장됨)
        } else {
            null
        }
    }

    override fun updateSuccess(result: CampaignPromotionVoucherResult, transactionKey: String?) {
        result.updateSuccess(transactionKey)
    }

    override fun updateError(result: CampaignPromotionVoucherResult, errorMessage: String?) {
        result.updateError(errorMessage)
    }

    override fun updateFailed(result: CampaignPromotionVoucherResult, errorMessage: String?) {
        result.updateFailed(errorMessage)
    }

    override fun saveResult(result: CampaignPromotionVoucherResult) {
        voucherResultRepository.save(result)
    }

    override fun getRetryTopic(): String = RETRY_TOPIC

    override fun getPromotionType(): String = "Voucher"
}
```

#### 4.2.6 PointRetryProcessor.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto.CampaignPointPromotionMessage
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionPointResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionPointResultRepository
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.MoneyCampaignChargeApi
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis.CampaignPromotionSummaryCacheRepository
import org.springframework.kafka.core.KafkaTemplate
import org.springframework.stereotype.Component

@Component
class PointRetryProcessor(
    objectMapper: ObjectMapper,
    summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    kafkaTemplate: KafkaTemplate<String, String>,
    private val pointResultRepository: CampaignPromotionPointResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi
) : AbstractPromotionRetryProcessor<CampaignPointPromotionMessage, CampaignPromotionPointResult>(
    objectMapper, summaryCacheRepository, kafkaTemplate
) {
    companion object {
        private const val RETRY_TOPIC = "campaign-promotion-point-retry"
    }

    override fun getMessageClass(): Class<CampaignPointPromotionMessage> =
        CampaignPointPromotionMessage::class.java

    override fun getTargetId(message: CampaignPointPromotionMessage): Long = message.pointTargetId.toLong()

    override fun getPromotionId(message: CampaignPointPromotionMessage): Long = message.promotionId.toLong()

    override fun getRetryCount(message: CampaignPointPromotionMessage): Int = message.retryCount

    override fun incrementRetryCount(message: CampaignPointPromotionMessage): CampaignPointPromotionMessage =
        message.copy(retryCount = message.retryCount + 1)

    override fun findResult(targetId: Long): CampaignPromotionPointResult? {
        return pointResultRepository.findByPointTargetId(targetId)
    }

    override fun callMoneyApi(message: CampaignPointPromotionMessage): String? {
        val request = CampaignPointChargeRequest(
            customerUid = message.customerUid.toLong(),
            merchantCode = message.merchantCode,
            campaignCode = message.campaignCode,
            amount = message.amount.toLong(),
            description = message.description,
            expiredAt = message.expiredAt
        )

        val response = moneyCampaignChargeApi.chargePoint(request)
        return if (response.meta?.result == "SUCCESS") {
            response.data?.moneyKey  // 성공 시 moneyKey 반환 (transactionKey로 저장됨)
        } else {
            null
        }
    }

    override fun updateSuccess(result: CampaignPromotionPointResult, transactionKey: String?) {
        result.updateSuccess(transactionKey)
    }

    override fun updateError(result: CampaignPromotionPointResult, errorMessage: String?) {
        result.updateError(errorMessage)
    }

    override fun updateFailed(result: CampaignPromotionPointResult, errorMessage: String?) {
        result.updateFailed(errorMessage)
    }

    override fun saveResult(result: CampaignPromotionPointResult) {
        pointResultRepository.save(result)
    }

    override fun getRetryTopic(): String = RETRY_TOPIC

    override fun getPromotionType(): String = "Point"
}
```

### 4.3 Application Service Layer

#### 4.3.1 CampaignPromotionConsumerService.kt

Processor를 사용하여 단순화된 서비스 클래스입니다.

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor.PointPromotionProcessor
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor.VoucherPromotionProcessor
import org.springframework.stereotype.Service

/**
 * 프로모션 Consumer 서비스
 * - Processor에 처리를 위임하여 코드 중복 제거
 * - 공통 로직은 AbstractPromotionProcessor에서 관리
 */
@Service
class CampaignPromotionConsumerService(
    private val voucherPromotionProcessor: VoucherPromotionProcessor,
    private val pointPromotionProcessor: PointPromotionProcessor
) {
    /**
     * 상품권 프로모션 처리
     * @param message Kafka 메시지 (JSON)
     */
    fun processVoucherPromotion(message: String) {
        voucherPromotionProcessor.process(message)
    }

    /**
     * 포인트 프로모션 처리
     * @param message Kafka 메시지 (JSON)
     */
    fun processPointPromotion(message: String) {
        pointPromotionProcessor.process(message)
    }
}
```

**장점**:
- 코드 중복 제거 (공통 로직은 `AbstractPromotionProcessor`에서 관리)
- 새로운 프로모션 타입 추가 시 Processor만 구현하면 됨
- 테스트 용이 (Processor 단위 테스트 가능)

#### 4.3.2 CampaignPromotionRetryService.kt

Processor를 사용하여 단순화된 재시도 서비스 클래스입니다.

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor.PointRetryProcessor
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.processor.VoucherRetryProcessor
import org.springframework.stereotype.Service

/**
 * 프로모션 재시도 서비스
 * - RetryProcessor에 처리를 위임하여 코드 중복 제거
 * - 공통 로직은 AbstractPromotionRetryProcessor에서 관리
 */
@Service
class CampaignPromotionRetryService(
    private val voucherRetryProcessor: VoucherRetryProcessor,
    private val pointRetryProcessor: PointRetryProcessor
) {
    /**
     * 상품권 프로모션 재시도 처리
     * @param message Kafka Retry 메시지 (JSON)
     */
    fun retryVoucherPromotion(message: String) {
        voucherRetryProcessor.processRetry(message)
    }

    /**
     * 포인트 프로모션 재시도 처리
     * @param message Kafka Retry 메시지 (JSON)
     */
    fun retryPointPromotion(message: String) {
        pointRetryProcessor.processRetry(message)
    }
}
```

**장점**:
- 코드 중복 제거 (Exponential Backoff, 재시도 횟수 체크 등 공통 로직은 `AbstractPromotionRetryProcessor`에서 관리)
- Main Processor와 동일한 패턴 적용으로 일관성 유지
- 테스트 용이 (RetryProcessor 단위 테스트 가능)

#### 4.3.3 DTO 클래스

##### CampaignVoucherPromotionMessage.kt

Main Consumer와 Retry Consumer에서 공통으로 사용하는 메시지 클래스입니다.

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto

import com.fasterxml.jackson.annotation.JsonProperty

/**
 * 상품권 프로모션 메시지 (Main + Retry 공용)
 * - Main Consumer: retryCount = 0
 * - Retry Consumer: retryCount >= 1
 */
data class CampaignVoucherPromotionMessage(
    @JsonProperty("promotionId")
    val promotionId: String,

    @JsonProperty("promotionSummaryId")
    val promotionSummaryId: String,

    @JsonProperty("voucherTargetId")
    val voucherTargetId: String,

    @JsonProperty("partitionKey")
    val partitionKey: String,

    @JsonProperty("customerUid")
    val customerUid: String,

    @JsonProperty("merchantCode")
    val merchantCode: String,

    @JsonProperty("merchantBrandCode")
    val merchantBrandCode: String,

    @JsonProperty("campaignCode")
    val campaignCode: String,

    @JsonProperty("amount")
    val amount: String,

    @JsonProperty("voucherNumber")
    val voucherNumber: String,

    @JsonProperty("description")
    val description: String?,

    @JsonProperty("validUntil")
    val validUntil: String?,           // yyyy-MM-dd

    @JsonProperty("isWithdrawal")
    val isWithdrawal: Boolean,

    @JsonProperty("retryCount")
    val retryCount: Int = 0           // Main: 0, Retry 시 증가
)
```

##### CampaignPointPromotionMessage.kt

Main Consumer와 Retry Consumer에서 공통으로 사용하는 메시지 클래스입니다.

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application.dto

import com.fasterxml.jackson.annotation.JsonProperty

/**
 * 포인트 프로모션 메시지 (Main + Retry 공용)
 * - Main Consumer: retryCount = 0
 * - Retry Consumer: retryCount >= 1
 */
data class CampaignPointPromotionMessage(
    @JsonProperty("promotionId")
    val promotionId: String,

    @JsonProperty("promotionSummaryId")
    val promotionSummaryId: String,

    @JsonProperty("pointTargetId")
    val pointTargetId: String,

    @JsonProperty("partitionKey")
    val partitionKey: String,

    @JsonProperty("customerUid")
    val customerUid: String,

    @JsonProperty("merchantCode")
    val merchantCode: String,

    @JsonProperty("campaignCode")
    val campaignCode: String,

    @JsonProperty("amount")
    val amount: String,

    @JsonProperty("description")
    val description: String?,

    @JsonProperty("expiredAt")
    val expiredAt: String?,           // yyyy-MM-dd

    @JsonProperty("retryCount")
    val retryCount: Int = 0           // Main: 0, Retry 시 증가
)
```

### 4.3 Domain/Entity Layer

#### 4.3.1 Enum 클래스

##### PromotionStatus.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant

enum class PromotionStatus {
    READY,
    IN_PROGRESS,
    COMPLETED,
    STOPPED,
    FAILED
}
```

##### ProcessStatus.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant

enum class ProcessStatus {
    SUCCESS,
    RETRYING,
    FAILED
}
```

#### 4.3.2 Entity 클래스

##### CampaignPromotion.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.PromotionStatus
import jakarta.persistence.*
import java.math.BigDecimal
import java.time.LocalDateTime

@Entity
@Table(name = "campaign_promotions")
class CampaignPromotion(
    @Id
    @Column(name = "promotion_id")
    val promotionId: Long,

    @Column(name = "campaign_code")
    val campaignCode: String,

    @Column(name = "external_id")
    val externalId: String,

    @Column(name = "promotion_type")
    val promotionType: String,

    @Enumerated(EnumType.STRING)
    @Column(name = "promotion_status")
    var promotionStatus: PromotionStatus,

    @Column(name = "total_count")
    val totalCount: Int,

    @Column(name = "total_amount")
    val totalAmount: BigDecimal,

    @Column(name = "partition_count")
    val partitionCount: Int,

    @Column(name = "reservation_at")
    val reservationAt: LocalDateTime,

    @Column(name = "reservation_priority")
    val reservationPriority: Int,

    @Column(name = "default_reason")
    val defaultReason: String?,

    @Column(name = "default_amount")
    val defaultAmount: BigDecimal?,

    @Column(name = "default_expiry_at")
    val defaultExpiryAt: LocalDateTime?,

    @Column(name = "created_by")
    val createdBy: String,

    @Column(name = "created_at")
    val createdAt: LocalDateTime,

    @Column(name = "updated_by")
    var updatedBy: String?,

    @Column(name = "updated_at")
    var updatedAt: LocalDateTime?
)
```

##### CampaignPromotionVoucherResult.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.ProcessStatus
import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "campaign_promotion_voucher_results")
class CampaignPromotionVoucherResult(
    @Id
    @Column(name = "voucher_target_id")
    val voucherTargetId: Long,

    @Column(name = "promotion_id")
    val promotionId: Long,

    @Enumerated(EnumType.STRING)
    @Column(name = "process_status")
    var processStatus: ProcessStatus,

    @Column(name = "transaction_key")
    var transactionKey: String? = null,

    @Column(name = "error_message")
    var errorMessage: String? = null,

    @Column(name = "created_at")
    val createdAt: LocalDateTime = LocalDateTime.now(),

    @Column(name = "updated_at")
    var updatedAt: LocalDateTime = LocalDateTime.now()
) {
    fun updateSuccess(transactionKey: String?) {
        this.processStatus = ProcessStatus.SUCCESS
        this.transactionKey = transactionKey
        this.updatedAt = LocalDateTime.now()
    }

    fun updateError(errorMessage: String?) {
        this.errorMessage = errorMessage?.take(500)
        this.updatedAt = LocalDateTime.now()
    }

    fun updateFailed(errorMessage: String?) {
        this.processStatus = ProcessStatus.FAILED
        this.errorMessage = errorMessage?.take(500)
        this.updatedAt = LocalDateTime.now()
    }
}
```

##### CampaignPromotionPointResult.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.ProcessStatus
import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "campaign_promotion_point_results")
class CampaignPromotionPointResult(
    @Id
    @Column(name = "point_target_id")
    val pointTargetId: Long,

    @Column(name = "promotion_id")
    val promotionId: Long,

    @Enumerated(EnumType.STRING)
    @Column(name = "process_status")
    var processStatus: ProcessStatus,

    @Column(name = "transaction_key")
    var transactionKey: String? = null,

    @Column(name = "error_message")
    var errorMessage: String? = null,

    @Column(name = "created_at")
    val createdAt: LocalDateTime = LocalDateTime.now(),

    @Column(name = "updated_at")
    var updatedAt: LocalDateTime = LocalDateTime.now()
) {
    fun updateSuccess(transactionKey: String?) {
        this.processStatus = ProcessStatus.SUCCESS
        this.transactionKey = transactionKey
        this.updatedAt = LocalDateTime.now()
    }

    fun updateError(errorMessage: String?) {
        this.errorMessage = errorMessage?.take(500)
        this.updatedAt = LocalDateTime.now()
    }

    fun updateFailed(errorMessage: String?) {
        this.processStatus = ProcessStatus.FAILED
        this.errorMessage = errorMessage?.take(500)
        this.updatedAt = LocalDateTime.now()
    }
}
```

#### 4.3.3 Repository Interface

##### CampaignPromotionRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotion

interface CampaignPromotionRepository {
    fun findByPromotionId(promotionId: Long): CampaignPromotion?
}
```

##### CampaignPromotionVoucherResultRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionVoucherResult

interface CampaignPromotionVoucherResultRepository {
    fun save(result: CampaignPromotionVoucherResult): CampaignPromotionVoucherResult
    fun findByVoucherTargetId(voucherTargetId: Long): CampaignPromotionVoucherResult?
    // existsByVoucherTargetId 제거 - Insert-or-Catch 패턴으로 동시성 이슈 해결
}
```

##### CampaignPromotionPointResultRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionPointResult

interface CampaignPromotionPointResultRepository {
    fun save(result: CampaignPromotionPointResult): CampaignPromotionPointResult
    fun findByPointTargetId(pointTargetId: Long): CampaignPromotionPointResult?
    // existsByPointTargetId 제거 - Insert-or-Catch 패턴으로 동시성 이슈 해결
}
```

### 4.4 Infrastructure Layer (Repository)

#### 4.4.1 JPA Repository 구현

##### CampaignPromotionJpaRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.persistence

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotion
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionRepository
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

interface CampaignPromotionJpaRepositoryInterface : JpaRepository<CampaignPromotion, Long> {
    fun findByPromotionId(promotionId: Long): CampaignPromotion?
}

@Repository
class CampaignPromotionJpaRepository(
    private val jpaRepository: CampaignPromotionJpaRepositoryInterface
) : CampaignPromotionRepository {

    override fun findByPromotionId(promotionId: Long): CampaignPromotion? {
        return jpaRepository.findByPromotionId(promotionId)
    }
}
```

##### CampaignPromotionVoucherResultJpaRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.persistence

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionVoucherResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionVoucherResultRepository
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

interface CampaignPromotionVoucherResultJpaRepositoryInterface : JpaRepository<CampaignPromotionVoucherResult, Long> {
    fun findByVoucherTargetId(voucherTargetId: Long): CampaignPromotionVoucherResult?
    // existsByVoucherTargetId 제거 - Insert-or-Catch 패턴 사용
}

@Repository
class CampaignPromotionVoucherResultJpaRepository(
    private val jpaRepository: CampaignPromotionVoucherResultJpaRepositoryInterface
) : CampaignPromotionVoucherResultRepository {

    override fun save(result: CampaignPromotionVoucherResult): CampaignPromotionVoucherResult {
        return jpaRepository.save(result)
    }

    override fun findByVoucherTargetId(voucherTargetId: Long): CampaignPromotionVoucherResult? {
        return jpaRepository.findByVoucherTargetId(voucherTargetId)
    }
}
```

##### CampaignPromotionPointResultJpaRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.persistence

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.entity.CampaignPromotionPointResult
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionPointResultRepository
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

interface CampaignPromotionPointResultJpaRepositoryInterface : JpaRepository<CampaignPromotionPointResult, Long> {
    fun findByPointTargetId(pointTargetId: Long): CampaignPromotionPointResult?
    // existsByPointTargetId 제거 - Insert-or-Catch 패턴 사용
}

@Repository
class CampaignPromotionPointResultJpaRepository(
    private val jpaRepository: CampaignPromotionPointResultJpaRepositoryInterface
) : CampaignPromotionPointResultRepository {

    override fun save(result: CampaignPromotionPointResult): CampaignPromotionPointResult {
        return jpaRepository.save(result)
    }

    override fun findByPointTargetId(pointTargetId: Long): CampaignPromotionPointResult? {
        return jpaRepository.findByPointTargetId(pointTargetId)
    }
}
```

### 4.5 External API Client (FeignClient)

**참조 패턴**: `money/promotion/infrastructure/feign/MoneyPromotionApi.kt`

**설계 결정**: 1개의 통합 FeignClient 인터페이스에 2개의 메소드로 구성

#### 4.5.0 Money API 명세

##### 상품권 캠페인 충전 API

| 항목               | 내용                                           |
|------------------|----------------------------------------------|
| **URL**          | `POST /internal/v1/campaigns/voucher/charge` |
| **Content-Type** | `application/json`                           |

**Request Body**:
```json
{
  "customerUid": 12345,
  "merchantCode": "MERCHANT_CODE",
  "campaignCode": "CAMPAIGN_CODE",
  "amount": 10000,
  "voucherNumber": "VOUCHER_NUMBER",
  "description": "캠페인 상품권 충전",
  "expiredAt": "2026-12-31",
  "isWithdrawal": true
}
```

| 필드            | 타입      | 필수 | 설명               |
|---------------|---------|:--:|------------------|
| customerUid   | Long    | O  | 고객 UID           |
| merchantCode  | String  | O  | 가맹점 코드           |
| campaignCode  | String  | O  | 캠페인 코드           |
| amount        | Long    | O  | 충전 금액            |
| voucherNumber | String  | O  | 상품권 번호           |
| description   | String  | X  | 충전 사유            |
| expiredAt     | String  | X  | 만료일 (yyyy-MM-dd) |
| isWithdrawal  | Boolean | O  | 출금 가능 여부         |

**Response Body**:
```json
{
  "data": {},
  "meta": {
    "result": "SUCCESS",
    "errorCode": null,
    "message": null
  }
}
```

| 필드             | 타입     | 설명                  |
|----------------|--------|---------------------|
| data           | Object | 응답 데이터 (현재 빈 객체)    |
| meta.result    | String | 결과 (SUCCESS / FAIL) |
| meta.errorCode | String | 에러 코드 (실패 시)        |
| meta.message   | String | 에러 메시지 (실패 시)       |

---

##### 포인트 캠페인 충전 API

| 항목               | 내용                                         |
|------------------|--------------------------------------------|
| **URL**          | `POST /internal/v1/campaigns/point/charge` |
| **Content-Type** | `application/json`                         |

**Request Body**:
```json
{
  "customerUid": 12345,
  "merchantCode": "MERCHANT_CODE",
  "campaignCode": "CAMPAIGN_CODE",
  "amount": 50000,
  "description": "캠페인 포인트 충전",
  "expiredAt": "2026-12-31"
}
```

| 필드           | 타입     | 필수 | 설명               |
|--------------|--------|:--:|------------------|
| customerUid  | Long   | O  | 고객 UID           |
| merchantCode | String | O  | 가맹점 코드           |
| campaignCode | String | O  | 캠페인 코드           |
| amount       | Long   | O  | 충전 금액            |
| description  | String | X  | 충전 사유            |
| expiredAt    | String | X  | 만료일 (yyyy-MM-dd) |

**Response Body**:
```json
{
  "data": {},
  "meta": {
    "result": "SUCCESS",
    "errorCode": null,
    "message": null
  }
}
```

| 필드             | 타입     | 설명                  |
|----------------|--------|---------------------|
| data           | Object | 응답 데이터 (현재 빈 객체)    |
| meta.result    | String | 결과 (SUCCESS / FAIL) |
| meta.errorCode | String | 에러 코드 (실패 시)        |
| meta.message   | String | 에러 메시지 (실패 시)       |

---

#### 4.5.1 MoneyCampaignChargeApi.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeResponse
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeResponse
import com.musinsapayments.prepay.application.prepay.admin.core.aop.dto.ApiResponse
import org.springframework.cloud.openfeign.FeignClient
import org.springframework.http.MediaType
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody

@FeignClient(
    name = "moneyCampaignChargeApi",
    url = "\${client.money.url}",
    fallbackFactory = MoneyCampaignChargeApiFallbackFactory::class
)
interface MoneyCampaignChargeApi {

    @PostMapping("/internal/v1/campaigns/voucher/charge", consumes = [MediaType.APPLICATION_JSON_VALUE])
    fun chargeVoucher(@RequestBody request: CampaignVoucherChargeRequest): ApiResponse<CampaignVoucherChargeResponse>

    @PostMapping("/internal/v1/campaigns/point/charge", consumes = [MediaType.APPLICATION_JSON_VALUE])
    fun chargePoint(@RequestBody request: CampaignPointChargeRequest): ApiResponse<CampaignPointChargeResponse>
}
```

#### 4.5.2 MoneyCampaignChargeApiFallbackFactory.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignPointChargeResponse
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeRequest
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto.CampaignVoucherChargeResponse
import com.musinsapayments.prepay.application.prepay.admin.core.aop.dto.ApiResponse
import com.musinsapayments.prepay.application.prepay.admin.core.aop.dto.ResponseMeta
import com.musinsapayments.prepay.application.prepay.admin.core.exception.ApiResponseFailCode
import org.slf4j.LoggerFactory
import org.springframework.cloud.openfeign.FallbackFactory
import org.springframework.stereotype.Component

@Component
class MoneyCampaignChargeApiFallbackFactory : FallbackFactory<MoneyCampaignChargeApi> {

    private val log = LoggerFactory.getLogger(this::class.java)

    override fun create(cause: Throwable): MoneyCampaignChargeApi {
        val error = getFailErrorMeta(cause)

        return object : MoneyCampaignChargeApi {
            override fun chargeVoucher(request: CampaignVoucherChargeRequest): ApiResponse<CampaignVoucherChargeResponse> {
                log.warn("[MoneyCampaignChargeApi] chargeVoucher fallback - request: {}, cause: {}", request, cause.message)
                return getError(error)
            }

            override fun chargePoint(request: CampaignPointChargeRequest): ApiResponse<CampaignPointChargeResponse> {
                log.warn("[MoneyCampaignChargeApi] chargePoint fallback - request: {}, cause: {}", request, cause.message)
                return getError(error)
            }
        }
    }

    private fun getFailErrorMeta(cause: Throwable): ResponseMeta {
        return ResponseMeta.fail(
            errorCode = ApiResponseFailCode.ERR51001,
            message = cause.message ?: ApiResponseFailCode.ERR51001.message
        )
    }

    private fun <T> getError(error: ResponseMeta?): ApiResponse<T> {
        if (error == null || error.message.isNullOrEmpty()) {
            return ApiResponse(
                data = null,
                meta = ResponseMeta.fail(
                    errorCode = ApiResponseFailCode.ERR51001,
                    message = ApiResponseFailCode.ERR51001.message
                )
            )
        }
        return ApiResponse(data = null, meta = error)
    }
}
```

#### 4.5.3 Request/Response DTO

##### CampaignVoucherChargeRequest.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto

data class CampaignVoucherChargeRequest(
    val customerUid: Long,
    val merchantCode: String,
    val campaignCode: String,
    val amount: Long,
    val voucherNumber: String,
    val description: String?,
    val expiredAt: String?,       // yyyy-MM-dd
    val isWithdrawal: Boolean
)
```

##### CampaignVoucherChargeResponse.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto

/**
 * Money API 응답은 ApiResponse<T> 형태로 래핑됨
 * - data.moneyKey: 거래 키 (result 엔티티의 transactionKey로 저장)
 * - meta.result: SUCCESS / FAIL
 * - meta.errorCode: 에러 코드 (실패 시)
 * - meta.message: 에러 메시지 (실패 시)
 */
data class CampaignVoucherChargeResponse(
    val moneyKey: String  // 거래 키 → result 엔티티의 transactionKey로 저장
)
```

##### CampaignPointChargeRequest.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto

data class CampaignPointChargeRequest(
    val customerUid: Long,
    val merchantCode: String,
    val campaignCode: String,
    val amount: Long,
    val description: String?,
    val expiredAt: String?        // yyyy-MM-dd
)
```

##### CampaignPointChargeResponse.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.feign.dto

/**
 * Money API 응답은 ApiResponse<T> 형태로 래핑됨
 * - data.moneyKey: 거래 키 (result 엔티티의 transactionKey로 저장)
 * - meta.result: SUCCESS / FAIL
 * - meta.errorCode: 에러 코드 (실패 시)
 * - meta.message: 에러 메시지 (실패 시)
 */
data class CampaignPointChargeResponse(
    val moneyKey: String  // 거래 키 → result 엔티티의 transactionKey로 저장
)
```

### 4.6 Redis Cache Repository

**참조 패턴**: `money/cache/infrastructure/RedisTemplateHashRepository.kt`

#### 4.6.1 CampaignPromotionSummaryCache.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis

import com.fasterxml.jackson.annotation.JsonProperty
import org.springframework.data.annotation.Id
import org.springframework.data.redis.core.RedisHash
import java.time.LocalDateTime

@RedisHash(value = "campaign:promotion:summary", timeToLive = 86400)
data class CampaignPromotionSummaryCache(
    @Id
    @JsonProperty("promotionId")
    val promotionId: Long,

    @JsonProperty("totalCount")
    var totalCount: Int = 0,

    @JsonProperty("publishedCount")
    var publishedCount: Int = 0,

    @JsonProperty("successCount")
    var successCount: Int = 0,

    @JsonProperty("retrySuccessCount")
    var retrySuccessCount: Int = 0,

    @JsonProperty("failCount")
    var failCount: Int = 0,

    @JsonProperty("lastCompletedAt")
    var lastCompletedAt: String? = null
)
```

#### 4.6.2 CampaignPromotionSummaryCacheRepository.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.infrastructure.redis

import com.fasterxml.jackson.databind.ObjectMapper
import com.musinsapayments.prepay.application.prepay.admin.money.cache.infrastructure.RedisTemplateHashRepository
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.data.redis.core.RedisTemplate
import org.springframework.stereotype.Repository
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

@Repository
class CampaignPromotionSummaryCacheRepository(
    redisTemplate: RedisTemplate<String, String>,
    objectMapper: ObjectMapper
) : RedisTemplateHashRepository<CampaignPromotionSummaryCache, Long>(
    redisTemplate, objectMapper, CampaignPromotionSummaryCache::class
) {
    private val log = KotlinLogging.logger {}

    companion object {
        private const val KEY_PREFIX = "campaign:promotion:summary"
        private val DATE_TIME_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
    }

    fun incrementSuccessCount(promotionId: Long) {
        try {
            val cache = findById(promotionId) ?: return
            cache.successCount += 1
            save(cache)
            log.debug { "Incremented successCount - promotionId: $promotionId, successCount: ${cache.successCount}" }
        } catch (e: Exception) {
            log.error(e) { "Failed to increment successCount - promotionId: $promotionId" }
        }
    }

    fun incrementRetrySuccessCount(promotionId: Long) {
        try {
            val cache = findById(promotionId) ?: return
            cache.retrySuccessCount += 1
            save(cache)
            log.debug { "Incremented retrySuccessCount - promotionId: $promotionId, retrySuccessCount: ${cache.retrySuccessCount}" }
        } catch (e: Exception) {
            log.error(e) { "Failed to increment retrySuccessCount - promotionId: $promotionId" }
        }
    }

    fun incrementFailCount(promotionId: Long) {
        try {
            val cache = findById(promotionId) ?: return
            cache.failCount += 1
            save(cache)
            log.debug { "Incremented failCount - promotionId: $promotionId, failCount: ${cache.failCount}" }
        } catch (e: Exception) {
            log.error(e) { "Failed to increment failCount - promotionId: $promotionId" }
        }
    }

    fun updateLastCompletedAt(promotionId: Long, completedAt: LocalDateTime) {
        try {
            val cache = findById(promotionId) ?: return
            cache.lastCompletedAt = completedAt.format(DATE_TIME_FORMATTER)
            save(cache)
            log.debug { "Updated lastCompletedAt - promotionId: $promotionId, lastCompletedAt: ${cache.lastCompletedAt}" }
        } catch (e: Exception) {
            log.error(e) { "Failed to update lastCompletedAt - promotionId: $promotionId" }
        }
    }
}
```

---

## 5. Kafka 설정

### 5.1 Consumer 설정

**참조 패턴**: `core/config/KafkaConfig.kt`

기존 `KafkaConfig.kt`의 설정을 그대로 활용합니다:
- `ContainerProperties.AckMode.MANUAL` - 수동 ACK
- `DeadLetterPublishingRecoverer` - DLT 자동 발행
- `FixedBackOff(10L, 0)` - 에러 핸들링

### 5.2 Topic 설정

**kafka.yml 추가 내용**:

```yaml
kafka:
  topic:
    # 기존 Topic
    dead-letter: pocket-dead-letter
    voucher-bulk-issue-completed: voucher-bulk-issue-completed
    auth-inactive: auth-inactive

    # Campaign Promotion Consumer Topics (신규 추가)
    campaign-promotion-voucher-publish: "campaign-promotion-voucher-publish"
    campaign-promotion-point-publish: "campaign-promotion-point-publish"

    # Retry Topics (신규 생성)
    campaign-promotion-voucher-retry: "campaign-promotion-voucher-retry"
    campaign-promotion-point-retry: "campaign-promotion-point-retry"
```

### 5.3 Consumer 목록

| Consumer                         | Topic                              | Group ID                            | 비고             |
|----------------------------------|------------------------------------|-------------------------------------|----------------|
| CampaignVoucherPromotionListener | campaign-promotion-voucher-publish | prepay-admin-campaign-voucher       | 메인 Consumer    |
| CampaignPointPromotionListener   | campaign-promotion-point-publish   | prepay-admin-campaign-point         | 메인 Consumer    |
| CampaignVoucherRetryListener     | campaign-promotion-voucher-retry   | prepay-admin-campaign-voucher-retry | Retry Consumer |
| CampaignPointRetryListener       | campaign-promotion-point-retry     | prepay-admin-campaign-point-retry   | Retry Consumer |

### 5.4 메시지 포맷

#### 상품권 프로모션 메시지 (CampaignVoucherPromotionMessage)

> Main Consumer 및 Retry Consumer에서 동일한 메시지 구조 사용
> - Main Consumer: `retryCount = 0` (기본값)
> - Retry Consumer: `retryCount >= 1` (재시도 횟수)

```json
{
  "promotionId": "1",
  "promotionSummaryId": "1",
  "voucherTargetId": "1",
  "partitionKey": "0",
  "customerUid": "12345",
  "merchantCode": "merchant_code",
  "merchantBrandCode": "merchant_brand_code",
  "campaignCode": "CAMPAIGN_001",
  "amount": "10000",
  "voucherNumber": "voucher_number",
  "description": "새해맞이 프로모션 상품권 지급",
  "validUntil": "2026-12-31",
  "isWithdrawal": false
}
```

##### 상품권 Kafka 메시지 필드 설명

| 필드                 | 타입      | 설명               | 필수 |
|--------------------|---------|------------------|----|
| promotionId        | String  | 프로모션 ID          | Y  |
| promotionSummaryId | String  | 프로모션 현황 ID       | Y  |
| voucherTargetId    | String  | 바우처 대상 ID        | Y  |
| partitionKey       | String  | 파티션 키            | Y  |
| customerUid        | String  | 고객 UID           | Y  |
| merchantCode       | String  | 상점 코드            | Y  |
| merchantBrandCode  | String  | 상점 브랜드 코드        | Y  |
| campaignCode       | String  | 캠페인 코드           | Y  |
| amount             | String  | 지급 금액            | Y  |
| voucherNumber      | String  | 상품권 번호           | Y  |
| description        | String  | 지급 사유            | Y  |
| validUntil         | String  | 유효일 (yyyy-MM-dd) | Y  |
| isWithdrawal       | Boolean | 인출 가능 여부         | Y  |

#### 포인트 프로모션 메시지 (CampaignPointPromotionMessage)

> Main Consumer 및 Retry Consumer에서 동일한 메시지 구조 사용
> - Main Consumer: `retryCount = 0` (기본값)
> - Retry Consumer: `retryCount >= 1` (재시도 횟수)

```json
{
    "promotionId": "1",
    "promotionSummaryId": "1",
    "pointTargetId": "1",
    "partitionKey": "0",
    "customerUid": "12345",
    "merchantCode": "merchant_code",
    "campaignCode": "CAMPAIGN_001",
    "amount": "50000",
    "description": "새해맞이 프로모션 포인트 지급",
    "expiredAt": "2026-12-31"
}
```

##### 포인트 Kafka 메시지 필드 설명

| 필드                 | 타입     | 설명               | 필수 |
|--------------------|--------|------------------|----|
| promotionId        | String | 프로모션 ID          | Y  |
| promotionSummaryId | String | 프로모션 현황 ID       | Y  |
| pointTargetId      | String | 포인트 대상 ID        | Y  |
| partitionKey       | String | 파티션 키            | Y  |
| customerUid        | String | 고객 UID           | Y  |
| merchantCode       | String | 상점 코드            | Y  |
| campaignCode       | String | 캠페인 코드           | Y  |
| amount             | String | 지급 금액            | Y  |
| description        | String | 지급 사유            | Y  |
| expiredAt          | String | 유효일 (yyyy-MM-dd) | Y  |

**설계 결정**:
- 별도의 Retry 전용 메시지 클래스(`CampaignPromotionRetryMessage`) 대신 원본 메시지 클래스에 `retryCount` 필드 추가
- Retry 리스너가 이미 상품권/포인트로 분리되어 있으므로 메시지 구조도 분리 유지
- 메시지 변환 로직 불필요 → 코드 단순화

---

## 6. 구현 순서 (Phase별)

| Phase | 내용                       | 주요 파일                                                                                                  |
|:-----:|--------------------------|--------------------------------------------------------------------------------------------------------|
|   1   | Enum, Entity, Repository | `PromotionStatus.kt`, `ProcessStatus.kt`, `CampaignPromotion.kt`, `*Result.kt`, `*Repository.kt`       |
|   2   | FeignClient, DTO         | `MoneyCampaignChargeApi.kt`, `MoneyCampaignChargeApiFallbackFactory.kt`, Request/Response DTO          |
|   3   | **캐시 설정 및 서비스**          | `Caches.kt` 수정, `CampaignPromotionStatusCacheService.kt`                                               |
|   4   | **Main Processor**       | `AbstractPromotionProcessor.kt`, `VoucherPromotionProcessor.kt`, `PointPromotionProcessor.kt`          |
|   5   | **Retry Processor**      | `AbstractPromotionRetryProcessor.kt`, `VoucherRetryProcessor.kt`, `PointRetryProcessor.kt`             |
|   6   | Kafka Listener (Main)    | `CampaignVoucherPromotionListener.kt`, `CampaignPointPromotionListener.kt`                             |
|   7   | Consumer Service         | `CampaignPromotionConsumerService.kt`, Message DTO                                                     |
|   8   | Retry Listener & Service | `CampaignVoucherRetryListener.kt`, `CampaignPointRetryListener.kt`, `CampaignPromotionRetryService.kt` |
|   9   | Redis Cache (현황)         | `CampaignPromotionSummaryCache.kt`, `CampaignPromotionSummaryCacheRepository.kt`                       |
|  10   | Kafka 설정                 | `kafka.yml` Topic 추가                                                                                   |
|  11   | 테스트                      | Unit Test, Integration Test                                                                            |

---

## 7. 핵심 파일 참조

| 파일                                                                         | 참조 용도                    |
|----------------------------------------------------------------------------|--------------------------|
| `voucher/campaign/presentation/listener/CampaignIssueCompletedListener.kt` | Kafka Listener 패턴        |
| `core/aop/Retryer.kt`, `core/aop/RetryerAspect.kt`                         | @Retryer AOP 로직          |
| `money/promotion/infrastructure/feign/MoneyPromotionApi.kt`                | FeignClient 패턴           |
| `money/promotion/infrastructure/feign/MoneyPromotionApiFallbackFactory.kt` | FallbackFactory 패턴       |
| `money/cache/infrastructure/RedisTemplateHashRepository.kt`                | Redis Hash Repository 패턴 |
| `core/config/KafkaConfig.kt`                                               | Kafka Consumer 설정        |

---

## 8. 설계 결정 요약

| 항목                 | 결정 내용                                        | 이유                          |
|--------------------|----------------------------------------------|-----------------------------|
| **Repository 패턴**  | JPA Repository                               | prepay-admin 프로젝트 방향성       |
| **FeignClient 구조** | 1개 인터페이스 (`MoneyCampaignChargeApi`)에 2개 메소드  | 코드 단순화, 관련 기능 응집            |
| **Processor 패턴**   | Template Method 패턴 (Main + Retry 양쪽 적용)      | 공통 로직 추상화, 코드 중복 제거, 확장 용이  |
| **Retry 전략**       | 별도 Retry Topic + Exponential Backoff         | 메인 Consumer 부하 분리, 안정적인 재시도 |
| **멱등성 보장**         | Insert-or-Catch 패턴 (PK 충돌 시 Skip)            | 동시성 이슈 방지, DB 조회 감소         |
| **Redis Cache**    | RedisTemplateHashRepository 상속               | 기존 패턴 재사용 (현황 집계용)          |
| **프로모션 상태 캐싱**     | @Cacheable + Caffeine (Local Cache, TTL 10분) | DB 부하 감소, 동일 프로모션 반복 조회 방지  |
| **최대 재시도 횟수**      | 5회                                           | 시퀀스 다이어그램 명세                |

---

## 9. 에러 핸들링 전략

### 9.1 에러 유형별 처리

| 에러 유형             | 처리 방안                                        | 비고                          |
|-------------------|----------------------------------------------|-----------------------------|
| **프로모션 상태 불일치**   | Skip (로그 남기고 종료)                             | IN_PROGRESS 상태가 아닌 경우       |
| **중복 처리 요청**      | Skip (DataIntegrityViolationException catch) | Insert-or-Catch 패턴으로 동시성 해결 |
| **Money API 실패**  | Retry Topic 발행                               | 재시도 대상                      |
| **최종 실패 (5회 초과)** | FAILED 상태 저장 + DLT 발행                        | @Retryer AOP에서 DLT 자동 발행    |
| **직렬화/역직렬화 오류**   | 즉시 ACK + 로그                                  | 재시도 불가 (데이터 오류)             |

### 9.2 처리 결과 코드

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Consumer 에러 핸들링 흐름                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   try {                                                                 │
│       moneyCampaignChargeApi.chargeVoucher(...)  ───────────┐           │
│                                                              │           │
│       if (response.meta?.code == "0") {                      │ 성공      │
│           result.updateSuccess()                             ▼           │
│           summaryCacheRepository.incrementSuccessCount()  ◄──┘           │
│       } else {                                               │           │
│           handleVoucherFailure(...)  ◄───────────────────────┘ 실패      │
│       }                                                                 │
│   } catch (Exception e) {                                               │
│       handleVoucherFailure(...)  ◄─────────────────── 예외 발생          │
│   }                                                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 10. 검증 방법

### 10.1 단위 테스트

| 테스트 대상                                    | 검증 항목                                      |
|-------------------------------------------|--------------------------------------------|
| `AbstractPromotionProcessor`              | 템플릿 메서드 흐름, 멱등성, API 실패 시 Retry 메시지 발행     |
| `VoucherPromotionProcessor`               | 상품권 전용 로직 (API 요청 빌드, Retry 메시지 빌드)        |
| `PointPromotionProcessor`                 | 포인트 전용 로직 (API 요청 빌드, Retry 메시지 빌드)        |
| `AbstractPromotionRetryProcessor`         | 템플릿 메서드 흐름, Exponential Backoff, 재시도 횟수 체크 |
| `VoucherRetryProcessor`                   | 상품권 재시도 전용 로직 (API 요청 빌드, 최종 실패 처리)        |
| `PointRetryProcessor`                     | 포인트 재시도 전용 로직 (API 요청 빌드, 최종 실패 처리)        |
| `CampaignPromotionStatusCacheService`     | @Cacheable 캐시 히트/미스, @CacheEvict 캐시 무효화    |
| `MoneyCampaignChargeApi`                  | FeignClient 호출, Fallback 동작                |
| `CampaignPromotionSummaryCacheRepository` | Redis increment/update 동작                  |

### 10.2 통합 테스트

| 테스트 시나리오       | 검증 항목                                               |
|----------------|-----------------------------------------------------|
| **정상 처리 흐름**   | Kafka 메시지 수신 -> Money API 호출 -> 결과 저장 -> Redis 업데이트 |
| **멱등성 테스트**    | 동일 메시지 중복 수신 시 PK 충돌 → Skip 확인 (Insert-or-Catch)    |
| **재시도 흐름**     | API 실패 -> Retry Topic 발행 -> Retry Consumer 처리       |
| **최종 실패 흐름**   | 5회 재시도 후 FAILED 상태 + DLT 발행                         |
| **프로모션 상태 체크** | IN_PROGRESS 상태가 아닌 경우 Skip                          |
| **상태 캐싱 테스트**  | 동일 프로모션 연속 처리 시 캐시 히트 확인 (DB 조회 1회)                 |
| **캐시 무효화 테스트** | 프로모션 상태 변경 후 캐시 무효화 → 다음 조회 시 DB 조회 확인              |

### 10.3 E2E 테스트 시나리오

1. **prepay-batch** Publisher가 `campaign-promotion-voucher-publish` 토픽에 메시지 발행
2. **prepay-admin** Consumer가 메시지 수신
3. 프로모션 상태 확인 (IN_PROGRESS)
4. 결과 테이블에 INSERT (멱등성 확인)
5. Money API 호출
6. 성공 시: 결과 UPDATE (SUCCESS) + Redis 업데이트
7. 실패 시: Retry Topic 발행 -> Retry Consumer 처리
8. 5회 실패 시: FAILED 상태 + DLT 발행

---

## 11. Redis 캐시 필드 정리

| 필드명                 | 설명        | 업데이트 시점                      |
|---------------------|-----------|------------------------------|
| `totalCount`        | 전체 대상자 수  | 프로모션 시작 시 (Batch)            |
| `publishedCount`    | 발행된 메시지 수 | Publisher에서 메시지 발행 후 (Batch) |
| `successCount`      | 성공 처리 수   | Consumer에서 API 성공 시          |
| `retrySuccessCount` | 재시도 성공 수  | Retry Consumer에서 API 성공 시    |
| `failCount`         | 최종 실패 수   | 5회 이상 재시도 실패 시               |
| `lastCompletedAt`   | 마지막 처리 시간 | 성공/실패 처리 완료 시                |

---

## 12. 프로모션 상태 조회 캐싱 (@Cacheable)

### 12.1 도입 배경

Consumer에서 메시지 처리 시 매번 DB에서 프로모션 상태를 조회합니다:

```kotlin
// 현재 구현 - 매 메시지마다 DB 조회
val promotion = promotionRepository.findByPromotionId(promotionId)
if (promotion == null || promotion.promotionStatus != PromotionStatus.IN_PROGRESS) {
    return
}
```

**문제점**:
- 동일 프로모션에 대해 수십만 건의 메시지가 처리될 때 동일한 조회가 반복됨
- 불필요한 DB 부하 발생

**해결책**: `@Cacheable`을 사용하여 프로모션 상태를 캐싱

### 12.2 캐시 설정

#### 12.2.1 CacheNames 추가 (Caches.kt)

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.core.config.cache

import java.util.concurrent.TimeUnit

object CacheNames {
    const val MEMBER_PERMISSION_CACHE = "MEMBER_PERMISSION_CACHE"
    const val CAMPAIGN_PROMOTION_STATUS_CACHE = "CAMPAIGN_PROMOTION_STATUS_CACHE"  // 신규 추가
}

enum class Caches(
    val cacheName: String,
    val maximumSize: Int,
    val expireSpec: CacheExpiry,
    val expireWriteTime: Int?,
    val expireAccessTime: Int?,
    val timeUnit: TimeUnit
) {
    CUSTOMER_KMS_KEY("CUSTOMER_KMS_KEY", 1, CacheExpiry.WRITE, 24, null, TimeUnit.HOURS),
    MEMBER_PERMISSION_CACHE(CacheNames.MEMBER_PERMISSION_CACHE, 1000, CacheExpiry.WRITE, 60, null, TimeUnit.MINUTES),

    // 프로모션 상태 캐시 (최대 100개 프로모션, 10분 TTL)
    CAMPAIGN_PROMOTION_STATUS_CACHE(
        CacheNames.CAMPAIGN_PROMOTION_STATUS_CACHE,
        100,
        CacheExpiry.WRITE,
        10,
        null,
        TimeUnit.MINUTES
    );
}
```

### 12.3 캐시 서비스 구현

#### 12.3.1 CampaignPromotionStatusCacheService.kt

```kotlin
package com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.application

import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.constant.PromotionStatus
import com.musinsapayments.prepay.application.prepay.admin.campaign.promotion.domain.repository.CampaignPromotionRepository
import com.musinsapayments.prepay.application.prepay.admin.core.config.cache.CacheNames
import io.github.oshai.kotlinlogging.KotlinLogging
import org.springframework.cache.annotation.CacheEvict
import org.springframework.cache.annotation.Cacheable
import org.springframework.stereotype.Service

@Service
class CampaignPromotionStatusCacheService(
    private val promotionRepository: CampaignPromotionRepository
) {
    private val log = KotlinLogging.logger {}

    /**
     * 프로모션 상태를 캐싱하여 조회
     * - 동일 프로모션에 대한 반복 DB 조회 방지
     * - TTL: 10분 (Caches.kt에서 설정)
     */
    @Cacheable(
        cacheNames = [CacheNames.CAMPAIGN_PROMOTION_STATUS_CACHE],
        key = "#promotionId"
    )
    fun getPromotionStatus(promotionId: Long): PromotionStatus? {
        log.debug { "Cache miss - loading promotion status from DB: promotionId=$promotionId" }
        return promotionRepository.findByPromotionId(promotionId)?.promotionStatus
    }

    /**
     * 프로모션 상태가 변경될 때 캐시 무효화
     * - Admin에서 프로모션 상태를 변경할 때 호출
     * - 예: STOPPED, COMPLETED 등으로 상태 변경 시
     */
    @CacheEvict(
        cacheNames = [CacheNames.CAMPAIGN_PROMOTION_STATUS_CACHE],
        key = "#promotionId"
    )
    fun evictPromotionStatusCache(promotionId: Long) {
        log.info { "Evicting promotion status cache: promotionId=$promotionId" }
    }

    /**
     * 프로모션 상태가 IN_PROGRESS인지 확인
     */
    fun isPromotionInProgress(promotionId: Long): Boolean {
        return getPromotionStatus(promotionId) == PromotionStatus.IN_PROGRESS
    }
}
```

### 12.4 ConsumerService 수정

#### 수정 전 (DB 직접 조회)

```kotlin
@Service
class CampaignPromotionConsumerService(
    private val promotionRepository: CampaignPromotionRepository,
    // ...
) {
    fun processVoucherPromotion(message: String) {
        // ...

        // 매번 DB 조회
        val promotion = promotionRepository.findByPromotionId(promotionId)
        if (promotion == null || promotion.promotionStatus != PromotionStatus.IN_PROGRESS) {
            log.warn { "Promotion not in progress - promotionId: $promotionId" }
            return
        }

        // ...
    }
}
```

#### 수정 후 (캐시 서비스 사용)

```kotlin
@Service
class CampaignPromotionConsumerService(
    private val promotionStatusCacheService: CampaignPromotionStatusCacheService,  // 캐시 서비스 주입
    private val voucherResultRepository: CampaignPromotionVoucherResultRepository,
    private val pointResultRepository: CampaignPromotionPointResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi,
    private val summaryCacheRepository: CampaignPromotionSummaryCacheRepository,
    private val kafkaTemplate: KafkaTemplate<String, String>,
    private val objectMapper: ObjectMapper
) {
    private val log = KotlinLogging.logger {}

    @Transactional
    fun processVoucherPromotion(message: String) {
        val voucherMessage = objectMapper.readValue(message, CampaignVoucherPromotionMessage::class.java)
        val promotionId = voucherMessage.promotionId.toLong()
        val voucherTargetId = voucherMessage.voucherTargetId.toLong()

        log.info { "Processing voucher promotion - promotionId: $promotionId, voucherTargetId: $voucherTargetId" }

        // 1. 프로모션 상태 확인 (캐시 조회)
        if (!promotionStatusCacheService.isPromotionInProgress(promotionId)) {
            log.warn { "Promotion not in progress - promotionId: $promotionId (Skip)" }
            return
        }

        // 2. 멱등성 확인 (이미 처리된 대상자인지 확인)
        // ...
    }

    @Transactional
    fun processPointPromotion(message: String) {
        val pointMessage = objectMapper.readValue(message, CampaignPointPromotionMessage::class.java)
        val promotionId = pointMessage.promotionId.toLong()
        val pointTargetId = pointMessage.pointTargetId.toLong()

        log.info { "Processing point promotion - promotionId: $promotionId, pointTargetId: $pointTargetId" }

        // 1. 프로모션 상태 확인 (캐시 조회)
        if (!promotionStatusCacheService.isPromotionInProgress(promotionId)) {
            log.warn { "Promotion not in progress - promotionId: $promotionId (Skip)" }
            return
        }

        // 2. 멱등성 확인 (이미 처리된 대상자인지 확인)
        // ...
    }
}
```

### 12.5 캐시 무효화 시점

프로모션 상태가 변경되면 캐시를 무효화해야 합니다:

| 상태 변경                   | 캐시 무효화 필요 | 호출 위치       |
|-------------------------|-----------|-------------|
| READY → IN_PROGRESS     | O         | 프로모션 시작 API |
| IN_PROGRESS → STOPPED   | O         | 프로모션 중지 API |
| IN_PROGRESS → COMPLETED | O         | 프로모션 완료 처리  |
| IN_PROGRESS → FAILED    | O         | 프로모션 실패 처리  |

#### 캐시 무효화 호출 예시 (Admin Service)

```kotlin
@Service
class CampaignPromotionAdminService(
    private val promotionRepository: CampaignPromotionRepository,
    private val promotionStatusCacheService: CampaignPromotionStatusCacheService
) {
    @Transactional
    fun stopPromotion(promotionId: Long) {
        val promotion = promotionRepository.findByPromotionId(promotionId)
            ?: throw IllegalArgumentException("Promotion not found: $promotionId")

        promotion.promotionStatus = PromotionStatus.STOPPED
        promotionRepository.save(promotion)

        // 캐시 무효화
        promotionStatusCacheService.evictPromotionStatusCache(promotionId)
    }
}
```

### 12.6 패키지 구조 업데이트

```
├── application/
│   ├── CampaignPromotionConsumerService.kt
│   ├── CampaignPromotionRetryService.kt
│   ├── CampaignPromotionStatusCacheService.kt   # 신규 추가
│   └── dto/
```

### 12.7 캐싱 효과

| 항목                | 캐싱 전                | 캐싱 후                        |
|-------------------|---------------------|-----------------------------|
| **DB 조회 횟수**      | 메시지 수만큼 (예: 100만 건) | 프로모션 수 × (TTL 만료 횟수)        |
| **예시 (100만 대상자)** | 100만 번 DB 조회        | 약 1번 (10분 TTL 내 모든 처리 완료 시) |
| **DB 부하**         | 높음                  | 매우 낮음                       |
| **응답 시간**         | DB 조회 시간 포함         | 캐시 히트 시 즉시 반환               |

### 12.8 주의사항

1. **캐시 정합성**: 프로모션 상태 변경 시 반드시 `evictPromotionStatusCache()` 호출 필요
2. **TTL 설정**: 너무 길면 상태 변경이 반영되지 않고, 너무 짧으면 캐싱 효과 감소 (10분 권장)
3. **동시성**: 여러 Consumer가 동시에 동일 프로모션을 처리해도 캐시 히트로 안전
4. **Caffeine 캐시**: Local 캐시이므로 Pod 간 캐시 불일치 가능 (TTL로 해결)
