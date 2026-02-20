# Phase 7: Custom Polling Loop 전환

## 1. 개요

### 1.1 배경

- Phase 1에서 ElastiCache Valkey의 XREADGROUP BLOCK 제약으로 인해 `pollTimeout(Duration.ZERO)` non-blocking polling을 결정
- Phase 4에서 `StreamMessageListenerContainer` 기반 동적 Consumer 관리를 구현
- **문제 발견**: 프로모션 처리 완료 후에도 빈 XREADGROUP이 ~20ms 간격으로 무한 반복 (busy-wait)

`StreamMessageListenerContainer`의 내부 `StreamPollTask`는 `pollTimeout(Duration.ZERO)` 환경에서 XREADGROUP이 즉시 빈 배열을 반환하면 대기 없이 곧바로 다음 poll을 실행한다. 프로모션 메시지를 모두 처리한 후에도 Consumer가 종료되지 않고 tight loop으로 XREADGROUP을 반복하여 CPU/네트워크 자원을 낭비한다.

### 1.2 목표

- `StreamMessageListenerContainer` → custom polling loop 전환
- busy-wait 제거 (client-side sleep)
- idle 자동 종료 (마지막 메시지 수신 후 30초)

### 1.3 Phase 7 범위

| 포함 | 미포함 |
|------|--------|
| `PromotionStreamConsumer` 리팩토링 (StreamListener 제거) | 기존 Phase 1~6 문서 수정 |
| `PromotionStreamManager` 리팩토링 (Container 제거, polling task 생성) | 커넥션 풀 도입 |
| `PromotionConsumerContext` 필드 변경 | PEL 복구 로직 |
| `RedisStreamProperties` 프로퍼티 추가 | |
| idle auto-stop 구현 | |

---

## 2. 아키텍처 변경

### 2.1 변경 전 (Phase 1~4 설계)

```
StreamMessageListenerContainer (Spring)
  └─> StreamPollTask (내부 루프)
      └─> XREADGROUP COUNT {batchSize} (non-blocking, Duration.ZERO)
      └─> 메시지 있음: StreamListener.onMessage() 콜백
      └─> 메시지 없음: 즉시 다음 poll (tight loop!)
```

### 2.2 변경 후 (Phase 7)

```
Custom polling task (직접 구현)
  └─> while (running && !idleTimeout)
      └─> xReadGroup() (non-blocking)
      └─> 메시지 있음: consumer.processMessage() + ACK, lastMessageTime 갱신
      └─> 메시지 없음: Thread.sleep(pollIntervalMs)
      └─> 자동 종료: now - lastMessageTime >= idleTimeoutSeconds (30s)
              └─> onIdleStop 콜백 → Registry.shutdown(promotionId)
```

### 2.3 변경 요약 테이블

| 항목 | Phase 1~4 (변경 전) | Phase 7 (변경 후) |
|------|---------------------|-------------------|
| polling 주체 | `StreamMessageListenerContainer` (Spring) | custom polling Runnable (직접 구현) |
| Consumer 인터페이스 | `StreamListener.onMessage()` 콜백 | `PromotionStreamConsumer.processMessage()` 직접 호출 |
| 빈 poll 시 동작 | 즉시 다음 poll (tight loop) | `Thread.sleep(pollIntervalMs)` 후 다음 poll |
| idle 자동 종료 | 없음 (무한 polling) | 마지막 메시지 수신 후 `idleTimeoutSeconds` 경과 시 자동 종료 |
| Context 필드 | `container`, `subscriptions` | `pollingFutures`, `stopFlag`, `lastMessageTime` |
| Shutdown 방식 | `subscription.cancel()` → `container.stop()` | `stopFlag.set(true)` → futures 완료 대기 |

---

## 3. 컴포넌트 변경 상세

### 3.1 PromotionStreamConsumer (변경)

- `StreamListener<String, MapRecord<String, String, String>>` 인터페이스 **제거**
- `onMessage()` → `processMessage()` 리네이밍
- 내부 로직(parse → processStreamMessage → ACK)은 동일
- polling loop에서 직접 호출하는 형태

