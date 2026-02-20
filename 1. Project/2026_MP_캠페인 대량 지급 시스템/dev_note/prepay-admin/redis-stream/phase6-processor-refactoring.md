# Phase 6: Processor 리팩토링 — Stream Enqueue 및 Money API 처리 분리

## 목차

1. [개요](#1-개요)
2. [현재 Processor 흐름 분석](#2-현재-processor-흐름-분석)
3. [변경 후 흐름 설계](#3-변경-후-흐름-설계)
4. [Phase 6-1: processTopicMessage() — Kafka Listener 경로](#4-phase-6-1-processtopicmessage--kafka-listener-경로)
5. [Phase 6-2: processStreamMessage() — Stream Consumer 경로](#5-phase-6-2-processstreammessage--stream-consumer-경로)
6. [순환 의존성 방지](#6-순환-의존성-방지)
7. [멱등성 보장](#7-멱등성-보장)
8. [변경하지 않는 파일](#8-변경하지-않는-파일)

---

## 1. 개요

### 1.1 배경

Phase 1~5에서 Redis Stream 인프라, Consumer, Producer, Manager, PromotionStartedListener를 구현했다.

Phase 5 개발 시, Kafka Listener에서 직접 `streamManager.enqueue()`를 호출하는 방식을 검토했으나,
enqueue 시점을 Processor 내부로 옮기는 것이 더 적절하다는 결론에 도달했다.

**이유**:
- `saveResult()` 이후, `callMoneyApi()` 이전에 enqueue해야 결과 저장의 멱등성이 보장된다
- Kafka Listener는 메시지 수신/ACK에만 집중, 비즈니스 로직은 Processor가 담당
- Processor 내부에서 분기하면 Feature Toggle 적용이 Processor에 집중

### 1.2 목표

- `AbstractCampaignPromotionProcessor.process()` → `processTopicMessage()`으로 리네이밍 + `saveResult()` 이후 Stream enqueue 분기
- Money API 호출 + 결과 업데이트 로직을 `processStreamMessage()` 메서드로 분리
- `PromotionStreamConsumer`가 `processStreamMessage()`를 호출하도록 변경

### 1.3 Phase 분리

변경 범위가 크므로 **Kafka 경로 / Stream 경로** 기준으로 2단계로 분리하여 개발한다.

| Phase | 내용 | 핵심 메서드 | 호출 주체 |
|:---:|------|-----------|----------|
| **6-1** | Kafka Listener 경로 리팩토링 | `processTopicMessage()` | Kafka Listener |
| **6-2** | Stream Consumer 경로 구현 | `processStreamMessage()` | PromotionStreamConsumer |

Phase 6-1만 배포해도 `enabled=false`는 기존 동작 그대로, `enabled=true`는 enqueue까지 동작한다.
Phase 6-2에서 Stream Consumer 쪽 처리를 완성한다.

### 1.4 범위

| 포함 | 미포함 |
|------|-------|
| `AbstractCampaignPromotionProcessor` 리팩토링 | Retry Processor 변경 (변경 불필요) |
| `process()` → `processTopicMessage()` 리네이밍 (6-1) | `stopConsumers()` 자동 트리거 (별도 Phase) |
| `processStreamMessage()` 신규 메서드 (6-2) | PEL 복구 로직 (별도 Phase) |
| Kafka Listener `processTopicMessage()` 호출 변경 (6-1) | |
| `PromotionStreamConsumer` 호출 변경 (6-2) | |
| Voucher/Point Processor 추상 메서드 구현 (6-1, 6-2) | |
| 단위 테스트 (6-1, 6-2) | |

---

## 2. 현재 Processor 흐름 분석

### 2.1 AbstractCampaignPromotionProcessor.process()

```
Kafka Listener → processor.process(json)

process(json):
  1. parseMessage(json) → message
  2. isPromotionInProgress(promotionId) → 진행 중이 아니면 skip
  3. saveResult(message) → result (멱등성: 중복 시 DataIntegrityViolationException → skip)
  4. callMoneyApi(message) → moneyKey
  5. 성공: updateSuccess(result, moneyKey, promotionSummaryId)
  6. 실패: handleFailure() → updateError() + Retry 토픽 발행
```

### 2.2 PromotionStreamConsumer.onMessage()

```
Redis Stream → consumer.onMessage(record)
  → processor.process(json)  ← 현재 process() 전체를 호출
  → 수동 ACK
```

### 2.3 문제점

현재 `PromotionStreamConsumer`가 `process()`를 호출하면, `saveResult()` → `callMoneyApi()` → `updateSuccess()`가 모두 순차 실행된다.

Phase 6에서는 `process()`를 `processTopicMessage()`로 리네이밍하고 `saveResult()` 후 Stream에 enqueue하는 분기를 추가하는데, Consumer가 `processTopicMessage()`를 호출하면 **다시 enqueue → 무한 루프**가 발생한다.

따라서 **Money API 호출 로직을 `processStreamMessage()` 메서드로 분리**하고, Consumer는 이 메서드를 호출해야 한다.

---

## 3. 변경 후 흐름 설계

### 3.1 전체 아키텍처

```
[enabled=false — 기존 흐름]
  Kafka → Listener → processor.processTopicMessage(json)
                        ├── parseMessage
                        ├── isPromotionInProgress
                        ├── saveResult (멱등성)
                        └── executeMoneyApi → callMoneyApi → updateSuccess/handleFailure

[enabled=true — Stream 흐름]
  Kafka → Listener → processor.processTopicMessage(json)
                        ├── parseMessage
                        ├── isPromotionInProgress
                        ├── saveResult (멱등성)
                        └── streamProducer.enqueue() → Redis Stream XADD
                                                          ↓
                              PromotionStreamConsumer.onMessage()
                                → processor.processStreamMessage(json)
                                    ├── parseMessage
                                    ├── findResult (저장된 결과 조회)
                                    ├── isAlreadyProcessed 체크 (중복 방지)
                                    └── executeMoneyApi → callMoneyApi → updateSuccess/handleFailure
```

### 3.2 processTopicMessage() — Kafka Listener에서 호출 (Phase 6-1)

```
processTopicMessage(json):
  1. parseMessage(json) → message
  2. isPromotionInProgress(promotionId) → 진행 중이 아니면 skip
  3. saveResult(message) → result
     - 성공: 정상 진행
     - 실패(중복): skip (enabled 여부와 무관하게 동일)
  4-A. enabled=true  → enqueueToStream(promotionId, message, json) → return
  4-B. enabled=false → executeMoneyApi(message, result) (기존 동작)
```

### 3.3 processStreamMessage() — Stream Consumer에서 호출 (Phase 6-2)

```
processStreamMessage(json):
  1. parseMessage(json) → message
  2. findResult(message) → result (저장된 결과 조회)
     - 없으면 error log → return
  3. isAlreadyProcessed(result) → true이면 skip (멱등성)
  4. executeMoneyApi(message, result) → callMoneyApi → updateSuccess/handleFailure
```

### 3.4 executeMoneyApi() — 공통 로직 추출 (Phase 6-1)

`processTopicMessage()`와 `processStreamMessage()` 모두 Money API 호출 + 결과 업데이트를 수행한다.
이 로직을 `executeMoneyApi()`로 추출하여 중복을 제거한다.

```
executeMoneyApi(message, result):
  1. callMoneyApi(message) → moneyKey
  2. 성공: updateSuccess(result, moneyKey, promotionSummaryId)
  3. 실패: handleFailure() → updateError() + Retry 토픽 발행
```

---

## 4. Phase 6-1: processTopicMessage() — Kafka Listener 경로

### 4.1 범위

| 포함 | 미포함 |
|------|-------|
| `process()` → `processTopicMessage()` 리네이밍 | `processStreamMessage()` (Phase 6-2) |
| `executeMoneyApi()` 추출 | `findResult()`, `isAlreadyProcessed()` 추상 메서드 (Phase 6-2) |
| stream enqueue 분기 (`enabled` 플래그) | `PromotionStreamConsumer` 변경 (Phase 6-2) |
| `getPromotionTypeEnum()`, `getPartitionKey()` 추상 메서드 | |
| `streamProducer`, `streamProperties` 의존성 추가 | |
| Kafka Listener 호출 변경 | |
| Voucher/Point Processor: 생성자 + 추상 메서드 2개 | |

### 4.2 AbstractCampaignPromotionProcessor 변경

#### 4.2.1 새 의존성

| 의존성 | 타입 | 용도 |
|--------|------|------|
| `streamProducer` | `PromotionStreamProducer` | Redis Stream XADD |
| `streamProperties` | `RedisStreamProperties` | `enabled` 플래그 참조 |

> `PromotionStreamManager` 대신 `PromotionStreamProducer`를 주입하여 **순환 의존성을 방지**한다. (6절 참조)

```kotlin
abstract class AbstractCampaignPromotionProcessor<M : Any, R : Any>(
    protected val objectMapper: ObjectMapper,
    protected val promotionStatusCacheService: CampaignPromotionStatusCacheService,
    protected val eventProviderService: EventProviderService,
    protected val streamProducer: PromotionStreamProducer,        // 추가
    protected val streamProperties: RedisStreamProperties,        // 추가
)
```

#### 4.2.2 processTopicMessage() (기존 process() 리네이밍)

```kotlin
open fun processTopicMessage(json: String) {
    val message = parseJsonMessage(json) ?: return
    val promotionId = getPromotionId(message)
    val targetId = getTargetId(message)
    val promotionSummaryId = getPromotionSummaryId(message)

    // 1. 프로모션 상태 확인
    if (!promotionStatusCacheService.isPromotionInProgress(promotionId)) {
        log.warn { "${logPrefix(promotionId, promotionSummaryId, targetId)} Skipped - reason=promotion not in progress" }
        return
    }

    // 2. 결과 저장 (멱등성 보장 - REQUIRES_NEW 트랜잭션)
    val result = try {
        saveResult(message)
    } catch (_: Exception) {
        log.info { "${logPrefix(promotionId, promotionSummaryId, targetId)} Skipped - reason=already processed (idempotent)" }
        return
    }
    log.debug { "${logPrefix(promotionId, promotionSummaryId, targetId)} Result saved" }

    // 3. Stream enqueue 또는 직접 Money API 호출
    if (streamProperties.enabled) {
        enqueueToStream(promotionId, message, json)
    } else {
        executeMoneyApi(message, result)
    }
}
```

#### 4.2.3 executeMoneyApi() 추출

기존 `process()` 내 Money API 호출 로직을 `executeMoneyApi()`로 추출한다.

```kotlin
private fun executeMoneyApi(message: M, result: R) {
    val promotionId = getPromotionId(message)
    val targetId = getTargetId(message)
    val promotionSummaryId = getPromotionSummaryId(message)

    try {
        val moneyKey = callMoneyApi(message)
        updateSuccess(result, moneyKey, promotionSummaryId)
        log.info { "${logPrefix(promotionId, promotionSummaryId, targetId)} Succeeded - transactionKey=$moneyKey" }
    } catch (e: Exception) {
        handleFailure(message, result, exception = e)
    }
}
```

#### 4.2.4 enqueueToStream()

```kotlin
private fun enqueueToStream(promotionId: Long, message: M, json: String) {
    val streamKey = getPromotionTypeEnum().streamKey(promotionId)
    streamProducer.enqueue(streamKey, getPartitionKey(message), json)
    log.debug { "[${getPromotionType()}Processor] Enqueued to stream - promotionId=$promotionId, streamKey=$streamKey" }
}
```

#### 4.2.5 신규 추상 메서드 (Phase 6-1)

| 메서드 | 반환 타입 | 설명 |
|--------|----------|------|
| `getPromotionTypeEnum()` | `PromotionType` | PromotionType enum 반환 (Stream key 생성용) |
| `getPartitionKey(message: M)` | `String` | 메시지에서 partitionKey 추출 |

```kotlin
/**
 * PromotionType enum 반환 (Stream key 생성, enqueue에 사용)
 */
protected abstract fun getPromotionTypeEnum(): PromotionType

/**
 * 메시지에서 partitionKey 추출 (Stream enqueue 시 key로 사용)
 */
protected abstract fun getPartitionKey(message: M): String
```

### 4.3 Voucher/Point Processor 변경 (Phase 6-1)

#### 4.3.1 생성자 파라미터 추가

```kotlin
@Component
class CampaignPromotionVoucherProcessor(

    objectMapper: ObjectMapper,
    promotionStatusCacheService: CampaignPromotionStatusCacheService,
    eventProviderService: EventProviderService,
    streamProducer: PromotionStreamProducer,            // 추가
    streamProperties: RedisStreamProperties,            // 추가

    private val voucherResultRepository: CampaignPromotionVoucherResultRepository,
    private val moneyCampaignChargeApi: MoneyCampaignChargeApi,
    private val chargeRequestMapper: CampaignChargeRequestMapper,
    private val resultUpdateService: CampaignPromotionResultUpdateService

) : AbstractCampaignPromotionProcessor<CampaignPromotionVoucherMessage, CampaignPromotionVoucherResultEntity>(
    objectMapper, promotionStatusCacheService, eventProviderService, streamProducer, streamProperties
)
```

#### 4.3.2 추상 메서드 구현 (Phase 6-1)

**Voucher**:
```kotlin
override fun getPromotionTypeEnum(): PromotionType = PromotionType.VOUCHER

override fun getPartitionKey(message: CampaignPromotionVoucherMessage): String = message.partitionKey
```

**Point**:
```kotlin
override fun getPromotionTypeEnum(): PromotionType = PromotionType.POINT

override fun getPartitionKey(message: CampaignPromotionPointMessage): String = message.partitionKey
```

#### 4.3.3 기존 메서드 변경 없음

| 메서드 | 변경 여부 | 비고 |
|--------|:---:|------|
| `parseMessage()` | 유지 | |
| `getPromotionId()` | 유지 | |
| `getTargetId()` | 유지 | |
| `getPromotionSummaryId()` | 유지 | |
| `saveResult()` | 유지 | |
| `callMoneyApi()` | 유지 | |
| `updateSuccess()` | 유지 | |
| `updateError()` | 유지 | |
| `buildRetryPayload()` | 유지 | |
| `getRetryEventType()` | 유지 | |
| `getPromotionType()` | 유지 | 로깅용 String ("Voucher") |

### 4.4 Kafka Listener 변경 (Phase 6-1)

Kafka Listener의 `process()` 호출을 `processTopicMessage()`로 변경한다.

```kotlin
// CampaignVoucherPromotionListener — 변경 전
voucherProcessor.process(message)

// CampaignVoucherPromotionListener — 변경 후
voucherProcessor.processTopicMessage(message)
```

`CampaignPointPromotionListener`도 동일 패턴.

### 4.5 변경 파일 요약 (Phase 6-1)

| # | Action | File | 설명 |
|---|--------|------|------|
| 1 | **Modify** | `AbstractCampaignPromotionProcessor.kt` | `process()` → `processTopicMessage()` 리네이밍, `executeMoneyApi()` 추출, stream enqueue 분기, 추상 메서드 2개 |
| 2 | **Modify** | `CampaignPromotionVoucherProcessor.kt` | 생성자 파라미터 추가, 추상 메서드 2개 구현 |
| 3 | **Modify** | `CampaignPromotionPointProcessor.kt` | 동일 패턴 |
| 4 | **Modify** | `CampaignVoucherPromotionListener.kt` | `process()` → `processTopicMessage()` 호출 변경 |
| 5 | **Modify** | `CampaignPointPromotionListener.kt` | `process()` → `processTopicMessage()` 호출 변경 |
| 6 | **Create** | `CampaignPromotionVoucherProcessorTest.kt` | Voucher Processor 단위 테스트 (processTopicMessage) |
| 7 | **Create** | `CampaignPromotionPointProcessorTest.kt` | Point Processor 단위 테스트 (processTopicMessage) |

### 4.6 검증 방법 (Phase 6-1)

#### 4.6.1 processTopicMessage() — enabled=true 테스트

| # | 테스트 | 핵심 검증 |
|---|--------|----------|
| 1 | enabled=true → enqueue 호출 | `streamProducer.enqueue()` 호출, `callMoneyApi()` 미호출 |
| 2 | enabled=true + saveResult 성공 → enqueue | `saveResult()` → `enqueue()` 순서 검증 |
| 3 | enabled=true + saveResult 중복 → skip | saveResult 예외 발생 시 `enqueue()` 미호출 (멱등성 유지) |
| 4 | enabled=true + enqueue 실패 → 예외 전파 | 예외가 Listener로 전파 (Retryer가 재시도) |

#### 4.6.2 processTopicMessage() — enabled=false 테스트

| # | 테스트 | 핵심 검증 |
|---|--------|----------|
| 1 | enabled=false → callMoneyApi 호출 | `callMoneyApi()` 호출, `enqueue()` 미호출 |
| 2 | enabled=false + saveResult 중복 → skip | 기존 동작 유지, `callMoneyApi()` 미호출 |
| 3 | enabled=false + callMoneyApi 성공 → updateSuccess | `updateSuccess()` 호출 |
| 4 | enabled=false + callMoneyApi 실패 → handleFailure | `updateError()` + Retry 발행 |

#### 4.6.3 검증 실행

```bash
./gradlew compileTestKotlin
./gradlew test --tests "*.CampaignPromotionVoucherProcessorTest"
./gradlew test --tests "*.CampaignPromotionPointProcessorTest"
```

---

## 5. Phase 6-2: processStreamMessage() — Stream Consumer 경로

### 5.1 범위

| 포함 | 미포함 |
|------|-------|
| `processStreamMessage()` 신규 메서드 | Phase 6-1 항목 (이미 완료) |
| `findResult()`, `isAlreadyProcessed()` 추상 메서드 | `stopConsumers()` 자동 트리거 (별도 Phase) |
| Voucher/Point Processor: 추상 메서드 2개 구현 | PEL 복구 로직 (별도 Phase) |
| `PromotionStreamConsumer` 호출 변경 | |

> Phase 6-1에서 추가된 `executeMoneyApi()`를 `processStreamMessage()` 내부에서 재사용한다.

### 5.2 AbstractCampaignPromotionProcessor 변경

#### 5.2.1 processStreamMessage() 신규

```kotlin
/**
 * Redis Stream Consumer에서 호출하는 Money API 처리 메서드.
 *
 * 저장된 결과를 조회하고, PENDING 상태인 경우에만 Money API를 호출한다.
 * 이미 처리된 결과(SUCCESS, FAILED 등)는 skip한다. (멱등성 보장)
 */
open fun processStreamMessage(json: String) {
    val message = parseJsonMessage(json) ?: return
    val promotionId = getPromotionId(message)
    val targetId = getTargetId(message)
    val promotionSummaryId = getPromotionSummaryId(message)

    val result = findResult(message) ?: run {
        log.error { "${logPrefix(promotionId, promotionSummaryId, targetId)} Result not found - cannot process Money API" }
        return
    }

    if (isAlreadyProcessed(result)) {
        log.info { "${logPrefix(promotionId, promotionSummaryId, targetId)} Skipped - reason=already processed" }
        return
    }

    executeMoneyApi(message, result)
}
```

#### 5.2.2 신규 추상 메서드 (Phase 6-2)

| 메서드 | 반환 타입 | 설명 |
|--------|----------|------|
| `findResult(message: M)` | `R?` | targetId로 저장된 결과 엔티티 조회 |
| `isAlreadyProcessed(result: R)` | `Boolean` | 결과가 이미 처리되었는지 확인 (PENDING이 아니면 true) |

```kotlin
/**
 * 저장된 결과 엔티티를 조회 (targetId 기준)
 *
 * @return 결과 엔티티 또는 null
 */
protected abstract fun findResult(message: M): R?

/**
 * 결과가 이미 처리되었는지 확인
 * PENDING 상태가 아니면 true (이미 Money API 호출이 완료되었거나 실패한 상태)
 */
protected abstract fun isAlreadyProcessed(result: R): Boolean
```

### 5.3 Voucher/Point Processor 변경 (Phase 6-2)

**Voucher**:
```kotlin
override fun findResult(message: CampaignPromotionVoucherMessage): CampaignPromotionVoucherResultEntity? {
    return voucherResultRepository.findByVoucherTargetId(message.voucherTargetId.toLong())
}

override fun isAlreadyProcessed(result: CampaignPromotionVoucherResultEntity): Boolean {
    return result.processStatus != ProcessStatus.PENDING
}
```

**Point**:
```kotlin
override fun findResult(message: CampaignPromotionPointMessage): CampaignPromotionPointResultEntity? {
    return pointResultRepository.findByPointTargetId(message.pointTargetId.toLong())
}

override fun isAlreadyProcessed(result: CampaignPromotionPointResultEntity): Boolean {
    return result.processStatus != ProcessStatus.PENDING
}
```

### 5.4 PromotionStreamConsumer 변경

#### 5.4.1 현재 코드

```kotlin
override fun onMessage(message: MapRecord<String, String, String>) {
    // ...
    processor.process(json)      // ← 전체 process() 호출
    acknowledge(message)
}
```

#### 5.4.2 변경 후

```kotlin
override fun onMessage(message: MapRecord<String, String, String>) {
    // ...
    processor.processStreamMessage(json)    // ← Money API 처리만 호출
    acknowledge(message)
}
```

변경 범위: `process(json)` → `processStreamMessage(json)` 1줄 변경.

`PromotionStreamManager`는 Consumer에 processor를 전달하는 역할만 하므로 변경 불필요.

### 5.5 변경 파일 요약 (Phase 6-2)

| # | Action | File | 설명 |
|---|--------|------|------|
| 1 | **Modify** | `AbstractCampaignPromotionProcessor.kt` | `processStreamMessage()` 신규, 추상 메서드 2개 |
| 2 | **Modify** | `CampaignPromotionVoucherProcessor.kt` | 추상 메서드 2개 구현 |
| 3 | **Modify** | `CampaignPromotionPointProcessor.kt` | 동일 패턴 |
| 4 | **Modify** | `PromotionStreamConsumer.kt` | `process()` → `processStreamMessage()` 호출 변경 |
| 5 | **Modify** | `CampaignPromotionVoucherProcessorTest.kt` | processStreamMessage 테스트 추가 |
| 6 | **Modify** | `CampaignPromotionPointProcessorTest.kt` | processStreamMessage 테스트 추가 |
| 7 | **Modify** | `PromotionStreamConsumerIntegrationTest.kt` | `processStreamMessage()` 호출로 테스트 변경 |

### 5.6 검증 방법 (Phase 6-2)

#### 5.6.1 processStreamMessage() 테스트

| # | 테스트 | 핵심 검증 |
|---|--------|----------|
| 1 | 정상 처리 → callMoneyApi + updateSuccess | 결과 조회 → Money API → 성공 업데이트 |
| 2 | findResult null → skip | `callMoneyApi()` 미호출 |
| 3 | isAlreadyProcessed=true → skip | 이미 SUCCESS 상태 → `callMoneyApi()` 미호출 |
| 4 | callMoneyApi 실패 → handleFailure | `updateError()` + Retry 발행 |

#### 5.6.2 PromotionStreamConsumer 테스트

| # | 테스트 | 핵심 검증 |
|---|--------|----------|
| 1 | onMessage → processStreamMessage 호출 | `processStreamMessage(json)` 호출 (기존 `process()` 아님) |
| 2 | processStreamMessage 성공 → ACK | 수동 ACK 수행 |
| 3 | processStreamMessage 실패 → ACK 안 함 | PEL 유지 (재처리 대상) |

#### 5.6.3 검증 실행

```bash
./gradlew compileTestKotlin
./gradlew test --tests "*.CampaignPromotionVoucherProcessorTest"
./gradlew test --tests "*.CampaignPromotionPointProcessorTest"
./gradlew test --tests "*.PromotionStreamConsumerIntegrationTest"
```

---

## 6. 순환 의존성 방지

### 6.1 문제

`PromotionStreamManager`는 생성자에서 `voucherProcessor`와 `pointProcessor`를 주입받는다.
만약 Processor가 `PromotionStreamManager`를 주입받으면 **순환 의존성**이 발생한다.

```
PromotionStreamManager → CampaignPromotionVoucherProcessor
CampaignPromotionVoucherProcessor → PromotionStreamManager   ← 순환!
```

### 6.2 해결: PromotionStreamProducer 직접 주입

Processor는 Stream에 메시지를 **발행(XADD)** 하기만 하면 된다.
`PromotionStreamProducer`는 `StringRedisTemplate`만 의존하므로 순환이 발생하지 않는다.

```
PromotionStreamManager → CampaignPromotionVoucherProcessor → PromotionStreamProducer
                       → CampaignPromotionPointProcessor   → PromotionStreamProducer
```

| 의존성 | 순환 여부 | 비고 |
|--------|:---:|------|
| Processor → `PromotionStreamManager` | 순환 | Manager가 Processor를 주입 |
| Processor → `PromotionStreamProducer` | **안전** | Producer는 Processor를 주입하지 않음 |

### 6.3 Bean 가용성

`RedisStreamConfig`에 `@ConditionalOnProperty`가 **없으므로** stream beans(ConnectionFactory, RedisTemplate)는 항상 생성된다.
`PromotionStreamProducer`도 `@Service`이므로 `enabled=false`여도 Bean이 존재한다.
`enabled=false`일 때는 `enqueueToStream()`이 호출되지 않으므로 문제없다.

---

## 7. 멱등성 보장

### 7.1 processTopicMessage() — saveResult 중복 시 (Phase 6-1)

| 시나리오 | enabled=false | enabled=true |
|---------|:---:|:---:|
| saveResult 성공 | Money API 호출 | Stream enqueue |
| saveResult 중복 (DataIntegrityViolationException) | **skip** | **skip** |

`enabled` 여부와 무관하게 saveResult 중복 시 항상 skip한다.
멱등성 체크를 우회하면 모든 재전달 메시지가 Stream에 중복 enqueue되어 멱등성의 의미가 없어진다.

### 7.1.1 saveResult 성공 → enqueue 실패 케이스

이 경우 결과가 PENDING 상태로 남는다.
이는 멱등성 체크를 우회해서 해결할 문제가 아니며, 별도 복구 메커니즘으로 처리해야 한다.

| 복구 방안 | 설명 |
|----------|------|
| PENDING 상태 모니터링 | 일정 시간 이상 PENDING 상태인 결과를 주기적으로 스캔하여 재처리 |
| 수동 재처리 | 운영 도구를 통해 PENDING 건을 수동으로 Stream에 enqueue |

> 실제로 saveResult 성공 후 enqueue 실패하는 경우는 Redis 장애 상황으로, 매우 드물다.

### 7.2 processStreamMessage() — 중복 호출 시 (Phase 6-2)

Stream에 동일 메시지가 2건 들어간 경우:

```
1. Consumer A: processStreamMessage(json)
   → findResult → result (PENDING)
   → callMoneyApi → updateSuccess → result = SUCCESS

2. Consumer B: processStreamMessage(json)  (동일 메시지)
   → findResult → result (SUCCESS)
   → isAlreadyProcessed(result) == true → skip
```

| 체크 포인트 | 멱등성 보장 방법 |
|------------|----------------|
| `saveResult()` 중복 | `DataIntegrityViolationException` catch → 기존 로직 |
| `processStreamMessage()` 중복 | `isAlreadyProcessed()` → `processStatus != PENDING` → skip |
| `callMoneyApi()` 중복 방지 | `isAlreadyProcessed()` 체크로 진입 전 차단 |

### 7.3 ProcessStatus 상태 흐름

```
saveResult() → PENDING
callMoneyApi() 성공 → updateSuccess() → SUCCESS
callMoneyApi() 실패 → updateError() → RETRYING (Retry 발행) 또는 FAILED
```

`processStreamMessage()`는 `PENDING` 상태에서만 Money API를 호출한다.
`SUCCESS`, `RETRYING`, `FAILED` 상태에서는 skip한다.

---

## 8. 변경하지 않는 파일

| 파일 | 미변경 사유 |
|------|-----------|
| `CampaignVoucherPromotionRetryListener.kt` | Retry는 Stream 미경유, `AbstractCampaignPromotionRetryProcessor` 사용 |
| `CampaignPointPromotionRetryListener.kt` | 동일 |
| `CampaignPromotionStartedListener.kt` | Phase 5에서 완성, 그대로 활용 |
| `PromotionStreamManager.kt` | Consumer에 processor 전달만 함, 변경 불필요 |
| `PromotionStreamProducer.kt` | Phase 3에서 완성, 그대로 활용 |
| `CampaignPromotionVoucherResultRepository.kt` | `findByVoucherTargetId()` 이미 존재 |
| `CampaignPromotionPointResultRepository.kt` | `findByPointTargetId()` 이미 존재 |
