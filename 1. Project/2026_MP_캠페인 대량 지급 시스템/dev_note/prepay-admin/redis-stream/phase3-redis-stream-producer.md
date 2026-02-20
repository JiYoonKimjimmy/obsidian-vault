# Redis Stream Producer 구현

## 목차

1. [개요](#1-개요)
2. [PromotionStreamProducer 설계](#2-promotionstreamproducer-설계)
3. [Stream Key / Consumer Group 네이밍 규칙](#3-stream-key--consumer-group-네이밍-규칙)
4. [실제 구현 범위](#4-실제-구현-범위)
5. [검증 방법 (테스트)](#5-검증-방법-테스트)
6. [근거 문서 링크](#6-근거-문서-링크)

---

## 1. 개요

### 1.1 배경

Phase 1([`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md))에서 Stream 전용 ConnectionFactory, Container 설정, 프로퍼티를 구성했다.
Phase 2([`phase2-redis-stream-consumer.md`](./phase2-redis-stream-consumer.md))에서 `PromotionStreamConsumer`를 구현하고, 다중 Subscription 수신 및 수동 ACK 동작을 검증했다.

Phase 3에서는 이 인프라 위에 **`PromotionStreamProducer` 컴포넌트를 구현**하고, **Producer가 발행한 메시지를 Consumer가 수신·처리·ACK하는 연동 흐름을 검증**한다.

### 1.2 목표

- `PromotionStreamProducer` 구현 — `enqueue(streamKey, key, message)` → `XADD` + `MAXLEN ~` trim
- `ensureStreamAndGroup()` 유틸리티 — Stream + Consumer Group 생성 (BUSYGROUP 예외 처리)
- Producer → Consumer 연동 테스트 — 발행 → 수신 → 처리 → ACK 전체 흐름 검증

### 1.3 Phase 3 범위

| 포함 | 미포함 (이후 Phase) |
|------|-------------------|
| `PromotionStreamProducer` 구현 | 동적 Container 생성/파괴 via Manager — Phase 4 |
| `ensureStreamAndGroup()` 유틸리티 | `PromotionConsumerRegistry` — Phase 4 |
| XADD + MAXLEN ~ approximate trimming | Kafka Listener 연동 — Phase 5 |
| Producer → Consumer 연동 테스트 | |
| XADD 실패 시 예외 전파 테스트 | |

> Phase 2까지 테스트에서 `streamOps.add()`로 직접 메시지를 발행했다면, Phase 3부터는 `PromotionStreamProducer.enqueue()`를 통해 발행한다.

---

## 2. PromotionStreamProducer 설계

### 2.1 클래스 구조

Kafka Listener(Phase 5)가 수신한 메시지를 Redis Stream에 발행하는 컴포넌트.
Phase 3에서는 테스트 코드에서 직접 호출하여 검증한다.

```kotlin
@Component
class PromotionStreamProducer(
    @Qualifier("streamRedisTemplate")
    private val streamRedisTemplate: StringRedisTemplate,
    private val properties: RedisStreamProperties
) {
    private val streamOps: StreamOperations<String, String, String> =
        streamRedisTemplate.opsForStream()

    /**
     * Redis Stream에 메시지를 발행한다 (XADD + MAXLEN ~ trim).
     *
     * @param streamKey Stream 키 (e.g. "promotion:{promotionId}:voucher:stream")
     * @param key Kafka partition key
     * @param message 원본 JSON 메시지
     * @return Record ID (e.g. "1234567890-0")
     */
    fun enqueue(streamKey: String, key: String, message: String): String {
        val record = StreamRecords.string(
            mapOf(
                "key" to key,
                "message" to message,
                "publishedAt" to Instant.now().toEpochMilli().toString()
            )
        ).withStreamKey(streamKey)

        val addOptions = XAddOptions.maxlen(properties.maxLen).approximateTrimming(true)
        val recordId = streamOps.add(record, addOptions)
            ?: throw IllegalStateException("Failed to XADD to stream: $streamKey")

        return recordId.value
    }
}
```

### 2.2 enqueue() 흐름

```
PromotionStreamProducer.enqueue(streamKey, key, message)
        │
        ▼
   StreamRecords.string(
     "key"         → Kafka partition key
     "message"     → 원본 JSON 메시지
     "publishedAt" → 발행 시각 (epoch millis)
   ).withStreamKey(streamKey)
        │
        ▼
   streamOps.add(record, XAddOptions.maxlen(maxLen).approximateTrimming(true))
        │
        ├── 성공 → RecordId 반환 (e.g. "1234567890-0")
        │
        └── null 반환 → IllegalStateException("Failed to XADD to stream: $streamKey")
```

실행되는 Redis 명령:

```
XADD promotion:100:voucher:stream MAXLEN ~ 100000 * key "..." message "..." publishedAt "..."
```

### 2.3 Record 필드 구조

| 필드 | 타입 | 설명 |
|------|------|------|
| `key` | `String` | Kafka partition key (Consumer에서 로깅/추적용) |
| `message` | `String` | 원본 JSON 메시지 (Consumer의 `processor.process(json)` 인자) |
| `publishedAt` | `String` | 발행 시각 (epoch millis, 모니터링/디버깅용) |

### 2.4 MAXLEN ~ approximate trimming

XADD 시 `MAXLEN ~` 옵션을 사용하여 Stream 크기를 자동으로 제한한다.

| 항목 | 설명 |
|------|------|
| `MAXLEN ~` | approximate trim — 정확히 maxLen에서 자르지 않고 약간의 여유를 두어 Redis 성능 영향 최소화 |
| 기본값 | `properties.maxLen = 100_000` |
| 동작 | 메시지 추가 시마다 오래된 entry 자동 제거 → 별도 trim 스케줄러 불필요 |
| 역할 | Consumer 장애 시 백로그 상한을 제한하는 안전장치 (정상 운영 시 실제 백로그는 훨씬 작음) |

### 2.5 XADD 실패 시 예외 전파

`streamOps.add()`가 `null`을 반환하면 `IllegalStateException`을 던진다.

Phase 5(Kafka Listener 연동)에서 이 예외는 다음과 같이 활용된다:
- 예외 발생 → `acknowledge.acknowledge()`가 호출되지 않음 → Kafka가 메시지를 재전달
- 기존 Processor의 idempotency(unique constraint)가 중복 처리를 방지

### 2.6 생성자 파라미터

| 파라미터 | 타입 | 용도 |
|---------|------|------|
| `streamRedisTemplate` | `StringRedisTemplate` | `@Qualifier("streamRedisTemplate")` — Phase 1에서 생성한 Stream 전용 Template |
| `properties` | `RedisStreamProperties` | `maxLen` 등 Stream 공통 프로퍼티 |

---

## 3. Stream Key / Consumer Group 네이밍 규칙

### 3.1 네이밍 패턴

| 항목 | 패턴 | 예시 |
|------|------|------|
| Stream key | `promotion:{promotionId}:{type}:stream` | `promotion:100:voucher:stream` |
| Consumer Group | `promotion-{promotionId}-{type}-group` | `promotion-100-voucher-group` |

- `{promotionId}`: 프로모션 ID (Long)
- `{type}`: `voucher` 또는 `point`

### 3.2 ensureStreamAndGroup()

Stream + Consumer Group을 생성하는 유틸리티. 이미 존재하는 경우 `BUSYGROUP` 예외를 catch하여 무시한다.

```kotlin
fun ensureStreamAndGroup(
    streamOps: StreamOperations<String, String, String>,
    streamKey: String,
    consumerGroup: String
) {
    try {
        streamOps.createGroup(streamKey, ReadOffset.from("0"), consumerGroup)
    } catch (e: RedisSystemException) {
        if (e.cause?.message?.contains("BUSYGROUP") == true) {
            // Consumer Group이 이미 존재 — 정상 케이스
        } else {
            throw e
        }
    }
}
```

`XGROUP CREATE` 명령의 동작:
- Stream이 존재하지 않으면 자동 생성 (MKSTREAM)
- Consumer Group이 이미 존재하면 `BUSYGROUP` 에러 반환 → catch하여 무시

### 3.3 Phase 3에서의 사용 방식

Phase 3에서는 `ensureStreamAndGroup()`을 **테스트 코드에서 직접 호출**한다.
Phase 4에서 `PromotionStreamManager.startConsumers()` 내부로 이동한다.

```kotlin
// Phase 3 테스트 코드에서:
ensureStreamAndGroup(streamOps, streamKey, consumerGroup)

// Phase 4 이후:
// PromotionStreamManager.startConsumers() 내부에서 호출
```

---

## 4. 실제 구현 범위

### 4.1 신규 파일

| # | 파일 | 설명 |
|---|------|------|
| 1 | `PromotionStreamProducer.kt` | Redis Stream에 XADD 발행 — `enqueue(streamKey, key, message)` |

### 4.2 변경 파일

없음. Phase 1 인프라 + Phase 2 Consumer를 그대로 사용한다.

### 4.3 이 Phase에서 구현하지 않는 것

| 컴포넌트 | Phase | 이유 |
|---------|:-----:|------|
| `PromotionStreamManager` | 4 | Container 동적 생성/파괴 오케스트레이션 |
| `PromotionConsumerRegistry` | 4 | Container 생명주기 관리 |
| Kafka Listener 변경 | 5 | Feature Toggle, 신규 이벤트 Listener |

---

## 5. 검증 방법 (테스트)

### 5.1 Producer XADD 테스트

**테스트 목표**: `enqueue()` 호출 시 메시지가 Stream에 정상 발행되고, Record 필드 구조가 올바른지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | Stream에 메시지 발행 | `enqueue()` 호출 후 `XLEN`으로 1건 확인 |
| 2 | Record 필드 구조 | `XRANGE`로 entry 조회 → `key`, `message`, `publishedAt` 필드 존재 확인 |
| 3 | Record 필드 값 | `key` == 전달한 key, `message` == 전달한 JSON, `publishedAt` != null |
| 4 | 반환값 | RecordId 형식 (`"숫자-숫자"`) |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enqueue()로 메시지를 발행하면 Stream에 Record가 추가된다`() {
    // 1. Producer로 메시지 발행
    val streamKey = "promotion:1:voucher:stream"
    val key = "partition-key-1"
    val message = """{"promotionId":1,"targetId":100}"""

    val recordId = producer.enqueue(streamKey, key, message)

    // 2. XLEN으로 1건 확인
    val streamLen = streamOps.size(streamKey)
    assertThat(streamLen).isEqualTo(1)

    // 3. XRANGE로 entry 조회 → 필드 검증
    val entries = streamOps.range(streamKey, Range.unbounded())
    assertThat(entries).hasSize(1)

    val entry = entries!!.first()
    assertThat(entry.id.value).isEqualTo(recordId)
    assertThat(entry.value["key"]).isEqualTo(key)
    assertThat(entry.value["message"]).isEqualTo(message)
    assertThat(entry.value["publishedAt"]).isNotNull()
}
```

### 5.2 MAXLEN trimming 테스트

**테스트 목표**: `maxLen` 초과 발행 시 Stream 크기가 제한되는지 검증한다.

**설정**: `RedisStreamProperties.maxLen = 10` (테스트용 작은 값)

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | maxLen 초과 발행 후 Stream 크기 제한 | 20건 발행 → `XLEN` ≤ maxLen + α (approximate trim이므로 정확히 maxLen이 아닐 수 있음) |
| 2 | 오래된 entry 제거 | 처음 발행한 entry가 XRANGE 결과에 없음 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `MAXLEN trimming으로 Stream 크기가 제한된다`() {
    // maxLen = 10으로 설정된 Producer 사용
    val streamKey = "promotion:1:voucher:stream"

    // 20건 발행
    val recordIds = (0 until 20).map { i ->
        producer.enqueue(streamKey, "key-$i", """{"id":$i}""")
    }

    // Stream 크기 확인 — approximate trim이므로 정확히 10이 아닐 수 있음
    val streamLen = streamOps.size(streamKey)
    assertThat(streamLen).isLessThanOrEqualTo(15)  // maxLen(10) + approximate 여유

    // 처음 발행한 entry가 제거되었는지 확인
    val entries = streamOps.range(streamKey, Range.unbounded())
    val remainingIds = entries!!.map { it.id.value }
    assertThat(remainingIds).doesNotContain(recordIds.first())
}
```

### 5.3 Producer → Consumer 연동 테스트

**테스트 목표**: `PromotionStreamProducer.enqueue()`로 발행한 메시지를 `PromotionStreamConsumer`가 수신하고, `processor.process(json)`을 호출한 후 ACK가 정상적으로 수행되는 전체 흐름을 검증한다.

**설정**:
- `PromotionStreamProducer`로 메시지 발행
- `PromotionStreamConsumer` + Mock Processor로 수신
- Container + Subscription 수동 구성 (Phase 2 패턴)

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | Consumer가 메시지를 수신 | Mock Processor의 `process()` 호출 횟수 == 발행 건수 |
| 2 | 올바른 JSON 전달 | `process()` 호출 시 전달된 인자가 원본 JSON과 일치 |
| 3 | ACK 정상 처리 | `XPENDING` 결과에서 pending 카운트 == 0 |
| 4 | Stream에 메시지 존재 | `XLEN` > 0 (ACK는 PEL에서 제거할 뿐 Stream entry는 남음) |

**테스트 코드 흐름**:

```kotlin
@Test
fun `Producer가 발행한 메시지를 Consumer가 수신하고 처리 후 ACK한다`() {
    val streamKey = "promotion:1:voucher:stream"
    val consumerGroup = "promotion-1-voucher-group"

    // 1. Stream + Consumer Group 생성
    ensureStreamAndGroup(streamOps, streamKey, consumerGroup)

    // 2. Mock Processor 준비
    val processedMessages = CopyOnWriteArrayList<String>()
    val mockProcessor = mock<AbstractCampaignPromotionProcessor<*, *>>()
    whenever(mockProcessor.process(any())).thenAnswer { invocation ->
        processedMessages.add(invocation.getArgument(0))
        null
    }

    // 3. Consumer + Container 구성 (Phase 2 패턴)
    val consumer = PromotionStreamConsumer(
        processor = mockProcessor,
        streamRedisTemplate = streamRedisTemplate,
        streamKey = streamKey,
        consumerGroup = consumerGroup
    )

    val container = createContainer()
    container.receive(
        Consumer.from(consumerGroup, "consumer-0"),
        StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
        consumer
    )
    container.start()

    // 4. Producer로 메시지 발행
    val messages = (0 until 10).map { i ->
        val json = """{"promotionId":1,"targetId":$i}"""
        producer.enqueue(streamKey, "key-$i", json)
        json
    }

    // 5. 수신 대기
    Thread.sleep(5000)

    // 6. 검증: 모든 메시지 수신
    assertThat(processedMessages).hasSize(10)

    // 7. 검증: 올바른 JSON 전달
    assertThat(processedMessages).containsExactlyInAnyOrderElementsOf(messages)

    // 8. 검증: ACK 완료 (PEL 비어있음)
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(0)

    // 9. 검증: Stream entry는 남아있음
    val streamLen = streamOps.size(streamKey)
    assertThat(streamLen).isEqualTo(10)

    container.stop()
}
```

### 5.4 XADD 실패 처리 테스트

**테스트 목표**: `streamOps.add()`가 `null`을 반환할 때 `IllegalStateException`이 발생하는지 검증한다.

> 이 테스트는 `streamOps`를 Mock으로 대체하여 `null` 반환을 시뮬레이션한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | 예외 타입 | `IllegalStateException` |
| 2 | 예외 메시지 | `"Failed to XADD to stream: {streamKey}"` 포함 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `streamOps add()가 null 반환 시 IllegalStateException 발생`() {
    // Mock StreamOperations — add()가 null 반환
    val mockStreamOps = mock<StreamOperations<String, String, String>>()
    whenever(mockStreamOps.add(any<StringRecord>(), any<XAddOptions>())).thenReturn(null)

    // Mock RedisTemplate — opsForStream()이 mockStreamOps 반환
    val mockTemplate = mock<StringRedisTemplate>()
    whenever(mockTemplate.opsForStream<String, String>()).thenReturn(mockStreamOps)

    val producer = PromotionStreamProducer(mockTemplate, properties)

    val streamKey = "promotion:1:voucher:stream"
    assertThatThrownBy {
        producer.enqueue(streamKey, "key-1", """{"id":1}""")
    }
        .isInstanceOf(IllegalStateException::class.java)
        .hasMessageContaining("Failed to XADD to stream: $streamKey")
}
```

### 5.5 테스트 인프라

#### 테스트 Config

기존 `StreamMultiplexingTestConfig` 패턴을 따른다. Phase 1에서 구성한 `streamRedisConnectionFactory`를 사용한다.

#### 테스트 공통 setup/cleanup

```kotlin
@BeforeEach
fun setup() {
    // Stream 정리 (이전 테스트 잔여물 제거)
    streamRedisTemplate.delete(streamKey)
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
        .pollTimeout(Duration.ZERO)    // Phase 1 결정: non-blocking
        .batchSize(10)                 // XREAD COUNT
        .build()

    return StreamMessageListenerContainer.create(streamRedisConnectionFactory, options)
}
```

---

## 6. 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md) | Phase 1 인프라 구성 — `streamRedisConnectionFactory`, `streamRedisTemplate`, `RedisStreamProperties` |
| [`phase2-redis-stream-consumer.md`](./phase2-redis-stream-consumer.md) | Phase 2 Consumer 구현 — `PromotionStreamConsumer`, Container + Subscription 구성 패턴 |
| [`redis-stream-development-plan.md`](./redis-stream-development-plan.md) | 전체 개발 계획 (5 Phase) |