**변경 전:**

```kotlin
class PromotionStreamConsumer(
    private val processor: AbstractCampaignPromotionProcessor<*, *>,
    private val streamRedisTemplate: StringRedisTemplate,
    private val streamKey: String,
    private val consumerGroup: String,
) : StreamListener<String, MapRecord<String, String, String>> {

    private val log = KotlinLogging.logger {}

    override fun onMessage(message: MapRecord<String, String, String>) {
        val payload = message.value
        val json = payload["message"] ?: run {
            log.warn { "[StreamConsumer] Missing 'message' field - recordId=${message.id}" }
            acknowledge(message)
            return
        }
        val key = payload["key"] ?: ""

        try {
            processor.processStreamMessage(json)
            acknowledge(message)
            log.debug { "[StreamConsumer] Processed - recordId=${message.id}, key=$key" }
        } catch (e: Exception) {
            log.error(e) { "[StreamConsumer] Processing failed - recordId=${message.id}, key=$key" }
            // ACK 안 함 → PEL 유지 → 재처리 대상
        }
    }

    private fun acknowledge(message: MapRecord<String, String, String>) {
        streamRedisTemplate.xAck(streamKey, consumerGroup, message.id)
    }
}
```

**변경 후:**

```kotlin
class PromotionStreamConsumer(
    private val processor: AbstractCampaignPromotionProcessor<*, *>,
    private val streamRedisTemplate: StringRedisTemplate,
    private val streamKey: String,
    private val consumerGroup: String,
) {
    private val log = KotlinLogging.logger {}

    fun processMessage(message: MapRecord<String, String, String>) {
        val payload = message.value
        val json = payload["message"] ?: run {
            log.warn { "[StreamConsumer] Missing 'message' field - recordId=${message.id}" }
            acknowledge(message)
            return
        }
        val key = payload["key"] ?: ""

        try {
            processor.processStreamMessage(json)
            acknowledge(message)
            log.debug { "[StreamConsumer] Processed - recordId=${message.id}, key=$key" }
        } catch (e: Exception) {
            log.error(e) { "[StreamConsumer] Processing failed - recordId=${message.id}, key=$key" }
            // ACK 안 함 → PEL 유지 → 재처리 대상
        }
    }

    private fun acknowledge(message: MapRecord<String, String, String>) {
        streamRedisTemplate.xAck(streamKey, consumerGroup, message.id)
    }
}
```

### 3.2 PromotionStreamManager (변경)

- `createContainer()` 삭제 → `createPollingTask()` 신규
- `startConsumers()` 내부: Container+Subscription → polling task submit
- `streamConnectionFactory` 생성자 파라미터 **삭제** (Container 생성에만 필요했음, polling은 `streamRedisTemplate`만 사용)

**startConsumers() 변경 흐름:**

```
변경 전:
  1. xGroupCreate(streamKey, consumerGroup)
  2. createExecutor()
  3. createContainer(executor)
  4. container.receive() × N  → Subscription 등록
  5. container.start()
  6. registry.register(context with container, subscriptions)

변경 후:
  1. xGroupCreate(streamKey, consumerGroup)
  2. createExecutor()
  3. stopFlag = AtomicBoolean(false), lastMessageTime = AtomicLong(now)
  4. consumerNames별 polling task 생성 → executor.submit() × N → futures
  5. registry.register(context with futures, stopFlag, lastMessageTime)
```

**startConsumers() 변경 후 코드:**

