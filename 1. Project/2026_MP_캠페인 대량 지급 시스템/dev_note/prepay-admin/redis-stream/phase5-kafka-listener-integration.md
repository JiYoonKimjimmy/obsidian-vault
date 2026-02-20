# Kafka Listener 연동 & E2E 테스트

## 목차

1. [개요](#1-개요)
2. [기존 Listener Feature Toggle 설계](#2-기존-listener-feature-toggle-설계)
3. [신규 Promotion Started Listener 설계](#3-신규-promotion-started-listener-설계)
4. [XADD 실패 시 방어 전략](#4-xadd-실패-시-방어-전략)
5. [Retry Listener 영향도 분석](#5-retry-listener-영향도-분석)
6. [실제 구현 범위](#6-실제-구현-범위)
7. [검증 방법 (테스트)](#7-검증-방법-테스트)
8. [근거 문서 링크](#8-근거-문서-링크)

---

## 1. 개요

### 1.1 배경

Phase 1~4에서 Redis Stream 인프라, Consumer, Producer, Manager/Registry를 모두 구현하고 검증했다.

- Phase 1: Stream 전용 ConnectionFactory, Container 설정, 프로퍼티
- Phase 2: `PromotionStreamConsumer` — `onMessage()` → `processor.process()` → 수동 ACK
- Phase 3: `PromotionStreamProducer` — `enqueue()` → XADD + MAXLEN ~ trim
- Phase 4: `PromotionStreamManager` + `PromotionConsumerRegistry` — 동적 Container 생성/파괴

Phase 5에서는 이 컴포넌트들을 **기존 Kafka Listener에 연동**하고, **Feature Toggle로 기존 직접 처리와 Stream 발행 모드를 전환**할 수 있도록 한다. 또한 **신규 Kafka 이벤트(`prepay-campaign-promotion-started`)를 수신하여 Consumer를 자동 기동**하는 Listener를 구현하고, **E2E 테스트**로 전체 흐름을 검증한다.

### 1.2 목표

- `CampaignVoucherPromotionListener` Feature Toggle 적용 — `redis.stream.enabled` 분기
- `CampaignPointPromotionListener` Feature Toggle 적용 — 동일 패턴
- 신규 `CampaignPromotionStartedListener` 구현 — `startConsumers()` 트리거
- `PromotionStartedMessage` DTO 정의
- E2E 테스트를 통한 전체 흐름 검증

### 1.3 Phase 5 범위

| 포함 | 미포함 |
|------|-------|
| `CampaignVoucherPromotionListener` Feature Toggle | Retry Listener 변경 (변경 불필요 — 5절 참조) |
| `CampaignPointPromotionListener` Feature Toggle | PEL 복구 로직 상세 설계 (별도 Phase) |
| 신규 `CampaignPromotionStartedListener` | `stopConsumers()` 자동 트리거 (별도 Phase) |
| `PromotionStartedMessage` DTO | 커넥션 풀 도입 (별도 Phase) |
| `kafka.yml` 토픽 추가 | |
| E2E 테스트 | |

---

## 2. 기존 Listener Feature Toggle 설계

### 2.1 변경 대상

| Listener | 토픽 | 현재 동작 |
|---------|------|---------|
| `CampaignVoucherPromotionListener` | `prepay-campaign-promotion-voucher-publish` | `voucherProcessor.process(message)` 직접 호출 |
| `CampaignPointPromotionListener` | `prepay-campaign-promotion-point-publish` | `pointProcessor.process(message)` 직접 호출 |

### 2.2 CampaignVoucherPromotionListener 변경

**변경 전** (현재 코드):

```kotlin
@Component
class CampaignVoucherPromotionListener(
    private val voucherProcessor: CampaignPromotionVoucherProcessor
) {
    // ...

    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-voucher-publish}"],
        groupId = "prepay-admin-campaign-voucher"
    )
    fun listen(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        // ... 로깅, 빈 값 체크 ...

        voucherProcessor.process(message)
        acknowledge.acknowledge()
    }
}
```

**변경 후**:

```kotlin
@Component
class CampaignVoucherPromotionListener(
    private val voucherProcessor: CampaignPromotionVoucherProcessor,
    private val streamManager: PromotionStreamManager,
    private val streamProperties: RedisStreamProperties
) {
    private val log = KotlinLogging.logger {}

    companion object {
        private const val LOG_PREFIX = "[CampaignPromotion][promotionId=-]"
        private const val COMPONENT = "[VoucherListener]"
    }

    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-voucher-publish}"],
        groupId = "prepay-admin-campaign-voucher"
    )
    fun listen(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "$LOG_PREFIX$COMPONENT Received - partitionKey=$key" }
        log.debug { "$LOG_PREFIX$COMPONENT Message payload - partitionKey=$key, message=$message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "$LOG_PREFIX$COMPONENT Skipped - reason=missing key or message, partitionKey=$key" }
            return acknowledge.acknowledge()
        }

        if (streamProperties.enabled) {
            val promotionId = extractPromotionId(message)
            streamManager.enqueue(promotionId, "voucher", key, message)
        } else {
            voucherProcessor.process(message)
        }

        acknowledge.acknowledge()
    }

    private fun extractPromotionId(message: String): Long {
        // JSON에서 promotionId 추출 (PocketMessageDto<CampaignPromotionVoucherMessage> 구조)
        // 경량 파싱: 전체 역직렬화 없이 promotionId만 추출
        val regex = """"promotionId"\s*:\s*"(\d+)"""".toRegex()
        return regex.find(message)?.groupValues?.get(1)?.toLong()
            ?: throw IllegalArgumentException("Cannot extract promotionId from message")
    }
}
```

### 2.3 CampaignPointPromotionListener 변경

동일한 패턴으로 변경한다. `"voucher"` → `"point"`, `voucherProcessor` → `pointProcessor`.

```kotlin
@Component
class CampaignPointPromotionListener(
    private val pointProcessor: CampaignPromotionPointProcessor,
    private val streamManager: PromotionStreamManager,
    private val streamProperties: RedisStreamProperties
) {
    private val log = KotlinLogging.logger {}

    companion object {
        private const val LOG_PREFIX = "[CampaignPromotion][promotionId=-]"
        private const val COMPONENT = "[PointListener]"
    }

    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-point-publish}"],
        groupId = "prepay-admin-campaign-point"
    )
    fun listen(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "$LOG_PREFIX$COMPONENT Received - partitionKey=$key" }
        log.debug { "$LOG_PREFIX$COMPONENT Message payload - partitionKey=$key, message=$message" }

        if (key.isBlank() || message.isBlank()) {
            log.warn { "$LOG_PREFIX$COMPONENT Skipped - reason=missing key or message, partitionKey=$key" }
            return acknowledge.acknowledge()
        }

        if (streamProperties.enabled) {
            val promotionId = extractPromotionId(message)
            streamManager.enqueue(promotionId, "point", key, message)
        } else {
            pointProcessor.process(message)
        }

        acknowledge.acknowledge()
    }

    private fun extractPromotionId(message: String): Long {
        val regex = """"promotionId"\s*:\s*"(\d+)"""".toRegex()
        return regex.find(message)?.groupValues?.get(1)?.toLong()
            ?: throw IllegalArgumentException("Cannot extract promotionId from message")
    }
}
```

### 2.4 Feature Toggle 동작

| `redis.stream.enabled` | 동작 |
|:---:|------|
| `false` (기본값) | 기존 직접 처리 — `processor.process(message)` 호출 |
| `true` | Stream 발행 — `streamManager.enqueue(promotionId, type, key, message)` → Redis Stream XADD |

```
enabled=false (기존):
  Kafka → VoucherListener → voucherProcessor.process(message) → Money API → DB

enabled=true (신규):
  Kafka → VoucherListener → streamManager.enqueue() → Redis Stream XADD → Kafka ACK
                                                          ↓
                              PromotionStreamConsumer → processor.process(message) → Money API → DB
```

### 2.5 extractPromotionId() 설계

Kafka 메시지 JSON에서 `promotionId`를 추출하여 Stream key 라우팅에 사용한다.

메시지 구조: `PocketMessageDto<CampaignPromotionVoucherMessage>`

```json
{
  "sentAt": "2026-02-10T10:00:00",
  "version": 1,
  "topic": "prepay-campaign-promotion-voucher-publish",
  "payload": {
    "promotionId": "12345",
    "promotionSummaryId": "67890",
    "voucherTargetId": "100",
    ...
  }
}
```

**추출 방식**: 정규식으로 `"promotionId":"12345"` 패턴 매칭.

| 항목 | 설명 |
|------|------|
| 정규식 | `"promotionId"\s*:\s*"(\d+)"` |
| 대상 | Kafka 메시지 JSON 전체 |
| 반환 | `Long` (promotionId) |
| 실패 시 | `IllegalArgumentException` → Kafka ACK 되지 않음 → 재전달 |

> **전체 역직렬화 대비 장점**: `ObjectMapper`로 `PocketMessageDto<CampaignPromotionVoucherMessage>` 전체를 파싱하는 것보다 정규식이 훨씬 가볍다. Listener 단계에서는 promotionId만 필요하므로 경량 파싱이 적합하다. 전체 역직렬화는 Stream Consumer가 `processor.process(json)`을 호출할 때 Processor 내부에서 수행한다.

### 2.6 생성자 파라미터 변경 요약

**CampaignVoucherPromotionListener**:

| 파라미터 | 변경 | 용도 |
|---------|:---:|------|
| `voucherProcessor` | 기존 유지 | `enabled=false` 시 기존 직접 처리 |
| `streamManager` | **추가** | `enabled=true` 시 `enqueue()` 호출 |
| `streamProperties` | **추가** | `enabled` 플래그 참조 |

**CampaignPointPromotionListener**:

| 파라미터 | 변경 | 용도 |
|---------|:---:|------|
| `pointProcessor` | 기존 유지 | `enabled=false` 시 기존 직접 처리 |
| `streamManager` | **추가** | `enabled=true` 시 `enqueue()` 호출 |
| `streamProperties` | **추가** | `enabled` 플래그 참조 |

---

## 3. 신규 Promotion Started Listener 설계

### 3.1 역할

`prepay-campaign-promotion-started` Kafka 이벤트를 수신하여 `PromotionStreamManager.startConsumers()`를 호출한다.
프로모션이 시작될 때 이 이벤트가 발행되면, 각 인스턴스가 독립적으로 Consumer를 기동한다.

### 3.2 전체 흐름

```
캠페인 시작 로직 (Producer 측)
    └── Kafka 발행: prepay-campaign-promotion-started
        └── { promotionId: 100, totalCount: 100000, type: "voucher" }

4개 인스턴스 각각:
    CampaignPromotionStartedListener.listen()
        └── streamManager.startConsumers(100, 100000, "voucher")
            ├── ensureStreamAndGroup()  ← BUSYGROUP으로 중복 안전
            ├── createContainer() + N개 Subscription
            ├── container.start()
            └── registry.register()
```

### 3.3 PromotionStartedMessage DTO

```kotlin
data class PromotionStartedMessage(
    val promotionId: Long,
    val totalCount: Int,
    val type: String             // "voucher" 또는 "point"
)
```

| 필드 | 타입 | 설명 |
|------|------|------|
| `promotionId` | `Long` | 프로모션 ID |
| `totalCount` | `Int` | 프로모션 대상자 수 (Consumer 수 결정에 사용) |
| `type` | `String` | `"voucher"` 또는 `"point"` |

> 이벤트 페이로드는 `PocketMessageDto<PromotionStartedMessage>` 형태로 래핑될 수 있다.
> Producer 측에서 해당 이벤트를 발행하도록 변경이 필요하다 (이 문서의 범위 외).

### 3.4 CampaignPromotionStartedListener

```kotlin
@Component
@ConditionalOnProperty(prefix = "redis.stream", name = ["enabled"], havingValue = "true")
class CampaignPromotionStartedListener(
    private val streamManager: PromotionStreamManager,
    private val objectMapper: ObjectMapper
) {
    private val log = KotlinLogging.logger {}

    companion object {
        private const val LOG_PREFIX = "[CampaignPromotion]"
        private const val COMPONENT = "[PromotionStartedListener]"
    }

    @KafkaListener(
        topics = ["\${kafka.topic.campaign-promotion-started}"],
        groupId = "prepay-admin-campaign-promotion-started"
    )
    fun listen(
        @Header(KafkaHeaders.RECEIVED_KEY) key: String,
        message: String,
        acknowledge: Acknowledgment
    ) {
        log.info { "$LOG_PREFIX$COMPONENT Received - key=$key" }

        try {
            val event = objectMapper.readValue(
                message,
                object : TypeReference<PocketMessageDto<PromotionStartedMessage>>() {}
            )
            val payload = event.payload

            log.info {
                "$LOG_PREFIX$COMPONENT Starting consumers" +
                " - promotionId=${payload.promotionId}, totalCount=${payload.totalCount}, type=${payload.type}"
            }

            streamManager.startConsumers(payload.promotionId, payload.totalCount, payload.type)
        } catch (e: Exception) {
            log.error(e) { "$LOG_PREFIX$COMPONENT Failed to start consumers - key=$key" }
        }

        acknowledge.acknowledge()
    }
}
```

### 3.5 핵심 설계 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| `@ConditionalOnProperty` | `redis.stream.enabled=true` 일 때만 Bean 생성 | `enabled=false`이면 이 Listener가 불필요 |
| `acknowledge.acknowledge()` | 항상 호출 (성공/실패 모두) | `startConsumers()` 실패 시에도 Kafka 메시지를 재처리하지 않음 — 중복 `startConsumers()`는 `isActive()` 체크로 무시되므로 안전하지만, 파싱 실패 등의 경우 무한 재시도 방지 |
| `groupId` | `prepay-admin-campaign-promotion-started` | 4개 인스턴스 모두가 이벤트를 수신해야 하므로 **인스턴스별로 다른 groupId를 사용하거나, 별도 Kafka 토픽 설정**이 필요 (아래 3.6절 참조) |

### 3.6 다중 인스턴스 수신 전략

4개 인스턴스 모두가 `startConsumers()`를 호출해야 한다 (각 인스턴스에서 로컬 Container를 생성해야 하므로).

**문제**: 동일 `groupId`를 사용하면 Kafka Consumer Group이 메시지를 1개 인스턴스에만 전달한다.

**해결 방안**:

| 방안 | 설명 | 장점 | 단점 |
|------|------|------|------|
| **A. 인스턴스별 고유 groupId** | `groupId = "prepay-admin-promotion-started-${instanceId}"` | 모든 인스턴스 수신 보장 | groupId 동적 생성 필요, 관리 복잡 |
| **B. Broadcast 토픽** | Kafka 토픽 파티션 수 ≥ 인스턴스 수 + 모든 인스턴스가 같은 파티션을 소비하도록 설정 | — | Kafka 기본 동작과 충돌 |
| **C. Spring Kafka `id` 속성 사용** | `@KafkaListener(id = "promotion-started-#{T(java.util.UUID).randomUUID()}")` | 간단 | 재시작 시 offset 초기화 |

**권장: 방안 A — 인스턴스별 고유 groupId**

```kotlin
@KafkaListener(
    topics = ["\${kafka.topic.campaign-promotion-started}"],
    groupId = "#{T(java.net.InetAddress).getLocalHost().getHostName() + '-' + T(java.lang.ProcessHandle).current().pid() + '-promotion-started'}"
)
```

또는 `@Value`로 주입:

```kotlin
@KafkaListener(
    topics = ["\${kafka.topic.campaign-promotion-started}"],
    groupId = "\${kafka.group.campaign-promotion-started}"
)
```

```yaml
# kafka.yml
kafka:
  group:
    campaign-promotion-started: "prepay-admin-promotion-started-${HOSTNAME:localhost}"
```

> 각 인스턴스가 고유한 groupId를 가지면, 모든 인스턴스가 동일 토픽의 모든 메시지를 수신한다.
> 이후 `startConsumers()` 내부의 `isActive()` 체크와 BUSYGROUP 처리로 중복 실행이 안전하게 방지된다.

### 3.7 kafka.yml 토픽 추가

```yaml
kafka:
  topic:
    # ... 기존 토픽 ...
    campaign-promotion-started: prepay-campaign-promotion-started
```

---

## 4. XADD 실패 시 방어 전략

### 4.1 실패 시나리오

`streamManager.enqueue()` → `producer.enqueue()` → `streamOps.add()` 실패 시:

```
Kafka VoucherListener.listen()
    │
    ├── streamManager.enqueue(promotionId, "voucher", key, message)
    │       └── producer.enqueue(streamKey, key, message)
    │               └── streamOps.add(record, addOptions)
    │                       └── 실패 → IllegalStateException 또는 RedisException
    │
    ├── 예외 발생 → acknowledge.acknowledge() 호출되지 않음
    │
    └── Kafka가 메시지를 재전달 (Manual ACK이므로 미ACK 메시지는 재전달)
```

### 4.2 방어 흐름

| 단계 | 동작 | 실패 시 |
|:---:|------|--------|
| 1 | `streamManager.enqueue()` 호출 | 예외 → 2번으로 |
| 2 | 예외 발생 → `acknowledge.acknowledge()` 미호출 | Kafka 재전달 |
| 3 | Kafka가 동일 메시지 재전달 | Listener 재수신 |
| 4 | `enqueue()` 재시도 → 성공 | 정상 흐름 |
| 5 | 만약 이미 동일 메시지가 XADD된 상태에서 재전달 | 중복 XADD (Stream에 동일 내용 2건) |
| 6 | Consumer가 `processor.process()` 호출 → `saveResult()` 중복 | `DataIntegrityViolationException` → 멱등성 보장 (catch → skip) |

### 4.3 멱등성 보장 구조

```
중복 XADD 시나리오:
  1. XADD 성공 (RecordId: 1234-0)
  2. Kafka ACK 실패 (네트워크 등)
  3. Kafka 재전달 → XADD 다시 성공 (RecordId: 1234-1) → 동일 내용 2건
  4. Consumer가 RecordId: 1234-0 처리 → processor.process() → saveResult() 성공
  5. Consumer가 RecordId: 1234-1 처리 → processor.process() → saveResult() 중복
     → DataIntegrityViolationException → catch → skip (멱등성)
```

| 컴포넌트 | 멱등성 보장 방법 |
|---------|---------------|
| `AbstractCampaignPromotionProcessor.process()` | `saveResult()`에서 `DataIntegrityViolationException` catch → skip |
| `saveResult()` | `REQUIRES_NEW` 트랜잭션 + Unique Constraint (targetId 기준) |

> 기존 Processor의 멱등성 로직이 그대로 작동하므로 Stream 도입으로 인한 추가 멱등성 처리는 불필요하다.

---

## 5. Retry Listener 영향도 분석

### 5.1 Retry 흐름 (현재)

```
기존 흐름:
  Kafka (publish 토픽)
    → Listener → processor.process(json)
                    → callMoneyApi() 실패
                    → updateError() + Retry 토픽 발행
                        → Retry Listener → retryProcessor.process(json)
                            → callMoneyApi() 재시도
```

### 5.2 Retry 흐름 (Stream 도입 후)

```
Stream 도입 후 흐름:
  Kafka (publish 토픽)
    → Listener → streamManager.enqueue() → Redis Stream XADD → Kafka ACK
                                                  ↓
                            PromotionStreamConsumer.onMessage()
                              → processor.process(json)
                                  → callMoneyApi() 실패
                                  → updateError() + Retry 토픽 발행
                                      → Retry Listener → retryProcessor.process(json)
                                          → callMoneyApi() 재시도 (직접 처리)
```

### 5.3 Retry Listener 변경 불필요

| 항목 | 설명 |
|------|------|
| Retry 메시지 발행 주체 | `AbstractCampaignPromotionProcessor.handleFailure()` — Stream Consumer가 호출하는 `processor.process()`의 내부 로직 |
| Retry 메시지 수신 | `CampaignVoucherPromotionRetryListener`, `CampaignPointPromotionRetryListener` |
| Retry 처리 방식 | `retryProcessor.process(json)` → 직접 Money API 재호출 |
| Stream 경유 여부 | **NO** — Retry 메시지는 Stream을 거치지 않고 직접 처리 |

Retry Listener는 변경하지 않는 이유:
1. Retry 메시지는 개별 건 재처리이므로 병렬 처리가 불필요하다
2. Retry 메시지량은 소량이므로 순차 처리로 충분하다
3. `AbstractCampaignPromotionRetryProcessor`는 Stream과 무관하게 동작한다

### 5.4 변경하지 않는 Listener 목록

| Listener | 이유 |
|---------|------|
| `CampaignVoucherPromotionRetryListener` | Retry는 Stream 미경유, 소량 직접 처리 |
| `CampaignPointPromotionRetryListener` | 동일 |

---

## 6. 실제 구현 범위

### 6.1 신규 파일

| # | 파일 | 설명 |
|---|------|------|
| 1 | `CampaignPromotionStartedListener.kt` | `prepay-campaign-promotion-started` 이벤트 수신 → `startConsumers()` 호출 |
| 2 | `PromotionStartedMessage.kt` | 이벤트 페이로드 DTO (`promotionId`, `totalCount`, `type`) |

### 6.2 변경 파일

| # | 파일 | 변경 내용 |
|---|------|---------|
| 1 | `CampaignVoucherPromotionListener.kt` | `streamManager`, `streamProperties` 주입 + Feature Toggle 분기 |
| 2 | `CampaignPointPromotionListener.kt` | 동일 패턴 |
| 3 | `kafka.yml` | `campaign-promotion-started` 토픽 추가 |

### 6.3 변경하지 않는 파일

| 파일 | 이유 |
|------|------|
| `CampaignVoucherPromotionRetryListener.kt` | Retry는 Stream 미경유 (5절 참조) |
| `CampaignPointPromotionRetryListener.kt` | 동일 |
| `AbstractCampaignPromotionProcessor.kt` | 기존 비즈니스 로직 그대로 재사용 |
| `AbstractCampaignPromotionRetryProcessor.kt` | 동일 |
| `CampaignPromotionVoucherProcessor.kt` | Consumer가 기존 `process()` 호출 |
| `CampaignPromotionPointProcessor.kt` | 동일 |
| Phase 1~4 코드 | 모두 그대로 활용 |

### 6.4 의존 관계

```
Phase 5 구현이 의존하는 Phase 1~4 컴포넌트:

CampaignVoucherPromotionListener (변경)
  └── PromotionStreamManager (Phase 4)
       ├── enqueue() → PromotionStreamProducer (Phase 3)
       └── startConsumers()
            ├── PromotionStreamConsumer (Phase 2)
            └── streamRedisConnectionFactory (Phase 1)

CampaignPromotionStartedListener (신규)
  └── PromotionStreamManager.startConsumers() (Phase 4)
```

---

## 7. 검증 방법 (테스트)

### 7.1 Feature Toggle enabled=true 테스트

**테스트 목표**: `redis.stream.enabled=true` 일 때 Listener가 `streamManager.enqueue()`를 호출하는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `enqueue()` 호출됨 | Mock `streamManager`의 `enqueue()` 호출 verify |
| 2 | `processor.process()` 호출 안 됨 | Mock `voucherProcessor`의 `process()` never verify |
| 3 | 올바른 promotionId 추출 | `enqueue()` 호출 시 첫 번째 인자 == 메시지 내 promotionId |
| 4 | Kafka ACK 수행됨 | `acknowledge.acknowledge()` 호출 verify |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enabled=true 일 때 streamManager_enqueue가 호출된다`() {
    // given
    val properties = RedisStreamProperties(enabled = true)
    val listener = CampaignVoucherPromotionListener(
        voucherProcessor = mockVoucherProcessor,
        streamManager = mockStreamManager,
        streamProperties = properties
    )

    val key = "partition-key-1"
    val promotionId = 12345L
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":"$promotionId","voucherTargetId":"100"}}"""

    // when
    listener.listen(key, message, mockAcknowledgment)

    // then
    verify(mockStreamManager).enqueue(promotionId, "voucher", key, message)
    verify(mockVoucherProcessor, never()).process(any())
    verify(mockAcknowledgment).acknowledge()
}
```

### 7.2 Feature Toggle enabled=false 테스트

**테스트 목표**: `redis.stream.enabled=false` 일 때 Listener가 기존 `processor.process()`를 호출하는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `processor.process()` 호출됨 | Mock `voucherProcessor`의 `process()` 호출 verify |
| 2 | `enqueue()` 호출 안 됨 | Mock `streamManager`의 `enqueue()` never verify |
| 3 | Kafka ACK 수행됨 | `acknowledge.acknowledge()` 호출 verify |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enabled=false 일 때 processor_process가 호출된다`() {
    // given
    val properties = RedisStreamProperties(enabled = false)
    val listener = CampaignVoucherPromotionListener(
        voucherProcessor = mockVoucherProcessor,
        streamManager = mockStreamManager,
        streamProperties = properties
    )

    val key = "partition-key-1"
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":"12345","voucherTargetId":"100"}}"""

    // when
    listener.listen(key, message, mockAcknowledgment)

    // then
    verify(mockVoucherProcessor).process(message)
    verify(mockStreamManager, never()).enqueue(any(), any(), any(), any())
    verify(mockAcknowledgment).acknowledge()
}
```

### 7.3 XADD 실패 시 Kafka ACK 안 됨 테스트

**테스트 목표**: `enqueue()` 실패(예외) 시 `acknowledge.acknowledge()`가 호출되지 않아 Kafka가 메시지를 재전달하는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `enqueue()` 예외 발생 | Mock `streamManager`가 예외 throw |
| 2 | Kafka ACK 안 됨 | `acknowledge.acknowledge()` never verify |
| 3 | 예외 전파됨 | `assertThrows` |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enqueue 실패 시 Kafka ACK이 수행되지 않는다`() {
    // given
    val properties = RedisStreamProperties(enabled = true)
    val listener = CampaignVoucherPromotionListener(
        voucherProcessor = mockVoucherProcessor,
        streamManager = mockStreamManager,
        streamProperties = properties
    )

    whenever(mockStreamManager.enqueue(any(), any(), any(), any()))
        .thenThrow(RuntimeException("Redis connection failed"))

    val key = "partition-key-1"
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":"12345","voucherTargetId":"100"}}"""

    // when & then
    assertThrows<RuntimeException> {
        listener.listen(key, message, mockAcknowledgment)
    }
    verify(mockAcknowledgment, never()).acknowledge()
}
```

### 7.4 extractPromotionId 테스트

**테스트 목표**: JSON 메시지에서 promotionId를 정확하게 추출하는지 검증한다.

**검증 항목**:

| # | 검증 | 입력 | 기대값 |
|---|------|------|-------|
| 1 | 정상 추출 | `"promotionId":"12345"` 포함 JSON | `12345L` |
| 2 | 큰 ID | `"promotionId":"9999999999"` 포함 JSON | `9999999999L` |
| 3 | 추출 실패 | promotionId 없는 JSON | `IllegalArgumentException` |

**테스트 코드 흐름**:

```kotlin
@Test
fun `extractPromotionId가 JSON에서 promotionId를 추출한다`() {
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":"12345","voucherTargetId":"100"}}"""
    val result = listener.extractPromotionId(message)
    assertThat(result).isEqualTo(12345L)
}

@Test
fun `extractPromotionId가 promotionId가 없으면 예외를 던진다`() {
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"voucherTargetId":"100"}}"""
    assertThrows<IllegalArgumentException> {
        listener.extractPromotionId(message)
    }
}
```

> `extractPromotionId()`가 `private`이면 Listener의 `listen()` 메서드를 통해 간접 테스트한다.

### 7.5 CampaignPromotionStartedListener 테스트

**테스트 목표**: `prepay-campaign-promotion-started` 이벤트 수신 시 `startConsumers()`가 올바른 파라미터로 호출되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `startConsumers()` 호출됨 | Mock `streamManager`의 `startConsumers()` 호출 verify |
| 2 | 올바른 파라미터 | `promotionId`, `totalCount`, `type` 일치 확인 |
| 3 | Kafka ACK 수행됨 | `acknowledge.acknowledge()` 호출 verify |

**테스트 코드 흐름**:

```kotlin
@Test
fun `promotion-started 이벤트 수신 시 startConsumers가 호출된다`() {
    // given
    val key = "100"
    val message = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":100,"totalCount":50000,"type":"voucher"}}"""

    // when
    startedListener.listen(key, message, mockAcknowledgment)

    // then
    verify(mockStreamManager).startConsumers(100L, 50000, "voucher")
    verify(mockAcknowledgment).acknowledge()
}
```

### 7.6 CampaignPromotionStartedListener 파싱 실패 테스트

**테스트 목표**: 잘못된 메시지 형식이라도 예외가 전파되지 않고 Kafka ACK이 수행되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `startConsumers()` 호출 안 됨 | Mock `streamManager`의 `startConsumers()` never verify |
| 2 | 예외 전파 안 됨 | `assertDoesNotThrow` |
| 3 | Kafka ACK 수행됨 | `acknowledge.acknowledge()` 호출 verify |

**테스트 코드 흐름**:

```kotlin
@Test
fun `잘못된 메시지 형식이라도 Kafka ACK이 수행된다`() {
    // given
    val key = "100"
    val message = """invalid json"""

    // when & then
    assertDoesNotThrow {
        startedListener.listen(key, message, mockAcknowledgment)
    }
    verify(mockStreamManager, never()).startConsumers(any(), any(), any())
    verify(mockAcknowledgment).acknowledge()
}
```

### 7.7 E2E 연동 테스트: enabled=true → enqueue → Consumer 수신

**테스트 목표**: Feature Toggle이 켜진 상태에서 Listener → Redis Stream XADD → Consumer 수신 → Processor 처리 → ACK의 전체 흐름을 검증한다.

> 이 테스트는 실제 Redis 연결이 필요한 통합 테스트이다.

**설정**:
- `redis.stream.enabled=true`
- `PromotionStreamManager.startConsumers()` 사전 호출 (Consumer 기동)
- Listener의 `listen()` 직접 호출 (Kafka 없이 메시지 수신 시뮬레이션)

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | Redis Stream에 메시지 발행됨 | `XLEN` > 0 |
| 2 | Consumer가 메시지 수신 | Mock Processor `process()` 호출 확인 |
| 3 | ACK 완료 | `XPENDING` pending count == 0 |
| 4 | 올바른 JSON 전달 | `process()` 인자가 원본 메시지와 일치 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enabled=true 시 Listener → Redis Stream → Consumer 전체 흐름`() {
    val promotionId = 1L
    val type = "voucher"
    val streamKey = "promotion:$promotionId:$type:stream"
    val consumerGroup = "promotion-$promotionId-$type-group"

    // 1. Consumer 사전 기동
    manager.startConsumers(promotionId, 1000, type)

    // 2. Listener로 메시지 10건 수신 시뮬레이션
    val messages = (0 until 10).map { i ->
        val json = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":"$promotionId","promotionSummaryId":"1","voucherTargetId":"$i","partitionKey":"key-$i","customerUid":"uid-$i","merchantCode":"M001","campaignCode":"C001","amount":"1000","voucherNumber":"V$i","isWithdrawal":false}}"""
        json
    }

    messages.forEachIndexed { i, msg ->
        voucherListener.listen("key-$i", msg, mockAcknowledgment)
    }

    // 3. 수신 대기
    Thread.sleep(5000)

    // 4. 검증: 모든 메시지 처리
    verify(mockProcessor, times(10)).process(any())

    // 5. 검증: ACK 완료
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(0)

    // 6. 검증: Kafka ACK 10회 수행
    verify(mockAcknowledgment, times(10)).acknowledge()

    // cleanup
    manager.stopConsumers(promotionId)
}
```

### 7.8 E2E 연동 테스트: PromotionStartedListener → startConsumers → enqueue → 수신

**테스트 목표**: 신규 Promotion Started 이벤트 수신 → Consumer 기동 → 메시지 발행 → 수신 → 처리의 전체 흐름을 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | `startConsumers()` 호출됨 | Registry `isActive()` == `true` |
| 2 | 이후 enqueue한 메시지가 수신됨 | Mock Processor `process()` 호출 확인 |
| 3 | stopConsumers 후 정리 | Registry에서 제거, Stream 삭제 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `PromotionStarted 이벤트 → Consumer 기동 → enqueue → 수신 전체 흐름`() {
    val promotionId = 1L
    val type = "voucher"
    val streamKey = "promotion:$promotionId:$type:stream"

    // 1. Promotion Started 이벤트로 Consumer 기동
    val startedMessage = """{"sentAt":"2026-02-10","version":1,"payload":{"promotionId":$promotionId,"totalCount":1000,"type":"$type"}}"""
    startedListener.listen("$promotionId", startedMessage, mockAcknowledgment)

    // 2. Consumer 기동 확인
    assertThat(consumerRegistry.isActive(promotionId)).isTrue()

    // 3. 메시지 5건 발행
    repeat(5) { i ->
        manager.enqueue(promotionId, type, "key-$i", """{"promotionId":"$promotionId","targetId":$i}""")
    }

    // 4. 수신 대기
    Thread.sleep(5000)

    // 5. 검증: 모든 메시지 처리
    verify(mockProcessor, times(5)).process(any())

    // cleanup
    manager.stopConsumers(promotionId)
    assertThat(streamRedisTemplate.hasKey(streamKey)).isFalse()
}
```

### 7.9 PointListener Feature Toggle 테스트

`CampaignPointPromotionListener`에 대해서도 7.1~7.3과 동일한 패턴의 테스트를 작성한다.
Voucher 테스트와 차이점: `"voucher"` → `"point"`, `voucherProcessor` → `pointProcessor`.

### 7.10 테스트 인프라

#### 단위 테스트 (7.1~7.6, 7.9)

Mock 기반 단위 테스트. Redis 연결 불필요.

```kotlin
// Mock 객체
val mockStreamManager = mock<PromotionStreamManager>()
val mockVoucherProcessor = mock<CampaignPromotionVoucherProcessor>()
val mockPointProcessor = mock<CampaignPromotionPointProcessor>()
val mockAcknowledgment = mock<Acknowledgment>()
```

#### 통합 테스트 (7.7~7.8)

기존 `StreamMultiplexingTestConfig` 패턴을 따른다. Phase 1에서 구성한 `streamRedisConnectionFactory`를 사용한다.

```kotlin
@BeforeEach
fun setup() {
    streamRedisTemplate.delete("promotion:1:voucher:stream")
}

@AfterEach
fun cleanup() {
    consumerRegistry.shutdownAll()
    streamRedisTemplate.delete("promotion:1:voucher:stream")
}
```

---

## 8. 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md) | Phase 1 인프라 구성 — `RedisStreamProperties.enabled` 프로퍼티 |
| [`phase2-redis-stream-consumer.md`](./phase2-redis-stream-consumer.md) | Phase 2 Consumer 구현 — `PromotionStreamConsumer` |
| [`phase3-redis-stream-producer.md`](./phase3-redis-stream-producer.md) | Phase 3 Producer 구현 — `PromotionStreamProducer.enqueue()` |
| [`phase4-redis-stream-manager.md`](./phase4-redis-stream-manager.md) | Phase 4 Manager/Registry 구현 — `PromotionStreamManager.startConsumers()`, `enqueue()` |
| [`redis-stream-development-plan.md`](./redis-stream-development-plan.md) | 전체 개발 계획 (5 Phase) |
