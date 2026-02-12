```kotlin
import org.springframework.data.redis.connection.RedisConnectionFactory
import org.springframework.data.redis.connection.stream.Consumer
import org.springframework.data.redis.connection.stream.MapRecord
import org.springframework.data.redis.connection.stream.ReadOffset
import org.springframework.data.redis.connection.stream.StreamOffset
import org.springframework.data.redis.stream.StreamMessageListenerContainer
import org.springframework.data.redis.stream.StreamMessageListenerContainer.StreamMessageListenerContainerOptions
import org.springframework.data.redis.stream.Subscription
import java.time.Duration
import java.time.Instant
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class DynamicStreamContainerManager(
    private val connectionFactory: RedisConnectionFactory,
    private val idleTimeout: Duration,
    private val onShutdownComplete: (() -> Unit)? = null
) {
    private var container: StreamMessageListenerContainer<String, MapRecord<String, String, String>>? = null
    private val subscriptions = ConcurrentHashMap<String, SubscriptionEntry>()
    private var idleMonitor: ScheduledExecutorService? = null
    private val running = AtomicBoolean(false)

    // ── 컨테이너 + N개 컨슈머 일괄 시작 ──────────────────────────

    @Synchronized
    fun start(
        streamKey: String,
        groupName: String,
        consumers: List<String>,
        handler: (MapRecord<String, String, String>) -> Unit
    ) {
        check(!running.get()) { "Already running" }

        // 1) 컨테이너 생성 — Virtual Thread 기반 Executor
        val options = StreamMessageListenerContainerOptions.builder()
            .pollTimeout(Duration.ofSeconds(2))
            .batchSize(100)
            .executor(buildVirtualThreadExecutor())
            .build()

        container = StreamMessageListenerContainer.create(connectionFactory, options)

        // 2) N개 컨슈머 구독 등록
        consumers.forEach { consumerName ->
            val subscription = container!!.receive(
                Consumer.from(groupName, consumerName),
                StreamOffset.create(streamKey, ReadOffset.lastConsumed())
            ) { message ->
                touchLastActivity(consumerName)
                handler(message)
            }
            subscriptions[consumerName] = SubscriptionEntry(subscription)
        }

        // 3) 컨테이너 시작
        container!!.start()
        running.set(true)

        // 4) Idle 모니터 시작
        startIdleMonitor()
    }

    // ── Idle 모니터 ──────────────────────────────────────────────

    private fun startIdleMonitor() {
        idleMonitor = Executors.newSingleThreadScheduledExecutor { r ->
            Thread.ofVirtual().name("stream-idle-monitor").unstarted(r)
        }

        // 5초 간격으로 idle 체크
        idleMonitor!!.scheduleAtFixedRate(
            {
                if (!running.get()) return@scheduleAtFixedRate

                val allIdle = subscriptions.values.all { it.isIdleLongerThan(idleTimeout) }
                if (allIdle) {
                    shutdown()
                }
            },
            idleTimeout.toSeconds(),
            5,
            TimeUnit.SECONDS
        )
    }

    // ── 전체 종료 ────────────────────────────────────────────────

    @Synchronized
    fun shutdown() {
        if (!running.compareAndSet(true, false)) return

        // 1) 모든 구독 취소
        subscriptions.forEach { (_, entry) ->
            runCatching { entry.subscription.cancel() }
        }
        subscriptions.clear()

        // 2) 컨테이너 정지
        container?.stop()
        container = null

        // 3) 모니터 종료
        idleMonitor?.shutdownNow()
        idleMonitor = null

        // 4) 콜백 통지
        onShutdownComplete?.invoke()
    }

    fun isRunning(): Boolean = running.get()

    // ── 내부 헬퍼 ────────────────────────────────────────────────

    private fun touchLastActivity(consumerName: String) {
        subscriptions[consumerName]?.touch()
    }

    private fun buildVirtualThreadExecutor(): ExecutorService =
        Executors.newThreadPerTaskExecutor(
            Thread.ofVirtual().name("stream-consumer-", 0).factory()
        )

    // ── Subscription 래퍼 ────────────────────────────────────────

    private class SubscriptionEntry(val subscription: Subscription) {
        private val lastActivity = AtomicReference(Instant.now())

        fun touch() {
            lastActivity.set(Instant.now())
        }

        fun isIdleLongerThan(timeout: Duration): Boolean =
            Duration.between(lastActivity.get(), Instant.now()) > timeout
    }
}
```

```kotlin
import org.springframework.data.redis.connection.RedisConnectionFactory
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.stereotype.Service
import org.slf4j.LoggerFactory
import java.time.Duration
import java.util.concurrent.atomic.AtomicReference

@Service
class BulkPointStreamService(
    private val connectionFactory: RedisConnectionFactory,
    private val redisTemplate: StringRedisTemplate,
    private val pointHandler: PointDistributionHandler // 비즈니스 로직
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val managerRef = AtomicReference<DynamicStreamContainerManager>()

    companion object {
        private val IDLE_TIMEOUT = Duration.ofSeconds(30)
        private const val CONSUMER_COUNT = 4
    }

    /**
     * 배치 트리거 시점에 호출
     */
    fun onBatchTriggered(batchId: String) {
        val streamKey = "point-distribution:$batchId"
        val groupName = "point-group:$batchId"

        // 1) Consumer Group 생성
        createGroupIfAbsent(streamKey, groupName)

        // 2) 컨슈머 이름 목록 생성
        val consumerNames = (1..CONSUMER_COUNT).map { "consumer-$it" }

        // 3) 매니저 생성 & 시작
        val manager = DynamicStreamContainerManager(
            connectionFactory = connectionFactory,
            idleTimeout = IDLE_TIMEOUT,
            onShutdownComplete = { onProcessingComplete(batchId) }
        )

        manager.start(streamKey, groupName, consumerNames) { message ->
            pointHandler.handle(message)
            // ACK 처리
            redisTemplate.opsForStream().acknowledge(streamKey, groupName, message.id)
        }

        managerRef.set(manager)
        log.info("Stream consumer started: stream={}, consumers={}", streamKey, CONSUMER_COUNT)
    }

    /**
     * 30초 idle 후 자동 호출되는 콜백
     */
    private fun onProcessingComplete(batchId: String) {
        log.info(
            "All consumers idle for {}s — batch {} processing complete",
            IDLE_TIMEOUT.toSeconds(), batchId
        )

        managerRef.set(null)

        // 후속 작업: 배치 상태 갱신, 알림 발송, Stream 정리 등
        cleanupStream("point-distribution:$batchId")
    }

    /**
     * 수동 종료 (필요 시)
     */
    fun forceStop() {
        managerRef.getAndSet(null)
            ?.takeIf { it.isRunning() }
            ?.shutdown()
    }

    private fun createGroupIfAbsent(streamKey: String, groupName: String) {
        runCatching {
            redisTemplate.opsForStream().createGroup(streamKey, groupName)
        }.onFailure {
            // BUSYGROUP — 이미 존재하면 무시
            log.debug("Consumer group already exists: {}", groupName)
        }
    }

    private fun cleanupStream(streamKey: String) {
        redisTemplate.delete(streamKey)
        log.info("Stream cleaned up: {}", streamKey)
    }
}
```