```kotlin
fun startConsumers(promotionId: Long, promotionType: PromotionType, totalCount: Int) {
    lock.lock()
    try {
        if (consumerRegistry.isActive(promotionId)) {
            log.info { "[Manager] Already active: promotion=$promotionId" }
            return
        }

        val streamKey = promotionType.streamKey(promotionId)
        val consumerGroup = promotionType.consumerGroup(promotionId)
        val processor = getPromotionProcessor(promotionType)
        val consumerCount = calculateConsumerCountPerInstance(totalCount, properties.minConsumerPerInstance, properties.maxConsumerPerInstance)

        val created = streamRedisTemplate.xGroupCreate(streamKey, consumerGroup)
        if (created) {
            log.info { "[Manager] Created consumer group: $consumerGroup for stream: $streamKey" }
        } else {
            log.info { "[Manager] Consumer group already exists: $consumerGroup" }
        }

        val executor = createExecutor(consumerCount, promotionId)
        val stopFlag = AtomicBoolean(false)
        val lastMessageTime = AtomicLong(System.currentTimeMillis())

        val consumer = PromotionStreamConsumer(
            processor = processor,
            streamKey = streamKey,
            consumerGroup = consumerGroup,
            streamRedisTemplate = streamRedisTemplate,
        )
        val consumerNames = (0 until consumerCount).map { "$instanceId-consumer-$it" }
        val futures = consumerNames.map { consumerName ->
            executor.submit(
                createPollingTask(
                    consumer = consumer,
                    consumerName = consumerName,
                    streamKey = streamKey,
                    consumerGroup = consumerGroup,
                    stopFlag = stopFlag,
                    lastMessageTime = lastMessageTime,
                    onIdleStop = { consumerRegistry.shutdown(promotionId) },
                )
            )
        }

        consumerRegistry.register(
            promotionId = promotionId,
            context = PromotionConsumerContext(
                pollingFutures = futures,
                stopFlag = stopFlag,
                lastMessageTime = lastMessageTime,
                executor = executor,
                streamKey = streamKey,
                consumerGroup = consumerGroup,
                consumerNames = consumerNames,
                streamRedisTemplate = streamRedisTemplate,
                startedAt = Instant.now(),
            ),
        )

        log.info { "[Manager] Started consumers for promotion=$promotionId - type=$promotionType, consumerCount=$consumerCount, streamKey=$streamKey" }
    } finally {
        lock.unlock()
    }
}
```

**createPollingTask() 설계:**

```kotlin
private fun createPollingTask(
    consumer: PromotionStreamConsumer,
    consumerName: String,
    streamKey: String,
    consumerGroup: String,
    stopFlag: AtomicBoolean,
    lastMessageTime: AtomicLong,
    onIdleStop: () -> Unit,
): Runnable = Runnable {
    while (!stopFlag.get()) {
        try {
            val messages = streamRedisTemplate.xReadGroup(
                group = consumerGroup,
                consumer = consumerName,
                streamKey = streamKey,
                count = properties.batchSize.toLong(),
            )

            if (!messages.isNullOrEmpty()) {
                messages.forEach { consumer.processMessage(it) }
                lastMessageTime.set(System.currentTimeMillis())
            } else {
                // idle timeout 체크
                val idleMs = System.currentTimeMillis() - lastMessageTime.get()
                if (idleMs >= properties.idleTimeoutSeconds * 1000) {
                    log.info { "[PollingTask] Idle timeout (${properties.idleTimeoutSeconds}s) - consumer=$consumerName" }
                    onIdleStop()
                    return@Runnable
                }
                Thread.sleep(properties.pollIntervalMs)
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            break
        } catch (e: Exception) {
            log.error(e) { "[PollingTask] Error in polling loop - consumer=$consumerName" }
            Thread.sleep(properties.pollIntervalMs)
        }
    }
}
```

> **참고**: `xReadGroup()` 확장함수는 `StringRedisTemplateStreamExtensions.kt`에 정의되어 있으며 Phase 2에서 구현됨. 시그니처: `fun StringRedisTemplate.xReadGroup(group: String, consumer: String, streamKey: String, count: Long = 10): List<MapRecord<String, String, String>>?`

**`streamConnectionFactory` 파라미터 삭제:**

```kotlin
// 변경 전
@Service
class PromotionStreamManager(
    @param:Qualifier("streamRedisConnectionFactory")
    private val streamConnectionFactory: LettuceConnectionFactory,
    @param:Qualifier("streamRedisTemplate")
    private val streamRedisTemplate: StringRedisTemplate,
    ...
)

// 변경 후
@Service
class PromotionStreamManager(
    @param:Qualifier("streamRedisTemplate")
    private val streamRedisTemplate: StringRedisTemplate,
    ...
)
```

