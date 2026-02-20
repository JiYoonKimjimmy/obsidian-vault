# Redis Stream Consumer 구현

## 목차

1. [개요](#1-개요)
2. [PromotionStreamConsumer 설계](#2-promotionstreamconsumer-설계)
3. [Container + Subscription 구성 (테스트용)](#3-container--subscription-구성-테스트용)
4. [수동 ACK vs receiveAutoAck 결정 근거](#4-수동-ack-vs-receiveautoack-결정-근거)
5. [실제 구현 범위](#5-실제-구현-범위)
6. [검증 방법 (테스트)](#6-검증-방법-테스트)
7. [근거 문서 링크](#7-근거-문서-링크)

---

## 1. 개요

### 1.1 배경

Phase 1([`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md))에서 Stream 전용 ConnectionFactory, Container 설정, 프로퍼티를 구성하고 Redis Stream 연결이 정상 동작하는지 검증했다.

Phase 2에서는 이 인프라 위에 **`PromotionStreamConsumer` 컴포넌트를 구현**하고, Container에 다중 Subscription을 등록하여 **메시지 수신 및 분배가 정상 동작하는지 검증**한다.

### 1.2 목표

- `PromotionStreamConsumer` (`StreamListener`) 구현 — `onMessage()` → `processor.process(json)` → 수동 ACK
- Container + 다중 Subscription 수동 생성 (테스트 코드에서 직접)
- 다중 Consumer 메시지 분배 수신 검증

### 1.3 Phase 2 범위

| 포함 | 미포함 (이후 Phase) |
|------|-------------------|
| `PromotionStreamConsumer` 구현 | Producer (`PromotionStreamProducer`) — Phase 3 |
| Container + Subscription 수동 생성 (테스트용) | 동적 Container 생성/파괴 via Manager — Phase 4 |
| 다중 Consumer 수신 검증 테스트 | Kafka Listener 연동 — Phase 5 |
| 수동 ACK 검증 테스트 | |
| 에러 처리 테스트 | |

> 테스트에서 메시지 발행은 `streamOps.add()`로 직접 수행한다. Producer 컴포넌트는 Phase 3에서 구현한다.

---

## 2. PromotionStreamConsumer 설계

### 2.1 클래스 구조

`StreamListener<String, MapRecord<String, String, String>>`를 구현하여 Container로부터 메시지를 수신하고 기존 Processor를 호출한다.

```kotlin
class PromotionStreamConsumer(
    private val processor: AbstractCampaignPromotionProcessor<*, *>,
    private val streamRedisTemplate: StringRedisTemplate,
    private val streamKey: String,
    private val consumerGroup: String
) : StreamListener<String, MapRecord<String, String, String>> {

    private val log = KotlinLogging.logger {}

    override fun onMessage(message: MapRecord<String, String, String>) {
        val payload = message.value
        val json = payload["message"] ?: run {
            log.warn { "[StreamConsumer] Missing 'message' field - recordId=${message.id}" }
            acknowledge(message)  // 잘못된 메시지도 ACK하여 PEL에서 제거
            return
        }
        val key = payload["key"] ?: ""

        try {
            processor.process(json)
            acknowledge(message)
            log.debug { "[StreamConsumer] Processed - recordId=${message.id}, key=$key" }
        } catch (e: Exception) {
            log.error(e) { "[StreamConsumer] Processing failed - recordId=${message.id}, key=$key" }
            // ACK하지 않음 → PEL에 유지 → 재처리 대상
        }
    }

    private fun acknowledge(message: MapRecord<String, String, String>) {
        streamRedisTemplate.opsForStream().acknowledge(streamKey, consumerGroup, message.id)
    }
}
```

### 2.2 onMessage() 흐름

```
Container → StreamPollTask → XREADGROUP → 메시지 수신
                                          │
                                          ▼
                              PromotionStreamConsumer.onMessage(message)
                                          │
                              ┌───────────┴───────────┐
                              │  payload["message"]    │
                              │  필드 존재하는가?        │
                              └───────────┬───────────┘
                                    │           │
                                   YES          NO
                                    │           │
                                    ▼           ▼
                          processor.process()  acknowledge()
                                    │          (잘못된 메시지 제거)
                              ┌─────┴─────┐
                              │           │
                           성공          예외
                              │           │
                              ▼           ▼
                        acknowledge()  ACK 안 함
                        (PEL 제거)     (PEL 유지)
```

### 2.3 핵심 설계 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| `"message"` 필드 없는 메시지 | ACK 처리 (PEL에서 제거) | 잘못된 형식의 메시지가 PEL에 영원히 남아 재처리 반복을 방지 |
| `process()` 성공 시 | 수동 ACK | 처리 완료를 보장한 후에만 ACK |
| `process()` 예외 시 | ACK 안 함 | PEL에 유지 → 재시작 시 재처리 가능 |
| Processor 선택 | 생성자 주입 | Manager(Phase 4)가 voucher/point에 맞는 Processor를 주입 |

### 2.4 생성자 파라미터

| 파라미터 | 타입 | 용도 |
|---------|------|------|
| `processor` | `AbstractCampaignPromotionProcessor<*, *>` | 기존 비즈니스 로직 재사용 (`process(json)` 호출) |
| `streamRedisTemplate` | `StringRedisTemplate` | `acknowledge()` 호출용 (XACK) |
| `streamKey` | `String` | ACK 대상 Stream key |
| `consumerGroup` | `String` | ACK 대상 Consumer Group |

---

## 3. Container + Subscription 구성 (테스트용)

Phase 2에서는 `PromotionStreamManager` 없이 테스트 코드에서 직접 Container를 생성하고 Subscription을 등록한다.

### 3.1 Container 생성

Phase 1에서 결정된 설정을 그대로 사용한다.

```kotlin
val options = StreamMessageListenerContainerOptions.builder()
    .pollTimeout(Duration.ZERO)       // Phase 1 결정: non-blocking
    .batchSize(10)                    // XREAD COUNT
    .build()

val container = StreamMessageListenerContainer
    .create(streamRedisConnectionFactory, options)
```

| 설정 | 값 | 근거 |
|------|------|------|
| `pollTimeout` | `Duration.ZERO` | ElastiCache Valkey BLOCK 제약 (Phase 1 결정) |
| `batchSize` | `10` | 한 번에 읽을 메시지 수 |
| `connectionFactory` | `streamRedisConnectionFactory` | Phase 1에서 생성한 Stream 전용 팩토리 |

### 3.2 다중 Subscription 등록

```kotlin
val consumerGroup = "test-consumer-group"
val streamKey = "test:consumer:stream"

// N개 Subscription 등록 (수동 ACK: receive 사용)
val subscriptions = (0 until consumerCount).map { index ->
    container.receive(
        Consumer.from(consumerGroup, "consumer-$index"),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        listener  // PromotionStreamConsumer 인스턴스
    )
}

container.start()
```

### 3.3 `receive` vs `receiveAutoAck` 선택

Phase 2에서는 **`container.receive()`** (수동 ACK)를 사용한다.

```
container.receive(consumer, offset, listener)
→ 내부적으로 XREADGROUP ... 실행
→ 메시지 수신 후 listener.onMessage() 호출
→ ACK는 listener 내에서 수동으로 수행

container.receiveAutoAck(consumer, offset, listener)
→ 내부적으로 XREADGROUP ... 실행 + 즉시 XACK
→ listener.onMessage() 호출 전에 이미 ACK됨
```

이 선택의 상세 근거는 4절에서 설명한다.

### 3.4 테스트용 Consumer Group/Stream 생성

```kotlin
// Consumer Group 생성 (idempotent)
try {
    streamOps.createGroup(streamKey, ReadOffset.from("0"), consumerGroup)
} catch (e: RedisSystemException) {
    if (e.cause?.message?.contains("BUSYGROUP") != true) throw e
}
```

> 기존 `SingleSubscriptionTest`, `MultipleSubscriptionTest` 테스트에서 사용하던 패턴과 동일하다.

---

## 4. 수동 ACK vs receiveAutoAck 결정 근거

### 4.1 비교 테이블

| 항목 | `receiveAutoAck` | `receive` + 수동 ACK |
|------|-----------------|---------------------|
| ACK 시점 | 메시지 수신 즉시 (onMessage 호출 전) | `onMessage()` 내에서 명시적 호출 |
| 처리 실패 시 | **메시지 유실** — 이미 ACK됨 | PEL에 유지 → 재처리 가능 |
| 앱 크래시 시 | **메시지 유실** — 이미 ACK됨 | PEL에 유지 → 다른 인스턴스에서 재처리 |
| PEL 관리 | 불필요 | 필요 (미처리 메시지 모니터링) |
| 구현 복잡도 | 낮음 | 중간 (acknowledge 호출 추가) |
| **적합한 경우** | 메시지 유실 허용 가능 | **메시지 유실 불가** |

### 4.2 결정: 수동 ACK (`receive`) 사용

Voucher/Point 발급은 **금전적 처리**이므로 메시지 유실을 허용할 수 없다.

수동 ACK 방식에서의 동작:
- **처리 성공** → `acknowledge()` → PEL에서 제거
- **처리 실패** (예외) → ACK하지 않음 → PEL에 유지 → 재시작 시 재처리 가능
- **앱 크래시** → ACK되지 않음 → PEL에 유지 → 다른 인스턴스 또는 재시작 후 재처리

### 4.3 PEL 복구 전략 개요

수동 ACK 사용 시, 처리 실패/크래시로 PEL에 남은 메시지를 복구하는 전략이 필요하다.

```
PEL 복구 흐름 (개요):
  1. Consumer 시작 시 ReadOffset.from("0")으로 본인의 PEL 메시지 먼저 처리
  2. PEL이 비면 ReadOffset.lastConsumed()로 신규 메시지 처리 시작
  3. 장시간 미처리(idle) 메시지는 XCLAIM으로 다른 Consumer에게 재할당
```

> **TODO**: PEL 복구 로직 상세 설계는 별도 Phase에서 진행.
> - idle 메시지 XCLAIM 주기 및 임계값
> - 최대 재시도 횟수 초과 시 DLQ(Dead Letter) 처리

---

## 5. 실제 구현 범위

### 5.1 신규 파일

| # | 파일 | 설명 |
|---|------|------|
| 1 | `PromotionStreamConsumer.kt` | `StreamListener` 구현 — `onMessage()` → `processor.process(json)` → 수동 ACK |

### 5.2 변경 파일

없음. Phase 1 인프라를 그대로 사용한다.

### 5.3 이 Phase에서 구현하지 않는 것

| 컴포넌트 | Phase | 이유 |
|---------|:-----:|------|
| `PromotionStreamProducer` | 3 | 테스트에서는 `streamOps.add()`로 직접 발행 |
| `PromotionStreamManager` | 4 | Container 동적 생성/파괴 오케스트레이션 |
| `PromotionConsumerRegistry` | 4 | Container 생명주기 관리 |
| Kafka Listener 변경 | 5 | Feature Toggle, 신규 이벤트 Listener |

---

## 6. 검증 방법 (테스트)

### 6.1 다중 Consumer 수신 테스트 (MultiConsumerDistributionTest)

**테스트 목표**: N개 Subscription이 동일 Consumer Group에서 메시지를 분배 수신하는지 검증한다.

**설정**:
- `streamOps.add()`로 100건 메시지 발행
- 4개 Consumer(Subscription) 등록
- 각 Consumer는 `PromotionStreamConsumer` 인스턴스 (Mock Processor 사용)

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | 총 수신 건수 == 발행 건수 | Mock Processor의 `process()` 호출 횟수 합산 == 100 |
| 2 | 메시지 분배 수신 | 각 Consumer가 1건 이상 수신 (편차 허용) |
| 3 | 메시지 중복 없음 | recordId 기준으로 중복 검사 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `다중 Consumer가 메시지를 분배 수신한다`() {
    // 1. Consumer Group + Stream 생성
    ensureStreamAndGroup(streamKey, consumerGroup)

    // 2. 메시지 100건 발행
    repeat(100) { i ->
        streamOps.add(
            StreamRecords.string(mapOf(
                "key" to "key-$i",
                "message" to """{"promotionId":1,"targetId":$i}""",
                "publishedAt" to Instant.now().toEpochMilli().toString()
            )).withStreamKey(streamKey)
        )
    }

    // 3. Container + 4개 Subscription 생성 (PromotionStreamConsumer 사용)
    val container = createContainer()
    val perConsumerCounts = ConcurrentHashMap<String, AtomicInteger>()
    val allRecordIds = CopyOnWriteArrayList<String>()

    repeat(4) { index ->
        val consumerName = "consumer-$index"
        perConsumerCounts[consumerName] = AtomicInteger(0)

        val listener = StreamListener<String, MapRecord<String, String, String>> { message ->
            perConsumerCounts[consumerName]!!.incrementAndGet()
            allRecordIds.add(message.id.value)
            // 수동 ACK
            streamOps.acknowledge(streamKey, consumerGroup, message.id)
        }

        container.receive(
            Consumer.from(consumerGroup, consumerName),
            StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
            listener
        )
    }

    container.start()
    Thread.sleep(5000)  // 수신 대기

    // 4. 검증
    val totalReceived = perConsumerCounts.values.sumOf { it.get() }
    assertThat(totalReceived).isEqualTo(100)

    // 각 Consumer가 메시지를 분배 수신 (0건 Consumer 없어야 함)
    perConsumerCounts.forEach { (name, count) ->
        assertThat(count.get())
            .withFailMessage("$name 가 메시지를 수신하지 못함")
            .isGreaterThan(0)
    }

    // 중복 없음
    assertThat(allRecordIds).doesNotHaveDuplicates()

    container.stop()
}
```

### 6.2 수동 ACK 검증 테스트 (ManualAckTest)

**테스트 목표**: ACK한 메시지는 PEL에서 제거되고, ACK하지 않은 메시지는 PEL에 유지되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | ACK 전 PEL에 메시지 존재 | `XPENDING` 결과에서 pending 카운트 확인 |
| 2 | ACK 후 PEL에서 제거 | `XPENDING` 결과에서 pending 카운트 감소 확인 |
| 3 | ACK하지 않은 메시지는 PEL에 유지 | `XPENDING` 결과에서 pending 카운트 유지 확인 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `ACK한 메시지는 PEL에서 제거되고, ACK하지 않은 메시지는 PEL에 유지된다`() {
    // 1. 메시지 5건 발행
    val recordIds = (0 until 5).map { i ->
        streamOps.add(
            StreamRecords.string(mapOf(
                "message" to """{"id":$i}"""
            )).withStreamKey(streamKey)
        )!!
    }

    // 2. container.receive() (수동 ACK) 로 수신
    val received = CopyOnWriteArrayList<MapRecord<String, String, String>>()
    val container = createContainer()
    container.receive(
        Consumer.from(consumerGroup, "ack-test-consumer"),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        StreamListener { message -> received.add(message) }
    )
    container.start()
    Thread.sleep(3000)

    assertThat(received).hasSize(5)

    // 3. XPENDING으로 PEL 확인 — 5건 모두 pending
    val pendingBefore = streamOps.pending(streamKey, consumerGroup)
    assertThat(pendingBefore.totalPendingMessages).isEqualTo(5)

    // 4. 3건만 ACK
    received.take(3).forEach { message ->
        streamOps.acknowledge(streamKey, consumerGroup, message.id)
    }

    // 5. XPENDING 재확인 — 2건 pending
    val pendingAfter = streamOps.pending(streamKey, consumerGroup)
    assertThat(pendingAfter.totalPendingMessages).isEqualTo(2)

    container.stop()
}
```

### 6.3 에러 처리 테스트 (ErrorHandlingTest)

#### 6.3.1 process() 예외 시 ACK 안 됨

**테스트 목표**: `processor.process()` 예외 시 ACK이 수행되지 않아 메시지가 PEL에 유지되는지 검증한다.

```kotlin
@Test
fun `process() 예외 시 메시지가 PEL에 유지된다`() {
    // 1. 메시지 1건 발행
    streamOps.add(
        StreamRecords.string(mapOf(
            "message" to """{"id":1}"""
        )).withStreamKey(streamKey)
    )

    // 2. 예외를 발생시키는 Mock Processor 사용
    val failingProcessor = mock<AbstractCampaignPromotionProcessor<*, *>>()
    whenever(failingProcessor.process(any())).thenThrow(RuntimeException("처리 실패"))

    val consumer = PromotionStreamConsumer(
        processor = failingProcessor,
        streamRedisTemplate = streamRedisTemplate,
        streamKey = streamKey,
        consumerGroup = consumerGroup
    )

    // 3. Container + Subscription (수동 ACK)
    val container = createContainer()
    container.receive(
        Consumer.from(consumerGroup, "error-consumer"),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        consumer
    )
    container.start()
    Thread.sleep(3000)

    // 4. PEL에 1건 유지 확인
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(1)

    container.stop()
}
```

#### 6.3.2 "message" 필드 없는 메시지 → ACK 처리

**테스트 목표**: `"message"` 필드가 없는 잘못된 메시지는 ACK되어 PEL에서 제거되는지 검증한다.

```kotlin
@Test
fun `message 필드 없는 잘못된 메시지는 ACK 처리된다`() {
    // 1. "message" 필드 없는 메시지 발행
    streamOps.add(
        StreamRecords.string(mapOf(
            "invalid-key" to "invalid-value"
        )).withStreamKey(streamKey)
    )

    // 2. PromotionStreamConsumer (process()는 호출되지 않아야 함)
    val processor = mock<AbstractCampaignPromotionProcessor<*, *>>()
    val consumer = PromotionStreamConsumer(
        processor = processor,
        streamRedisTemplate = streamRedisTemplate,
        streamKey = streamKey,
        consumerGroup = consumerGroup
    )

    // 3. Container + Subscription
    val container = createContainer()
    container.receive(
        Consumer.from(consumerGroup, "invalid-consumer"),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        consumer
    )
    container.start()
    Thread.sleep(3000)

    // 4. PEL에 0건 (ACK 처리됨)
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(0)

    // 5. processor.process()는 호출되지 않음
    verify(processor, never()).process(any())

    container.stop()
}
```

### 6.4 테스트 인프라

#### 테스트 Config

기존 `StreamMultiplexingTestConfig` 패턴을 따른다. Phase 1에서 구성한 `streamRedisConnectionFactory`를 사용한다.

#### 테스트 공통 setup/cleanup

```kotlin
@BeforeEach
fun setup() {
    // Consumer Group 생성 (idempotent)
    try {
        streamOps.createGroup(streamKey, ReadOffset.from("0"), consumerGroup)
    } catch (e: RedisSystemException) {
        if (e.cause?.message?.contains("BUSYGROUP") != true) throw e
    }
}

@AfterEach
fun cleanup() {
    // Stream 삭제 (Consumer Group도 함께 삭제됨)
    streamRedisTemplate.delete(streamKey)
}
```

#### Container 생성 헬퍼

```kotlin
private fun createContainer(): StreamMessageListenerContainer<String, MapRecord<String, String, String>> {
    val options = StreamMessageListenerContainerOptions.builder()
        .pollTimeout(Duration.ZERO)
        .batchSize(10)
        .build()

    return StreamMessageListenerContainer.create(streamRedisConnectionFactory, options)
}
```

---

## 7. 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md) | Phase 1 인프라 구성 — ConnectionFactory, Container 설정, 프로퍼티 |
| [`redis-stream-development-plan.md`](./redis-stream-development-plan.md) | 전체 개발 계획 (5 Phase) |
| [`redis-stream-multiplexing-test-result.md`](./redis-stream-multiplexing-test-result.md) | 멀티플렉싱 non-blocking polling 테스트 결과 |
