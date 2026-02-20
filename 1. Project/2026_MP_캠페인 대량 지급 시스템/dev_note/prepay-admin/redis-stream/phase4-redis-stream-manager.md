# Redis Stream Consumer 동적 관리 구현

## 목차

1. [개요](#1-개요)
2. [PromotionStreamManager 설계](#2-promotionstreammanager-설계)
3. [PromotionConsumerRegistry 설계](#3-promotionconsumerregistry-설계)
4. [Consumer 수 동적 계산](#4-consumer-수-동적-계산)
5. [다중 인스턴스 조율](#5-다중-인스턴스-조율)
6. [실제 구현 범위](#6-실제-구현-범위)
7. [검증 방법 (테스트)](#7-검증-방법-테스트)
8. [근거 문서 링크](#8-근거-문서-링크)

---

## 1. 개요

### 1.1 배경

Phase 1([`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md))에서 Stream 전용 ConnectionFactory, Container 설정, 프로퍼티를 구성했다.
Phase 2([`phase2-redis-stream-consumer.md`](./phase2-redis-stream-consumer.md))에서 `PromotionStreamConsumer`를 구현하고, 다중 Subscription 수신 및 수동 ACK 동작을 검증했다.
Phase 3([`phase3-redis-stream-producer.md`](./phase3-redis-stream-producer.md))에서 `PromotionStreamProducer`를 구현하고, Producer→Consumer 연동 흐름을 검증했다.

Phase 4에서는 이 컴포넌트들 위에 **`PromotionStreamManager`(오케스트레이터)와 `PromotionConsumerRegistry`(생명주기 관리)를 구현**하고, Promotion별로 Container를 **동적으로 생성/파괴**하는 전체 흐름을 검증한다.

### 1.2 목표

- `PromotionStreamManager` 구현 — `startConsumers()`, `stopConsumers()`, `enqueue()`, Consumer 수 동적 계산
- `PromotionConsumerRegistry` 구현 — `register()`, `shutdown()`, `shutdownAll()`, `cleanupStream()`
- `PromotionConsumerContext` data class — Container 생명주기 관리 단위
- 다중 인스턴스 조율 — BUSYGROUP 중복 방지, instanceId 기반 Consumer 이름
- 테스트를 통한 전체 흐름 검증

### 1.3 Phase 4 범위

| 포함 | 미포함 (이후 Phase) |
|------|-------------------|
| `PromotionStreamManager` 구현 | Kafka Listener 변경 (Feature Toggle) — Phase 5 |
| `PromotionConsumerRegistry` 구현 | 신규 `prepay-campaign-promotion-started` Kafka Listener — Phase 5 |
| `PromotionConsumerContext` data class | E2E 테스트 (Kafka→Redis Stream→DB) — Phase 5 |
| Consumer 수 동적 계산 (`calculateConsumerCountPerInstance`) | |
| 다중 인스턴스 조율 (BUSYGROUP, instanceId) | |
| Manager/Registry 통합 테스트 | |

---

## 2. PromotionStreamManager 설계

### 2.1 역할

Promotion별로 Container를 동적으로 생성/파괴하는 오케스트레이터.
Consumer 수를 `totalCount` 기반으로 동적으로 결정한다.

### 2.2 클래스 구조

```kotlin
@Service
class PromotionStreamManager(
    @Qualifier("streamRedisConnectionFactory")
    private val streamConnectionFactory: LettuceConnectionFactory,
    @Qualifier("streamRedisTemplate")
    private val streamRedisTemplate: StringRedisTemplate,
    private val consumerRegistry: PromotionConsumerRegistry,
    private val producer: PromotionStreamProducer,
    private val properties: RedisStreamProperties,
    private val voucherProcessor: CampaignPromotionVoucherProcessor,
    private val pointProcessor: CampaignPromotionPointProcessor
) {
    private val log = KotlinLogging.logger {}
    private val lock = ReentrantLock()
    private val instanceId: String = generateInstanceId()
    private val streamOps: StreamOperations<String, String, String> =
        streamRedisTemplate.opsForStream()

    // ... Public API + Private 메서드
}
```

### 2.3 생성자 파라미터

| 파라미터 | 타입 | 용도 |
|---------|------|------|
| `streamConnectionFactory` | `LettuceConnectionFactory` | `@Qualifier("streamRedisConnectionFactory")` — Container 생성 시 공유 ConnectionFactory |
| `streamRedisTemplate` | `StringRedisTemplate` | `@Qualifier("streamRedisTemplate")` — `ensureStreamAndGroup()`, Consumer ACK용 |
| `consumerRegistry` | `PromotionConsumerRegistry` | Container 컨텍스트 등록/조회/종료 |
| `producer` | `PromotionStreamProducer` | `enqueue()` 위임 |
| `properties` | `RedisStreamProperties` | `batchSize`, `maxLen`, `maxConsumerPerInstance` 등 |
| `voucherProcessor` | `CampaignPromotionVoucherProcessor` | Voucher 타입 Consumer에 주입 |
| `pointProcessor` | `CampaignPromotionPointProcessor` | Point 타입 Consumer에 주입 |

> **Phase 1 결정 반영**: architecture.md에서는 `streamRedisConnectionFactory`와 별도로 `createConnectionFactory(consumerCount)`로 Promotion별 전용 Pool을 생성했지만, Phase 1 결정에 따라 **공유 `streamConnectionFactory`를 직접 사용**한다. `createConnectionFactory()` 메서드는 삭제된다.

### 2.4 startConsumers(promotionId, totalCount, type)

Promotion 전용 Consumer(Container + Subscription)를 시작한다.

```kotlin
fun startConsumers(promotionId: Long, totalCount: Int, type: String) {
    lock.lock()
    try {
        if (consumerRegistry.isActive(promotionId)) {
            log.info { "[Manager] Already active: promotion=$promotionId" }
            return
        }

        val streamKey = getStreamKey(promotionId, type)
        val consumerGroup = getConsumerGroup(promotionId, type)
        val consumerCount = calculateConsumerCountPerInstance(totalCount, properties.maxConsumerPerInstance)
        val processor = when (type) {
            "voucher" -> voucherProcessor
            "point" -> pointProcessor
            else -> throw IllegalArgumentException("Unknown type: $type")
        }

        // 1. Stream + Consumer Group 생성
        ensureStreamAndGroup(streamKey, consumerGroup)

        // 2. Executor 생성
        val executor = createExecutor(consumerCount, promotionId)

        // 3. Container 생성 (공유 ConnectionFactory 사용)
        val container = createContainer(executor)

        // 4. Subscription 등록 (수동 ACK)
        val listener = PromotionStreamConsumer(processor, streamRedisTemplate, streamKey, consumerGroup)
        val consumerNames = (0 until consumerCount).map { index ->
            "$instanceId-consumer-$index"
        }
        val subscriptions = consumerNames.map { consumerName ->
            container.receive(
                Consumer.from(consumerGroup, consumerName),
                StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
                listener
            )
        }

        // 5. Container 시작
        container.start()

        // 6. Registry 등록
        consumerRegistry.register(
            promotionId,
            PromotionConsumerContext(
                container = container,
                subscriptions = subscriptions,
                executor = executor,
                streamRedisTemplate = streamRedisTemplate,
                streamKey = streamKey,
                consumerGroup = consumerGroup,
                consumerNames = consumerNames,
                startedAt = Instant.now()
            )
        )

        log.info {
            "[Manager] Started consumers for promotion=$promotionId" +
            " - type=$type, consumerCount=$consumerCount, streamKey=$streamKey"
        }
    } finally {
        lock.unlock()
    }
}
```

**흐름도**:

```
startConsumers(promotionId, totalCount, type)
    │
    ├── 1. isActive(promotionId) → true → return (중복 방지)
    │
    ├── 2. ensureStreamAndGroup(streamKey, consumerGroup)
    │       └── XGROUP CREATE + BUSYGROUP 예외 처리
    │
    ├── 3. createExecutor(consumerCount, promotionId)
    │       └── ThreadPoolTaskExecutor (corePoolSize = consumerCount)
    │
    ├── 4. createContainer(executor)
    │       └── StreamMessageListenerContainer.create(streamConnectionFactory, options)
    │           └── pollTimeout(Duration.ZERO), batchSize
    │
    ├── 5. N개 Subscription 등록 — container.receive()
    │       └── Consumer.from(consumerGroup, "{instanceId}-consumer-{index}")
    │
    ├── 6. container.start()
    │
    └── 7. consumerRegistry.register(promotionId, context)
```

### 2.5 stopConsumers(promotionId)

Promotion의 모든 Consumer를 중지한다. Registry의 `shutdown()`에 위임한다.

```kotlin
fun stopConsumers(promotionId: Long) {
    lock.lock()
    try {
        consumerRegistry.shutdown(promotionId)
        log.info { "[Manager] Stopped consumers for promotion=$promotionId" }
    } finally {
        lock.unlock()
    }
}
```

### 2.6 enqueue(promotionId, type, key, message)

Redis Stream에 메시지를 발행한다. Producer의 `enqueue()`에 위임한다.

```kotlin
fun enqueue(promotionId: Long, type: String, key: String, message: String): String {
    val streamKey = getStreamKey(promotionId, type)
    return producer.enqueue(streamKey, key, message)
}
```

### 2.7 createExecutor()

Promotion별 전용 `ThreadPoolTaskExecutor`를 생성한다.

```kotlin
private fun createExecutor(consumerCount: Int, promotionId: Long): ThreadPoolTaskExecutor {
    return ThreadPoolTaskExecutor().apply {
        corePoolSize = consumerCount
        maxPoolSize = consumerCount + 2
        setThreadNamePrefix("stream-promo-$promotionId-")
        initialize()
    }
}
```

| 설정 | 값 | 근거 |
|------|------|------|
| `corePoolSize` | `consumerCount` | Subscription당 1개 스레드 필요 |
| `maxPoolSize` | `consumerCount + 2` | 여유분 |
| `threadNamePrefix` | `stream-promo-{promotionId}-` | 로그에서 어떤 Promotion의 스레드인지 식별 |

### 2.8 createContainer()

공유 `streamConnectionFactory`를 사용하여 Container를 생성한다.

```kotlin
private fun createContainer(
    executor: ThreadPoolTaskExecutor
): StreamMessageListenerContainer<String, MapRecord<String, String, String>> {

    val options = StreamMessageListenerContainerOptions.builder()
        .pollTimeout(Duration.ZERO)             // non-blocking XREADGROUP
        .batchSize(properties.batchSize)         // XREAD COUNT
        .executor(executor)
        .errorHandler { e -> log.error("Stream polling error", e) }
        .build()

    return StreamMessageListenerContainer.create(streamConnectionFactory, options)
}
```

> **Phase 1 결정 반영**:
> - `pollTimeout(Duration.ZERO)` — non-blocking (ElastiCache Valkey BLOCK 제약)
> - `streamConnectionFactory` — 공유 ConnectionFactory 사용 (Promotion별 전용 Pool 생성 삭제)
> - architecture.md의 `createContainer(connectionFactory, executor)` 시그니처에서 `connectionFactory` 파라미터가 제거됨

### 2.9 ensureStreamAndGroup()

Stream + Consumer Group을 생성한다. 이미 존재하는 경우 `BUSYGROUP` 예외를 catch하여 무시한다.

```kotlin
private fun ensureStreamAndGroup(streamKey: String, consumerGroup: String) {
    try {
        streamOps.createGroup(streamKey, ReadOffset.from("0"), consumerGroup)
        log.info { "[Manager] Created consumer group: $consumerGroup for stream: $streamKey" }
    } catch (e: RedisSystemException) {
        if (e.cause?.message?.contains("BUSYGROUP") == true) {
            log.info { "[Manager] Consumer group already exists: $consumerGroup" }
        } else {
            throw e
        }
    }
}
```

> Phase 3에서는 `ensureStreamAndGroup()`을 테스트 코드에서 직접 호출했다. Phase 4부터는 `PromotionStreamManager.startConsumers()` 내부로 이동한다.

### 2.10 유틸리티 메서드

```kotlin
private fun getStreamKey(promotionId: Long, type: String): String =
    "promotion:$promotionId:$type:stream"

private fun getConsumerGroup(promotionId: Long, type: String): String =
    "promotion-$promotionId-$type-group"

private fun generateInstanceId(): String =
    "${InetAddress.getLocalHost().hostName}-${ProcessHandle.current().pid()}"
```

| 메서드 | 반환 예시 |
|--------|---------|
| `getStreamKey(100, "voucher")` | `promotion:100:voucher:stream` |
| `getConsumerGroup(100, "voucher")` | `promotion-100-voucher-group` |
| `generateInstanceId()` | `ip-10-0-1-42-12345` |

### 2.11 동시성 제어

`ReentrantLock`으로 `startConsumers()`와 `stopConsumers()`의 동시성을 제어한다.

```kotlin
private val lock = ReentrantLock()
```

| 시나리오 | 동작 |
|---------|------|
| 동일 promotionId에 대해 `startConsumers()` 동시 호출 | `lock`으로 직렬화 + `isActive()` 체크로 중복 방지 |
| `startConsumers()` 중 `stopConsumers()` 호출 | `lock`으로 직렬화 — start 완료 후 stop 실행 |
| 서로 다른 promotionId에 대해 동시 호출 | `lock`으로 직렬화 — 단일 인스턴스 내에서 순차 실행 |

> 단일 인스턴스 내에서만 동시성을 제어한다. 다중 인스턴스 간 조율은 5절에서 설명한다.

---

## 3. PromotionConsumerRegistry 설계

### 3.1 역할

활성 Promotion별 Container 컨텍스트를 관리하는 레지스트리.
Container 생명주기(등록, 종료, 전체 종료)와 Stream 정리를 담당한다.

### 3.2 PromotionConsumerContext

Container 생명주기 관리 단위. data class로 정의한다.

```kotlin
data class PromotionConsumerContext(
    val container: StreamMessageListenerContainer<String, MapRecord<String, String, String>>,
    val subscriptions: List<Subscription>,
    val executor: ThreadPoolTaskExecutor,
    val streamRedisTemplate: StringRedisTemplate,   // Stream 정리용
    val streamKey: String,                          // Stream 정리용
    val consumerGroup: String,                      // Stream 정리용
    val consumerNames: List<String>,                // 이 인스턴스가 등록한 Consumer 이름 목록
    val startedAt: Instant
)
```

| 필드 | 타입 | 용도 |
|------|------|------|
| `container` | `StreamMessageListenerContainer<String, MapRecord<String, String, String>>` | Container 중지용 |
| `subscriptions` | `List<Subscription>` | Subscription 취소용 |
| `executor` | `ThreadPoolTaskExecutor` | Executor 종료용 |
| `streamRedisTemplate` | `StringRedisTemplate` | `cleanupStream()` — XINFO, XGROUP DELCONSUMER, DEL 등 |
| `streamKey` | `String` | Stream 정리 대상 키 |
| `consumerGroup` | `String` | Consumer Group 정리 대상 |
| `consumerNames` | `List<String>` | 이 인스턴스가 등록한 Consumer 이름 목록 (다중 인스턴스 구분용) |
| `startedAt` | `Instant` | 시작 시각 (로깅/모니터링) |

> **Phase 1 결정 반영**: architecture.md의 `PromotionConsumerContext`에는 `connectionFactory: LettuceConnectionFactory` 필드가 있었으나, 공유 ConnectionFactory를 사용하므로 **해당 필드를 제거**했다. shutdown 시 `connectionFactory.destroy()` 호출도 삭제된다.

### 3.3 클래스 구조

```kotlin
@Component
class PromotionConsumerRegistry {

    private val log = KotlinLogging.logger {}
    private val activePromotions = ConcurrentHashMap<Long, PromotionConsumerContext>()

    // ... 메서드
}
```

### 3.4 register(promotionId, context)

`ConcurrentHashMap`에 컨텍스트를 저장한다.

```kotlin
fun register(promotionId: Long, context: PromotionConsumerContext) {
    activePromotions[promotionId] = context
    log.info {
        "[Registry] Registered promotion=$promotionId" +
        " - consumers=${context.subscriptions.size}, startedAt=${context.startedAt}"
    }
}
```

### 3.5 isActive(promotionId)

해당 Promotion의 Consumer가 활성 상태인지 확인한다.

```kotlin
fun isActive(promotionId: Long): Boolean = activePromotions.containsKey(promotionId)
```

### 3.6 shutdown(promotionId)

Promotion의 모든 Consumer를 종료하고 Stream을 정리한다.

```kotlin
fun shutdown(promotionId: Long) {
    val context = activePromotions.remove(promotionId) ?: run {
        log.warn { "[Registry] Promotion not found: $promotionId" }
        return
    }

    // 순서 중요: Subscription 취소 → Container 중지 → Stream 정리 → Executor 종료
    // 1. polling 중지
    context.subscriptions.forEach { it.cancel() }
    // 2. 컨테이너 중지 (내부 task 정리)
    context.container.stop()
    // 3. Stream key + Consumer Group 정리
    cleanupStream(context)
    // 4. executor 종료
    context.executor.shutdown()

    log.info { "[Registry] Shutdown promotion=$promotionId" }
}
```

**종료 순서가 중요한 이유**:

| 순서 | 동작 | 순서를 어기면 |
|:---:|------|------------|
| 1 | `subscription.cancel()` — polling 중지 | Container가 아직 poll 중이면 취소가 안전하게 진행되지 않을 수 있음 |
| 2 | `container.stop()` — 컨테이너 중지 | `StreamPollTask`가 XREAD 중 connection 에러 발생 가능 |
| 3 | `cleanupStream()` — Stream/Group 정리 | Container가 아직 활성이면 정리 도중 Consumer가 재등록될 수 있음 |
| 4 | `executor.shutdown()` — 스레드풀 종료 | 진행 중인 작업이 완료된 후 종료 |

> **Phase 1 결정 반영**: architecture.md에서는 `context.connectionFactory.destroy()`가 3번과 4번 사이에 있었으나, 공유 ConnectionFactory를 사용하므로 **`destroy()` 호출을 삭제**했다. 공유 팩토리를 파괴하면 다른 Promotion의 Container까지 영향을 받는다.

### 3.7 cleanupStream(context)

다중 인스턴스 환경에서 안전하게 Stream과 Consumer Group을 정리한다.

```kotlin
private fun cleanupStream(context: PromotionConsumerContext) {
    try {
        val streamOps = context.streamRedisTemplate.opsForStream()
        val streamKey = context.streamKey
        val consumerGroup = context.consumerGroup

        // Consumer Group 내 활성 Consumer 수 확인
        val consumers = streamOps.consumers(streamKey, consumerGroup)
        val hasOtherConsumers = consumers.any { consumer ->
            // 이 인스턴스의 Consumer가 아닌 것이 있는지 확인
            context.consumerNames.none { it == consumer.consumerName() }
        }

        if (hasOtherConsumers) {
            // 다른 인스턴스의 Consumer가 남아있으면 이 인스턴스의 Consumer만 삭제
            context.consumerNames.forEach { name ->
                streamOps.deleteConsumer(streamKey, Consumer.from(consumerGroup, name))
            }
            log.info { "[Registry] Deleted local consumers only - other instances still active" }
        } else {
            // 마지막 인스턴스 → Consumer Group + Stream key 모두 삭제
            streamOps.destroyGroup(streamKey, consumerGroup)
            context.streamRedisTemplate.delete(streamKey)
            log.info { "[Registry] Deleted stream=$streamKey, group=$consumerGroup" }
        }
    } catch (e: Exception) {
        log.warn(e) { "[Registry] Stream cleanup failed (non-fatal)" }
    }
}
```

**분기 로직**:

```
cleanupStream(context)
    │
    ├── XINFO CONSUMERS {streamKey} {consumerGroup}
    │       └── 현재 Consumer Group의 모든 Consumer 목록 조회
    │
    ├── 다른 인스턴스의 Consumer가 있는가?
    │       │
    │       ├── YES → 로컬 Consumer만 삭제 (XGROUP DELCONSUMER)
    │       │         다른 인스턴스가 아직 소비 중이므로 Stream과 Group은 유지
    │       │
    │       └── NO  → 마지막 인스턴스 → 전체 삭제
    │                 ├── XGROUP DESTROY (Consumer Group 삭제)
    │                 └── DEL (Stream key 삭제)
    │
    └── 예외 발생 시 warn 로그 (non-fatal)
        Stream 정리 실패가 비즈니스 로직에 영향을 주면 안 됨
```

### 3.8 shutdownAll() — @PreDestroy

앱 종료 시 모든 Promotion의 Consumer를 순차적으로 종료한다.

```kotlin
@PreDestroy
fun shutdownAll() {
    log.info { "[Registry] Shutting down all promotions: ${activePromotions.keys}" }
    activePromotions.keys.toList().forEach { shutdown(it) }
}
```

| 항목 | 설명 |
|------|------|
| 트리거 | `@PreDestroy` — Spring Context 종료 시 자동 호출 |
| 순서 | `activePromotions.keys.toList()` 순서로 순차 종료 |
| `.toList()` | `ConcurrentHashMap` 순회 중 `shutdown()`이 `remove()`를 호출하므로 snapshot 필요 |

---

## 4. Consumer 수 동적 계산

### 4.1 calculateConsumerCountPerInstance()

`companion object`에 정의된 순수 함수. `totalCount`(프로모션 대상자 수)를 기준으로 인스턴스당 Consumer 수를 결정한다.

```kotlin
companion object {
    fun calculateConsumerCountPerInstance(totalCount: Int, maxConsumerPerInstance: Int): Int {
        val calculated = when {
            totalCount <= 1_000 -> 1
            totalCount <= 10_000 -> 2
            totalCount <= 100_000 -> 4
            totalCount <= 500_000 -> 8
            totalCount <= 1_000_000 -> 16
            else -> 32
        }
        return minOf(calculated, maxConsumerPerInstance)
    }
}
```

### 4.2 totalCount 구간별 Consumer 수

| totalCount 구간 | 인스턴스당 Consumer 수 |
|:---:|:---:|
| ~ 1,000 | 1 |
| 1,001 ~ 10,000 | 2 |
| 10,001 ~ 100,000 | 4 |
| 100,001 ~ 500,000 | 8 |
| 500,001 ~ 1,000,000 | 16 |
| 1,000,001 ~ | 32 |

### 4.3 4개 인스턴스 × N개 Consumer = 처리량 계산

전제: 메시지 1건 처리 ~200ms (Money API 호출이 지배적)

| totalCount | Consumer/인스턴스 | 총 Consumer (4인스턴스) | 초당 처리량 | 예상 처리 시간 |
|:---:|:---:|:---:|:---:|:---:|
| 1,000 | 1 | 4 | 20건/s | ~50초 |
| 10,000 | 2 | 8 | 40건/s | ~4.2분 |
| 100,000 | 4 | 16 | 80건/s | ~20.8분 |
| 500,000 | 8 | 32 | 160건/s | ~52.1분 |
| 1,000,000 | 16 | 64 | 320건/s | ~52.1분 |
| 1,000,001+ | 32 | 128 | 640건/s | ~26분 |

### 4.4 maxConsumerPerInstance 제약

`minOf(calculated, maxConsumerPerInstance)`로 상한을 제한한다.

```
예: maxConsumerPerInstance = 8, totalCount = 2,000,000
  calculated = 32
  실제 반환 = minOf(32, 8) = 8
```

환경별 `maxConsumerPerInstance` 설정:

| 환경 | max-consumer-per-instance | 근거 |
|------|:---:|------|
| local | 4 | 개발 환경 리소스 절약 |
| dev | 8 | 테스트용 적정 규모 |
| staging | 16 | 운영 환경 절반 수준으로 검증 |
| production | 32 | 목표 처리량 달성 기준 |

---

## 5. 다중 인스턴스 조율

### 5.1 instanceId 생성

각 인스턴스는 고유한 `instanceId`를 생성하여 Consumer 이름 충돌을 방지한다.

```kotlin
private val instanceId: String = generateInstanceId()

private fun generateInstanceId(): String =
    "${InetAddress.getLocalHost().hostName}-${ProcessHandle.current().pid()}"
```

예: `ip-10-0-1-42-12345`, `ip-10-0-1-43-67890`

### 5.2 Consumer 이름 패턴

```
{instanceId}-consumer-{index}
```

예: `ip-10-0-1-42-12345-consumer-0`, `ip-10-0-1-42-12345-consumer-1`, ...

동일 Consumer Group 내에서 인스턴스별 Consumer 이름이 고유하므로 충돌이 발생하지 않는다.

### 5.3 다중 인스턴스 startConsumers 호출 시나리오

4개 인스턴스가 동일한 Kafka 이벤트(`prepay-campaign-promotion-started`)를 수신하면,
각 인스턴스가 독립적으로 `startConsumers()`를 호출한다.

```
Instance A: startConsumers(promotionId=100, totalCount=100000, "voucher")
Instance B: startConsumers(promotionId=100, totalCount=100000, "voucher")
Instance C: startConsumers(promotionId=100, totalCount=100000, "voucher")
Instance D: startConsumers(promotionId=100, totalCount=100000, "voucher")

→ 동일 Consumer Group에 4 × 4 = 16개 Consumer 등록
→ Redis가 Consumer Group 내에서 메시지를 자동 분배 (의도된 동작)
```

### 5.4 BUSYGROUP 중복 방지

N개 인스턴스 모두 `XGROUP CREATE`를 시도한다. 1개만 성공하고, 나머지는 `BUSYGROUP` 에러를 catch하여 무시한다.
별도의 분산락이 필요하지 않다.

```kotlin
// ensureStreamAndGroup 내부
catch (e: RedisSystemException) {
    if (e.cause?.message?.contains("BUSYGROUP") == true) {
        log.info { "[Manager] Consumer group already exists: $consumerGroup" }
    } else {
        throw e
    }
}
```

| 시점 | Instance A | Instance B | Instance C | Instance D |
|------|:---:|:---:|:---:|:---:|
| XGROUP CREATE | 성공 | BUSYGROUP (catch) | BUSYGROUP (catch) | BUSYGROUP (catch) |
| Subscription 등록 | 4개 | 4개 | 4개 | 4개 |
| 총 Consumer | 16개 (Consumer Group 내 자동 분배) |

### 5.5 cleanupStream: 다중 인스턴스 안전한 정리

`stopConsumers()` 호출 시 `cleanupStream()`이 다른 인스턴스의 Consumer 활성 여부를 확인한다.

```
Instance A: stopConsumers(promotionId=100)
    └── cleanupStream()
        ├── XINFO CONSUMERS → [A-consumer-0, A-consumer-1, B-consumer-0, B-consumer-1, ...]
        ├── 다른 인스턴스 Consumer 존재? → YES
        └── A-consumer-0, A-consumer-1만 XGROUP DELCONSUMER

Instance D: stopConsumers(promotionId=100)  ← 마지막 인스턴스
    └── cleanupStream()
        ├── XINFO CONSUMERS → [D-consumer-0, D-consumer-1]  (나머지 이미 삭제됨)
        ├── 다른 인스턴스 Consumer 존재? → NO
        └── XGROUP DESTROY + DEL stream
```

---

## 6. 실제 구현 범위

### 6.1 신규 파일

| # | 파일 | 설명 |
|---|------|------|
| 1 | `PromotionStreamManager.kt` | 오케스트레이터 — `startConsumers()`, `stopConsumers()`, `enqueue()`, Consumer 수 계산 |
| 2 | `PromotionConsumerRegistry.kt` | Container 컨텍스트 관리 — `register()`, `shutdown()`, `shutdownAll()`, `cleanupStream()` |

> `PromotionConsumerContext`는 `PromotionConsumerRegistry` 내부에 data class로 정의한다.

### 6.2 변경 파일

없음. Phase 1~3 코드를 그대로 활용한다.

- `RedisStreamConfig.kt` — Phase 1에서 생성한 `streamRedisConnectionFactory`, `streamRedisTemplate` 사용
- `RedisStreamProperties.kt` — Phase 1에서 생성한 프로퍼티 사용
- `PromotionStreamConsumer.kt` — Phase 2에서 구현한 Consumer 사용
- `PromotionStreamProducer.kt` — Phase 3에서 구현한 Producer 사용

### 6.3 이 Phase에서 구현하지 않는 것

| 컴포넌트 | Phase | 이유 |
|---------|:-----:|------|
| Kafka Listener 변경 (Feature Toggle) | 5 | `CampaignVoucherPromotionListener`, `CampaignPointPromotionListener` 수정 |
| 신규 `prepay-campaign-promotion-started` Listener | 5 | `startConsumers()` 트리거 — Kafka 이벤트 수신 |
| E2E 테스트 | 5 | Kafka → Redis Stream → DB 전체 흐름 |

---

## 7. 검증 방법 (테스트)

### 7.1 calculateConsumerCountPerInstance 테스트

**테스트 목표**: `totalCount` 구간별로 올바른 Consumer 수를 반환하는지 검증한다.

**검증 항목**:

| # | 검증 | 입력 | 기대값 |
|---|------|------|-------|
| 1 | 경계값 하한 | `totalCount=0` | 1 |
| 2 | 경계값 상한 | `totalCount=1000` | 1 |
| 3 | 구간 이동 | `totalCount=1001` | 2 |
| 4 | 구간 이동 | `totalCount=10001` | 4 |
| 5 | 구간 이동 | `totalCount=100001` | 8 |
| 6 | 구간 이동 | `totalCount=500001` | 16 |
| 7 | 구간 이동 | `totalCount=1000001` | 32 |
| 8 | maxConsumerPerInstance 제약 | `totalCount=1000001, max=8` | 8 |
| 9 | maxConsumerPerInstance 제약 | `totalCount=100001, max=4` | 4 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `totalCount 구간별 Consumer 수를 올바르게 계산한다`() {
    assertThat(calculateConsumerCountPerInstance(0, 32)).isEqualTo(1)
    assertThat(calculateConsumerCountPerInstance(1000, 32)).isEqualTo(1)
    assertThat(calculateConsumerCountPerInstance(1001, 32)).isEqualTo(2)
    assertThat(calculateConsumerCountPerInstance(10001, 32)).isEqualTo(4)
    assertThat(calculateConsumerCountPerInstance(100001, 32)).isEqualTo(8)
    assertThat(calculateConsumerCountPerInstance(500001, 32)).isEqualTo(16)
    assertThat(calculateConsumerCountPerInstance(1000001, 32)).isEqualTo(32)
}

@Test
fun `maxConsumerPerInstance 제약이 적용된다`() {
    assertThat(calculateConsumerCountPerInstance(1000001, 8)).isEqualTo(8)
    assertThat(calculateConsumerCountPerInstance(100001, 4)).isEqualTo(4)
}
```

> 이 테스트는 `companion object` 함수 호출만으로 검증하므로 Redis 연결이 필요 없다 (단위 테스트).

### 7.2 startConsumers 테스트

**테스트 목표**: `startConsumers()` 호출 시 Container가 생성되고, Subscription이 등록되고, Registry에 등록되며, 메시지 수신이 정상 동작하는지 검증한다.

**설정**:
- `PromotionStreamManager` 생성 (Mock Processor 사용)
- `startConsumers(promotionId=1, totalCount=1000, type="voucher")` 호출
- 메시지 발행 → 수신 확인

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | Registry에 등록됨 | `consumerRegistry.isActive(1)` == `true` |
| 2 | Consumer Group 생성됨 | `XINFO GROUPS` 결과에 group 존재 |
| 3 | 메시지 수신 동작 | 발행 후 Mock Processor `process()` 호출 확인 |
| 4 | ACK 정상 처리 | `XPENDING` pending count == 0 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `startConsumers 호출 시 Container가 생성되고 메시지를 수신한다`() {
    val promotionId = 1L
    val totalCount = 1000
    val type = "voucher"
    val streamKey = "promotion:$promotionId:$type:stream"
    val consumerGroup = "promotion-$promotionId-$type-group"

    // 1. startConsumers 호출
    manager.startConsumers(promotionId, totalCount, type)

    // 2. Registry에 등록 확인
    assertThat(consumerRegistry.isActive(promotionId)).isTrue()

    // 3. 메시지 10건 발행
    repeat(10) { i ->
        manager.enqueue(promotionId, type, "key-$i", """{"promotionId":$promotionId,"targetId":$i}""")
    }

    // 4. 수신 대기
    Thread.sleep(5000)

    // 5. Mock Processor 호출 확인
    verify(mockProcessor, times(10)).process(any())

    // 6. ACK 완료 확인
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(0)

    // cleanup
    manager.stopConsumers(promotionId)
}
```

### 7.3 stopConsumers 테스트

**테스트 목표**: `stopConsumers()` 호출 시 Subscription이 취소되고, Container가 중지되고, Stream이 정리되고, Registry에서 제거되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | Registry에서 제거됨 | `consumerRegistry.isActive(1)` == `false` |
| 2 | Stream 정리됨 | `streamRedisTemplate.hasKey(streamKey)` == `false` (마지막 인스턴스인 경우) |
| 3 | 메시지 수신 중지 | stopConsumers 후 발행된 메시지는 수신되지 않음 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `stopConsumers 호출 시 Container가 중지되고 Stream이 정리된다`() {
    val promotionId = 1L
    val type = "voucher"
    val streamKey = "promotion:$promotionId:$type:stream"

    // 1. startConsumers → stopConsumers
    manager.startConsumers(promotionId, 1000, type)
    assertThat(consumerRegistry.isActive(promotionId)).isTrue()

    manager.stopConsumers(promotionId)

    // 2. Registry에서 제거 확인
    assertThat(consumerRegistry.isActive(promotionId)).isFalse()

    // 3. Stream 정리 확인 (마지막 인스턴스)
    assertThat(streamRedisTemplate.hasKey(streamKey)).isFalse()
}
```

### 7.4 이미 활성인 Promotion 중복 startConsumers 테스트

**테스트 목표**: 이미 활성 상태인 promotionId에 대해 `startConsumers()`를 다시 호출하면 무시되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | 두 번째 호출이 무시됨 | Consumer 수가 첫 번째 호출 이후와 동일 |
| 2 | 에러 없이 반환 | 예외 발생하지 않음 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `이미 활성인 Promotion에 대해 중복 startConsumers는 무시된다`() {
    val promotionId = 1L

    // 1. 첫 번째 호출 — 정상 시작
    manager.startConsumers(promotionId, 1000, "voucher")
    assertThat(consumerRegistry.isActive(promotionId)).isTrue()

    // 2. 두 번째 호출 — 무시
    assertDoesNotThrow {
        manager.startConsumers(promotionId, 1000, "voucher")
    }

    // 3. 여전히 활성 상태
    assertThat(consumerRegistry.isActive(promotionId)).isTrue()

    // cleanup
    manager.stopConsumers(promotionId)
}
```

### 7.5 cleanupStream 다중 인스턴스 시뮬레이션 테스트

**테스트 목표**: 다른 인스턴스의 Consumer가 활성일 때 로컬 Consumer만 삭제되고, 마지막 인스턴스일 때 전체 삭제되는지 검증한다.

**설정**: 단일 테스트에서 다중 인스턴스를 시뮬레이션한다.
- Manager A: Consumer 등록 (`instanceA-consumer-0`, `instanceA-consumer-1`)
- Manager B: Consumer 등록 (`instanceB-consumer-0`, `instanceB-consumer-1`)
- 동일 Consumer Group에 4개 Consumer가 등록됨

> `PromotionStreamManager`의 `instanceId`는 `generateInstanceId()`로 자동 생성되므로, 테스트에서는 Registry와 Container를 직접 구성하여 시뮬레이션한다.

**검증 항목**:

| # | 시나리오 | 검증 | 방법 |
|---|---------|------|------|
| 1 | A shutdown 시 (B 활성) | 로컬 Consumer만 삭제 | `XINFO CONSUMERS`에서 A Consumer 없음, B Consumer 존재 |
| 2 | B shutdown 시 (마지막) | 전체 삭제 | `streamRedisTemplate.hasKey(streamKey)` == `false` |

**테스트 코드 흐름**:

```kotlin
@Test
fun `다른 인스턴스 Consumer가 활성이면 로컬 Consumer만 삭제한다`() {
    val streamKey = "promotion:1:voucher:stream"
    val consumerGroup = "promotion-1-voucher-group"

    // 1. Stream + Consumer Group 생성
    ensureStreamAndGroup(streamKey, consumerGroup)

    // 2. 인스턴스 A의 Container + Subscription
    val containerA = createContainer()
    val consumerNamesA = listOf("instanceA-consumer-0", "instanceA-consumer-1")
    val subscriptionsA = consumerNamesA.map { name ->
        containerA.receive(
            Consumer.from(consumerGroup, name),
            StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
            noopListener
        )
    }
    containerA.start()

    // 3. 인스턴스 B의 Container + Subscription
    val containerB = createContainer()
    val consumerNamesB = listOf("instanceB-consumer-0", "instanceB-consumer-1")
    val subscriptionsB = consumerNamesB.map { name ->
        containerB.receive(
            Consumer.from(consumerGroup, name),
            StreamOffset.create(streamKey, ReadOffset.lastConsumed()),
            noopListener
        )
    }
    containerB.start()

    // 메시지 발행하여 Consumer가 Redis에 등록되도록 함
    streamOps.add(StreamRecords.string(mapOf("message" to "test")).withStreamKey(streamKey))
    Thread.sleep(3000)

    // 4. A shutdown — 로컬 Consumer만 삭제
    val contextA = PromotionConsumerContext(
        container = containerA,
        subscriptions = subscriptionsA,
        executor = createTestExecutor(),
        streamRedisTemplate = streamRedisTemplate,
        streamKey = streamKey,
        consumerGroup = consumerGroup,
        consumerNames = consumerNamesA,
        startedAt = Instant.now()
    )
    consumerRegistry.register(1L, contextA)
    consumerRegistry.shutdown(1L)

    // 5. 검증: B Consumer 존재, A Consumer 없음
    val consumers = streamOps.consumers(streamKey, consumerGroup)
    val remainingNames = consumers.map { it.consumerName() }
    assertThat(remainingNames).containsAll(consumerNamesB)
    assertThat(remainingNames).doesNotContainAnyElementsOf(consumerNamesA)
    assertThat(streamRedisTemplate.hasKey(streamKey)).isTrue()  // Stream 존재

    // 6. B shutdown — 마지막 인스턴스 → 전체 삭제
    val contextB = PromotionConsumerContext(
        container = containerB,
        subscriptions = subscriptionsB,
        executor = createTestExecutor(),
        streamRedisTemplate = streamRedisTemplate,
        streamKey = streamKey,
        consumerGroup = consumerGroup,
        consumerNames = consumerNamesB,
        startedAt = Instant.now()
    )
    consumerRegistry.register(1L, contextB)
    consumerRegistry.shutdown(1L)

    // 7. 검증: Stream 삭제됨
    assertThat(streamRedisTemplate.hasKey(streamKey)).isFalse()
}
```

### 7.6 shutdownAll (@PreDestroy) 테스트

**테스트 목표**: `shutdownAll()` 호출 시 모든 활성 Promotion이 종료되는지 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | 모든 Promotion 종료 | `consumerRegistry.isActive()` 모두 `false` |
| 2 | 모든 Stream 정리 | 각 streamKey에 대해 `hasKey()` == `false` |

**테스트 코드 흐름**:

```kotlin
@Test
fun `shutdownAll 호출 시 모든 활성 Promotion이 종료된다`() {
    // 1. 2개 Promotion 시작
    manager.startConsumers(1L, 1000, "voucher")
    manager.startConsumers(2L, 5000, "point")
    assertThat(consumerRegistry.isActive(1L)).isTrue()
    assertThat(consumerRegistry.isActive(2L)).isTrue()

    // 2. shutdownAll 호출
    consumerRegistry.shutdownAll()

    // 3. 모든 Promotion 종료 확인
    assertThat(consumerRegistry.isActive(1L)).isFalse()
    assertThat(consumerRegistry.isActive(2L)).isFalse()

    // 4. Stream 정리 확인
    assertThat(streamRedisTemplate.hasKey("promotion:1:voucher:stream")).isFalse()
    assertThat(streamRedisTemplate.hasKey("promotion:2:point:stream")).isFalse()
}
```

### 7.7 Producer→Manager→Consumer 연동 테스트

**테스트 목표**: `enqueue()`로 발행 → `startConsumers()`로 Consumer 기동 → 수신 → ACK → `stopConsumers()`의 전체 흐름을 검증한다.

**검증 항목**:

| # | 검증 | 방법 |
|---|------|------|
| 1 | 발행 후 수신 | Mock Processor `process()` 호출 횟수 == 발행 건수 |
| 2 | ACK 완료 | `XPENDING` pending count == 0 |
| 3 | stopConsumers 후 정리 | Registry에서 제거, Stream 삭제 |

**테스트 코드 흐름**:

```kotlin
@Test
fun `enqueue → startConsumers → 수신 → ACK → stopConsumers 전체 흐름`() {
    val promotionId = 1L
    val type = "voucher"
    val streamKey = "promotion:$promotionId:$type:stream"
    val consumerGroup = "promotion-$promotionId-$type-group"

    // 1. Consumer 시작
    manager.startConsumers(promotionId, 1000, type)

    // 2. 메시지 20건 발행
    repeat(20) { i ->
        manager.enqueue(promotionId, type, "key-$i", """{"promotionId":$promotionId,"targetId":$i}""")
    }

    // 3. 수신 대기
    Thread.sleep(5000)

    // 4. 검증: 모든 메시지 처리
    verify(mockProcessor, times(20)).process(any())

    // 5. 검증: ACK 완료
    val pending = streamOps.pending(streamKey, consumerGroup)
    assertThat(pending.totalPendingMessages).isEqualTo(0)

    // 6. stopConsumers
    manager.stopConsumers(promotionId)

    // 7. 검증: 정리 완료
    assertThat(consumerRegistry.isActive(promotionId)).isFalse()
    assertThat(streamRedisTemplate.hasKey(streamKey)).isFalse()
}
```

### 7.8 테스트 인프라

#### 테스트 Config

기존 `StreamMultiplexingTestConfig` 패턴을 따른다. Phase 1에서 구성한 `streamRedisConnectionFactory`를 사용한다.

#### 테스트 공통 setup/cleanup

```kotlin
@BeforeEach
fun setup() {
    // 이전 테스트 잔여물 제거
    streamRedisTemplate.delete("promotion:1:voucher:stream")
    streamRedisTemplate.delete("promotion:2:point:stream")
}

@AfterEach
fun cleanup() {
    // 활성 Promotion 모두 종료
    consumerRegistry.shutdownAll()
    // Stream 삭제
    streamRedisTemplate.delete("promotion:1:voucher:stream")
    streamRedisTemplate.delete("promotion:2:point:stream")
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

## 8. 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`phase1-redis-stream-infrastructure.md`](./phase1-redis-stream-infrastructure.md) | Phase 1 인프라 구성 — 5절 공유 ConnectionFactory 결정 (`createConnectionFactory` 삭제, `connectionFactory.destroy()` 제거) |
| [`phase2-redis-stream-consumer.md`](./phase2-redis-stream-consumer.md) | Phase 2 Consumer 구현 — `PromotionStreamConsumer`, Container + Subscription 구성 패턴 |
| [`phase3-redis-stream-producer.md`](./phase3-redis-stream-producer.md) | Phase 3 Producer 구현 — `PromotionStreamProducer`, `ensureStreamAndGroup()` |
| [`redis-stream-development-plan.md`](./redis-stream-development-plan.md) | 전체 개발 계획 (5 Phase) |