`streamConnectionFactory`는 `StreamMessageListenerContainer.create(connectionFactory, options)` 호출에서만 사용되었으므로, Container 제거에 따라 불필요해진다.

### 3.3 PromotionConsumerContext (변경)

**변경 전:**

```kotlin
data class PromotionConsumerContext(
    val container: StreamMessageListenerContainer<String, MapRecord<String, String, String>>,
    val subscriptions: List<Subscription>,
    val executor: ThreadPoolTaskExecutor,
    val streamKey: String,
    val consumerGroup: String,
    val consumerNames: List<String>,
    val streamRedisTemplate: StringRedisTemplate,
    val startedAt: Instant,
)
```

**변경 후:**

```kotlin
data class PromotionConsumerContext(
    val pollingFutures: List<Future<*>>,
    val stopFlag: AtomicBoolean,
    val lastMessageTime: AtomicLong,
    val executor: ThreadPoolTaskExecutor,
    val streamKey: String,
    val consumerGroup: String,
    val consumerNames: List<String>,
    val streamRedisTemplate: StringRedisTemplate,
    val startedAt: Instant,
)
```

| 삭제 필드 | 추가 필드 | 설명 |
|-----------|-----------|------|
| `container: StreamMessageListenerContainer` | `pollingFutures: List<Future<*>>` | polling task의 Future 목록 |
| `subscriptions: List<Subscription>` | `stopFlag: AtomicBoolean` | polling loop 중지 신호 |
| | `lastMessageTime: AtomicLong` | 마지막 메시지 수신 시각 (epoch ms) |

### 3.4 PromotionConsumerRegistry.shutdown() (변경)

**변경 전:**

```kotlin
fun shutdown(promotionId: Long) {
    val context = activePromotions.remove(promotionId) ?: run {
        log.warn { "[Registry] Promotion not found: $promotionId" }
        return
    }

    // 순서 중요: Subscription 취소 → Container 중지 → Stream 정리 → Executor 종료
    context.subscriptions.forEach { it.cancel() }
    context.container.stop()

    cleanupStream(context)

    context.executor.shutdown()

    log.info { "[Registry] Shutdown promotion=$promotionId" }
}
```

**변경 후:**

```kotlin
fun shutdown(promotionId: Long) {
    val context = activePromotions.remove(promotionId) ?: run {
        log.warn { "[Registry] Promotion not found: $promotionId" }
        return
    }

    // 순서: stopFlag → futures 완료 대기 → Stream 정리 → Executor 종료
    context.stopFlag.set(true)
    context.pollingFutures.forEach {
        try {
            it.get(5, TimeUnit.SECONDS)
        } catch (e: Exception) {
            log.warn { "[Registry] Polling task did not complete in time" }
        }
    }

    cleanupStream(context)

    context.executor.shutdown()

    log.info { "[Registry] Shutdown promotion=$promotionId" }
}
```

**변경 포인트:**
- `subscription.cancel()` + `container.stop()` → `stopFlag.set(true)` + `futures.get(5s)`
- `activePromotions.remove()`의 null guard가 idle auto-stop에서의 중복 호출을 방지

### 3.5 RedisStreamProperties (프로퍼티 추가)

**변경 전:**

```kotlin
@ConfigurationProperties(prefix = "redis.stream")
data class RedisStreamProperties(
    val enabled: Boolean = false,
    val batchSize: Int = 10,
    val maxLen: Long = 100_000,
    val minConsumerPerInstance: Int = 1,
    val maxConsumerPerInstance: Int = 32,
)
```

**변경 후:**

```kotlin
@ConfigurationProperties(prefix = "redis.stream")
data class RedisStreamProperties(
    val enabled: Boolean = false,
    val batchSize: Int = 10,
    val maxLen: Long = 100_000,
    val minConsumerPerInstance: Int = 1,
    val maxConsumerPerInstance: Int = 32,
    val pollIntervalMs: Long = 100,          // 빈 poll 시 sleep (ms)
    val idleTimeoutSeconds: Long = 30,       // idle 자동 종료 (초)
)
```

**redis.yml 추가:**

```yaml
redis:
  stream:
    enabled: true
    batch-size: 10
    max-len: 100000
    min-consumer-per-instance: 2
    max-consumer-per-instance: 32
    poll-interval-ms: 100
    idle-timeout-seconds: 30
```

---

## 4. idle auto-stop 설계

### 4.1 idle 판단 기준

- **시간 기반**: 마지막 메시지 수신 시각(`lastMessageTime`)으로부터 `idleTimeoutSeconds`(30초) 경과
- Consumer별이 아닌 **Promotion 전체** 기준 (`AtomicLong` 공유)
- 첫 poll 시작 시 `lastMessageTime = System.currentTimeMillis()`로 초기화 → 한 번도 메시지를 못 받아도 30초 후 종료

### 4.2 자동 종료 흐름

```
polling task N개 중 1개가 idle timeout 감지
  → onIdleStop() 콜백 호출
  → consumerRegistry.shutdown(promotionId) (동기)
  → stopFlag.set(true) → 나머지 polling task도 루프 탈출
  → cleanupStream + executor.shutdown
```

### 4.3 동시성 고려

- `stopFlag`: `AtomicBoolean` — 여러 polling task가 동시에 체크
- `lastMessageTime`: `AtomicLong` — 여러 polling task가 동시에 갱신
- `onIdleStop()`: 첫 호출만 유효하도록 `shutdown()` 내부의 `activePromotions.remove()`가 null guard 역할
  - 첫 번째 호출: `remove()` 성공 → shutdown 수행
  - 이후 호출: `remove()` 반환값 null → 즉시 return

---

## 5. 기존 Phase 대비 변경 파일 매핑

| 파일 | 기존 Phase | Phase 7 변경 |
|------|:----------:|-------------|
| `PromotionStreamConsumer.kt` | Phase 2 | `StreamListener` 제거, `processMessage()` 리네이밍 |
| `PromotionStreamManager.kt` | Phase 4 | `createContainer()` 삭제, `createPollingTask()` 추가, `startConsumers()` 재작성, `streamConnectionFactory` 삭제 |
| `PromotionConsumerContext.kt` | Phase 4 | `container`/`subscriptions` 삭제, `pollingFutures`/`stopFlag`/`lastMessageTime` 추가 |
| `PromotionConsumerRegistry.kt` | Phase 4 | `shutdown()` 내 Container 중지 → stopFlag + futures 대기 |
| `RedisStreamProperties.kt` | Phase 1 | `pollIntervalMs`, `idleTimeoutSeconds` 추가 |
| `redis.yml` | Phase 1 | 프로퍼티 추가 |
| `StringRedisTemplateStreamExtensions.kt` | Phase 2 | **변경 없음** (`xReadGroup()` 그대로 사용) |
| `RedisStreamConfig.kt` | Phase 1 | **변경 없음** |
| `PromotionStreamProducer.kt` | Phase 3 | **변경 없음** |

---

## 6. 검증 방법

### 6.1 기본 동작 테스트

- `startConsumers()` → 메시지 발행 → polling task가 수신 → ACK 확인
- `xLen()`, `xPending()` 확인

### 6.2 idle auto-stop 테스트

- 메시지 발행 → 전부 처리 → `idleTimeoutSeconds` 경과 대기 → `isActive()` == `false` 확인
- Registry에서 자동 제거, Stream/Consumer Group 정리 완료 확인

### 6.3 수동 종료 테스트

- `stopConsumers()` 호출 → `stopFlag`로 polling task 즉시 종료 → 정리 확인

### 6.4 graceful shutdown 테스트

- 앱 종료 시 `SmartLifecycle.stop()` → `shutdownAll()` → 모든 polling task 종료 확인
