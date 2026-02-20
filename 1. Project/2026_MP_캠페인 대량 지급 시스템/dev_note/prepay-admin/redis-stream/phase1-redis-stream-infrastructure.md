# Redis Stream 연동 인프라 구성

## 목차

1. [개요](#1-개요)
2. [초기 설계 대비 변경점 요약](#2-초기-설계-대비-변경점-요약)
3. [Stream 전용 ConnectionFactory 설정 (`RedisStreamConfig`)](#3-stream-전용-connectionfactory-설정-redisstreamconfig)
4. [Container 설정 변경 (`PromotionStreamManager.createContainer`)](#4-container-설정-변경-promotionstreammanagercreatecontainer)
5. [Container ConnectionFactory 변경 (`PromotionStreamManager.createConnectionFactory`)](#5-container-connectionfactory-변경-promotionstreammanagercreateconnectionfactory)
6. [프로퍼티 변경 (`RedisStreamProperties`)](#6-프로퍼티-변경-redisstreamproperties)
7. [알려진 제약사항 및 트레이드오프](#7-알려진-제약사항-및-트레이드오프)
8. [기존 `RedisTemplateConfig` 수정 사항](#8-기존-redistemplateconfig-수정-사항)
9. [실제 구현 범위](#9-실제-구현-범위)
10. [검증 방법](#10-검증-방법)
11. [근거 문서 링크](#11-근거-문서-링크)

---

## 1. 개요

### 1.1 배경

[`redis-stream-development-plan.md`](./redis-stream-development-plan.md)에서 설계한 Kafka → Redis Stream → 병렬 Consumer 아키텍처의 **인프라 구성(ConnectionFactory, Container 설정)** 상세를 기술한다.

전체 아키텍처 및 비즈니스 로직(Producer, Consumer, Registry, Kafka Listener 변경 등)은 각 Phase 상세 문서를 참고한다.

### 1.2 테스트 결과 요약

| 발견 | 원인 | 근거 |
|------|------|------|
| `XREADGROUP BLOCK` 실패 | ElastiCache Valkey가 **신규 커넥션**의 `XREADGROUP BLOCK`을 거부 (`ERR [ENGINE] Invalid command`) | [standalone-test-result](./redis-stream-standalone-test-result.md) |
| Spring Data Redis blocking 감지 | blocking 명령 감지 시 **전용(dedicated) 커넥션을 신규 생성** → 항상 실패 | [standalone-test-result](./redis-stream-standalone-test-result.md) 1.3절 |
| `connection.execute()` 경유 시 성공 | 공유 풀 커넥션(기존 커넥션) 경로를 사용하면 `XREADGROUP BLOCK` 동작 | [standalone-test-result](./redis-stream-standalone-test-result.md) 1.2절 |
| 멀티플렉싱 성능 저하 | non-blocking polling Subscription 수에 비례하여 다른 Redis 명령 응답시간 선형 증가 | [multiplexing-test-result](./redis-stream-multiplexing-test-result.md) 2절 |

배제된 가설: `CLIENT SETINFO` 핸드셰이크, 커넥션 워밍업, `StaticMasterReplica` vs `Standalone` 구성 방식 — 모두 원인이 아님.

### 1.3 결정 사항

| 항목 | 결정 | 근거 |
|------|------|------|
| polling 방식 | **non-blocking** (`pollTimeout(Duration.ZERO)`) | `XREADGROUP BLOCK` 사용 불가 |
| 커넥션 구성 | **멀티플렉싱 단일 커넥션** (`LettuceClientConfiguration`, 커넥션 풀 없음) | 커넥션 풀 도입은 팀 내부 추가 논의 후 결정 |
| ConnectionFactory | **Stream 전용 별도 ConnectionFactory** (기존 `redisConnectFactory`와 분리) | Serializer 불일치, 관심사 분리 |
| 프로퍼티 | 기존 `redis.master/slave` 재사용 (별도 host/port 불필요) | 동일 Redis 인스턴스 사용 |

---

## 2. 초기 설계 대비 변경점 요약

| 항목 | 초기 설계 (원본) | infrastructure.md (이번 문서) |
|------|----------------------|------------------------------|
| ConnectionFactory | `LettucePoolingClientConfiguration` (커넥션 풀) | `LettuceClientConfiguration` (멀티플렉싱) |
| `commons-pool2` | 필요 | **불필요** |
| ReadFrom | `UPSTREAM` (Master only) | `REPLICA_PREFERRED` (기존과 동일) |
| pollTimeout | `Duration.ofMillis(blockTimeoutMs)` (BLOCK) | `Duration.ZERO` (non-blocking) |
| commandTimeout | `> blockTimeoutMs` | 기존과 동일 (`connectTimeout`) |
| 프로퍼티 | `RedisStreamConnectionProperties` (별도 host/port) | **기존 `redis.master/slave` 재사용** |
| Promotion별 동적 ConnectionFactory | `createConnectionFactory(consumerCount)` 메서드 | **삭제** — 공유 `streamRedisConnectionFactory` 사용 |
| PromotionConsumerContext.connectionFactory | Promotion별 전용, shutdown 시 `destroy()` | **공유 팩토리 참조**, shutdown 시 `destroy()` 호출하지 않음 |

변경하지 않는 항목:
- 전체 아키텍처(Kafka → Redis Stream → 병렬 Consumer)
- Producer, Consumer, Registry, Kafka Listener 변경 등 비즈니스 로직
- 수동 ACK 전략, Consumer 수 동적 계산 로직
- Stream 관리 정책(MAXLEN trimming, cleanupStream)

---

## 3. Stream 전용 ConnectionFactory 설정 (`RedisStreamConfig`)

기존 [`RedisTemplateConfig.kt`](../../src/main/kotlin/com/musinsapayments/prepay/application/prepay/admin/core/config/RedisTemplateConfig.kt)의 패턴을 따르되, Stream 전용으로 분리한다.

### ConnectionFactory 분리가 필요한 이유

| # | 문제 | 설명 |
|---|------|------|
| 1 | hashValueSerializer 불일치 | 기존 `redisTemplate`은 `GenericJackson2JsonRedisSerializer`를 hashValue에 사용 → Stream entry에 타입 정보를 추가하여 이중 인코딩 발생 |
| 2 | 관심사 분리 | Stream 전용 설정(pollTimeout, batchSize 등)과 기존 캐시/세션 설정을 독립적으로 관리 |

### 코드

```kotlin
@EnableConfigurationProperties(RedisStreamProperties::class)
@Configuration
class RedisStreamConfig {

    @Bean
    fun streamRedisConnectionFactory(
        @Value("\${redis.master.host}") masterHost: String,
        @Value("\${redis.master.port}") masterPort: Int,
        @Value("\${redis.slave.host}") slaveHost: String,
        @Value("\${redis.slave.port}") slavePort: Int,
        @Value("\${redis.connect-timeout}") connectTimeout: Long,
    ): LettuceConnectionFactory {
        val clientConfig = LettuceClientConfiguration.builder()
            .clientOptions(
                ClientOptions.builder()
                    .autoReconnect(true)
                    .disconnectedBehavior(ClientOptions.DisconnectedBehavior.REJECT_COMMANDS)
                    .protocolVersion(ProtocolVersion.RESP2)
                    .build()
            )
            .commandTimeout(Duration.ofSeconds(connectTimeout))
            .readFrom(ReadFrom.REPLICA_PREFERRED)
            .build()

        val masterReplicaConfig = RedisStaticMasterReplicaConfiguration(masterHost, masterPort)
        masterReplicaConfig.addNode(slaveHost, slavePort)

        return LettuceConnectionFactory(masterReplicaConfig, clientConfig)
    }

    /**
     * Stream 전용 RedisTemplate.
     * StringRedisTemplate은 모든 Serializer가 StringRedisSerializer이므로
     * Stream entry가 순수 문자열로 저장/조회된다. (GenericJackson2Json 이중인코딩 방지)
     */
    @Bean
    fun streamRedisTemplate(
        @Qualifier("streamRedisConnectionFactory") connectionFactory: RedisConnectionFactory
    ): StringRedisTemplate = StringRedisTemplate(connectionFactory)
}
```

### 핵심 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| `@Primary` | 기존 `RedisTemplateConfig`에 추가 | Bean 충돌 방지 (8절 참조) |
| `ReadFrom.REPLICA_PREFERRED` | 기존과 동일 | XADD(쓰기)는 자동으로 Master로 라우팅됨 |
| 커넥션 풀 미사용 | `LettuceClientConfiguration` (멀티플렉싱) | 커넥션 풀은 팀 내부 추가 논의 후 도입 |
| `commons-pool2` 의존성 | **불필요** | 커넥션 풀을 사용하지 않으므로 |
| `StringRedisTemplate` | Stream 전용 | Stream entry를 순수 문자열로 저장 |

---

## 4. Container 설정 변경 (`PromotionStreamManager.createContainer`)

```kotlin
// 변경 전 (architecture.md)
.pollTimeout(Duration.ofMillis(properties.blockTimeoutMs))  // XREADGROUP BLOCK 2000

// 변경 후 (이번 문서)
.pollTimeout(Duration.ZERO)  // non-blocking XREADGROUP (BLOCK 미사용)
```

### non-blocking 동작 원리

`StreamMessageListenerContainer` 내부의 `StreamPollTask`는 `pollTimeout` 값에 따라 동작이 달라진다:

| pollTimeout | 실행되는 Redis 명령 | 동작 |
|-------------|-------------------|------|
| `> 0` | `XREADGROUP COUNT {batchSize} BLOCK {pollTimeout}` | 데이터가 올 때까지 blocking 대기 |
| `Duration.ZERO` | `XREADGROUP COUNT {batchSize}` | 즉시 응답 반환 (non-blocking) |

`pollTimeout(Duration.ZERO)` 설정 시:
1. `StreamPollTask`가 `XREADGROUP COUNT {batchSize}` 실행 (BLOCK 파라미터 없음)
2. 데이터가 있으면 메시지를 반환하고 `onMessage()` 호출
3. 데이터가 없으면 즉시 빈 응답 반환
4. 다음 poll 즉시 실행 → **tight loop**

---

## 5. Container ConnectionFactory 변경 (`PromotionStreamManager.createConnectionFactory`)

### 변경 전 (architecture.md)

`PromotionStreamManager`가 Promotion별로 전용 `LettucePoolingClientConfiguration` ConnectionFactory를 동적 생성:

```kotlin
// architecture.md의 createConnectionFactory(consumerCount)
private fun createConnectionFactory(consumerCount: Int): LettuceConnectionFactory {
    val poolConfig = GenericObjectPoolConfig<Any>().apply {
        maxTotal = consumerCount + 4
        maxIdle = consumerCount + 2
        minIdle = 0
    }
    val clientConfig = LettucePoolingClientConfiguration.builder()
        .poolConfig(poolConfig)
        // ...
}
```

### 변경 후 (이번 문서)

공유 `streamRedisConnectionFactory`를 Container에 직접 전달. `createConnectionFactory()` 메서드 삭제.

```kotlin
@Service
class PromotionStreamManager(
    @Qualifier("streamRedisConnectionFactory")
    private val streamConnectionFactory: LettuceConnectionFactory,  // 공유 ConnectionFactory
    @Qualifier("streamRedisTemplate")
    private val streamRedisTemplate: StringRedisTemplate,
    private val consumerRegistry: PromotionConsumerRegistry,
    private val producer: PromotionStreamProducer,
    private val properties: RedisStreamProperties,
    // ...
) {
    // ...

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

    // ...
}
```

### 변경 사항 요약

| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| `createConnectionFactory(consumerCount)` | Promotion별 전용 Pool 생성 | **삭제** |
| Container의 ConnectionFactory | Promotion별 전용 팩토리 | 공유 `streamRedisConnectionFactory` |
| `PromotionConsumerContext.connectionFactory` | Promotion별 전용, `destroy()` 호출 | 공유 팩토리 참조, **`destroy()` 호출하지 않음** |
| 물리 커넥션 수 | Subscription 수 + 여유분 | **1개** (모든 Subscription이 멀티플렉싱으로 공유) |

### `PromotionConsumerRegistry.shutdown()` 변경

```kotlin
// 변경 전 (architecture.md)
fun shutdown(promotionId: Long) {
    // ...
    context.subscriptions.forEach { it.cancel() }
    context.container.stop()
    cleanupStream(context)
    context.connectionFactory.destroy()   // Promotion별 전용 Pool 파괴
    context.executor.shutdown()
}

// 변경 후 (이번 문서)
fun shutdown(promotionId: Long) {
    // ...
    context.subscriptions.forEach { it.cancel() }
    context.container.stop()
    cleanupStream(context)
    // connectionFactory.destroy() 삭제 — 공유 팩토리이므로 파괴하지 않음
    context.executor.shutdown()
}
```

---

## 6. 프로퍼티 변경 (`RedisStreamProperties`)

### 변경 전 (architecture.md)

```kotlin
@ConfigurationProperties(prefix = "redis.stream")
data class RedisStreamProperties(
    val enabled: Boolean = false,
    val blockTimeoutMs: Long = 2000,
    val batchSize: Int = 10,
    val maxLen: Long = 100_000,
    val maxConsumerPerInstance: Int = 32,
    val connection: RedisStreamConnectionProperties = RedisStreamConnectionProperties()
)

data class RedisStreamConnectionProperties(
    val host: String = "localhost",
    val port: Int = 6379,
    val replicaHost: String = "localhost",
    val replicaPort: Int = 6379,
    val commandTimeoutMs: Long = 10_000,
    val pool: RedisStreamPoolProperties = RedisStreamPoolProperties()
)

data class RedisStreamPoolProperties(
    val maxTotal: Int = 20,
    val maxIdle: Int = 10,
    val minIdle: Int = 0
)
```

### 변경 후 (이번 문서)

```kotlin
@ConfigurationProperties(prefix = "redis.stream")
data class RedisStreamProperties(
    val enabled: Boolean = false,
    val batchSize: Int = 10,                     // COUNT 옵션
    val maxLen: Long = 100_000,                  // MAXLEN trimming
    val maxConsumerPerInstance: Int = 32,
)
```

| 삭제된 항목 | 이유 |
|------------|------|
| `blockTimeoutMs` | non-blocking (`pollTimeout(Duration.ZERO)`)이므로 불필요 |
| `connection` (별도 host/port) | 기존 `redis.master/slave` 프로퍼티를 재사용 |
| `connection.pool` | 커넥션 풀 미사용 |
| `connection.commandTimeoutMs` | 기존 `redis.connect-timeout`과 동일하게 사용 |

### redis.yml 변경

```yaml
redis:
  # ... 기존 설정 (master, slave, connect-timeout 등) 유지 ...

  stream:
    enabled: false                         # Feature Toggle (false면 기존 직접 처리)
    batch-size: 10                         # XREAD COUNT (한 번에 읽을 개수)
    max-len: 100000                        # Stream MAXLEN trimming
    max-consumer-per-instance: 32          # 인스턴스당 최대 Consumer 수
```

삭제된 항목 (architecture.md 대비):
- `block-timeout-ms` — non-blocking이므로 불필요
- `connection.*` — 기존 `redis.master/slave` 재사용

---

## 7. 알려진 제약사항 및 트레이드오프

### 7.1 tight loop CPU 부하

`pollTimeout(Duration.ZERO)`는 데이터가 없어도 즉시 다음 poll을 실행한다.
Subscription 수 × 초당 수천 회의 `XREADGROUP` 명령이 발생할 수 있다.

tight loop은 **처리할 메시지가 없는 상태에서 poll 자체가 빠르게 반복**되는 것이 원인이다.
`onMessage()`는 메시지가 있을 때만 호출되므로, 컨슈머 내부에 지연을 넣어도 빈 poll 반복에는 영향이 없다.

```
StreamPollTask.doLoop()
│
├─ [poll] XREADGROUP COUNT 10  ──→  메시지 있음?
│                                     ├─ YES → onMessage() 호출 (처리 ~200ms, 자연 backpressure)
│                                     └─ NO  → 빈 응답 즉시 반환 ← tight loop 발생 지점
│
└─ 다음 iteration 즉시 시작  ←────────────┘
```

**대응 방안:**

| 방식 | 설명 | 비고 |
|------|------|------|
| `pollTimeout`에 짧은 값 설정 | e.g. `Duration.ofMillis(100)` | 내부적으로 `XREADGROUP BLOCK 100`으로 변환되어 `ERR [ENGINE]` 실패 → **사용 불가** |
| 커스텀 `StreamPollTask` | 빈 응답 시 `Thread.sleep`을 삽입하는 커스텀 구현 | `StreamMessageListenerContainer` 내부 API 의존, 유지보수 부담 |
| **커넥션 풀 도입** | poll이 빠르게 반복되더라도 각 Subscription이 별도 커넥션을 사용하므로 경합 없음 | **근본 해결** (7.3절 참조) |

현재 구성(멀티플렉싱)에서는 tight loop 자체를 제어할 표준 API가 없고, `pollTimeout > 0`은 BLOCK 명령으로 변환되어 실패한다.
운영 환경에서 실제 CPU/네트워크 부하를 측정하여 수용 가능 여부를 판단하고, 필요 시 커넥션 풀 도입(7.3절)을 진행한다.

### 7.2 멀티플렉싱 성능 저하

테스트 환경(VPN 경유, `127.0.0.1:40198`)에서의 SET+GET 응답시간:

| Subscription 수 | SET+GET 평균 | SET+GET 최대 |
|:---:|:---:|:---:|
| 1 | 107ms | 161ms |
| 4 | 245ms | 361ms |
| 8 | 428ms | 479ms |
| 16 | 761ms | 827ms |
| 32 | 704ms | 828ms |

> 참고: 실제 운영 환경(VPC 내부, VPN 미경유)에서는 네트워크 지연이 훨씬 작으므로 성능 수치가 다를 수 있음.

32개 Subscription non-blocking polling + 100건 발행 중 기존 `redisTemplate` 성능 측정:

| 항목 | Baseline (Stream 없음) | With Stream (32 subs) | 배율 |
|------|:---:|:---:|:---:|
| SET+GET+DEL 평균 | 114ms | 2,137ms | **18.6x** |

> 출처: [multiplexing-test-result](./redis-stream-multiplexing-test-result.md) 3절

### 7.3 향후 개선 경로: 커넥션 풀 도입

커넥션 풀 도입 시 성능 개선 효과 (테스트 결과):

| Subscription 수 | 멀티플렉싱 (non-blocking) | 커넥션 풀 (BLOCK 실패) | 개선율 |
|:---:|:---:|:---:|:---:|
| 1 | 107ms | 66ms | 1.6x |
| 4 | 245ms | 70ms | 3.5x |
| 8 | 428ms | 67ms | 6.4x |
| 16 | 761ms | 64ms | 11.9x |
| 32 | 704ms | 64ms | 11.0x |

> 출처: [standalone-test-result](./redis-stream-standalone-test-result.md) 4절

커넥션 풀 도입 시 변경 사항:
- `LettuceClientConfiguration` → `LettucePoolingClientConfiguration` + `commons-pool2`
- `ReadFrom.REPLICA_PREFERRED` → `ReadFrom.UPSTREAM` (커넥션 풀에서는 쓰기 전용이 안전)
- `RedisStreamProperties`에 `connection.pool.*` 프로퍼티 추가
- `PromotionStreamManager`에서 Promotion별 동적 ConnectionFactory 생성 복원

→ 팀 내부 논의 후, 운영 환경 성능 테스트 결과를 확인하고 도입 여부를 결정한다.

---

## 8. 기존 `RedisTemplateConfig` 수정 사항

Stream 전용 `streamRedisConnectionFactory` Bean이 추가되므로, 기존 `redisConnectFactory`에 `@Primary`를 추가하여 Bean 충돌을 방지한다.

```kotlin
// RedisTemplateConfig.kt — @Primary 추가
@Bean
@Primary
fun redisConnectFactory(): RedisConnectionFactory? {
    // ... 기존 코드 동일 ...
}
```

`@Primary`를 추가하면:
- Spring Session, Spring Data Redis Repository, 캐시 등 `RedisConnectionFactory` 자동 주입 시 기존 팩토리 사용
- Stream 관련 코드에서는 `@Qualifier("streamRedisConnectionFactory")`로 명시적 주입

---

## 9. 실제 구현 범위

이 문서를 기반으로 구현할 파일:

| # | 파일 | 작업 |
|---|------|------|
| 1 | `RedisStreamConfig.kt` (신규) | Stream 전용 ConnectionFactory + StringRedisTemplate |
| 2 | `RedisStreamProperties.kt` (신규) | `@ConfigurationProperties(prefix = "redis.stream")` |
| 3 | `RedisTemplateConfig.kt` (수정) | `@Primary` 추가 |
| 4 | `redis.yml` (수정) | `redis.stream.*` 프로퍼티 추가 |
| 5 | `PromotionStreamManager.kt` (신규) | `pollTimeout(Duration.ZERO)`, 공유 ConnectionFactory 사용 |
| 6 | 기타 architecture.md 컴포넌트 | 기존 설계 유지 (Producer, Consumer, Registry) |

> 이번 문서는 **인프라 구성(ConnectionFactory, Container 설정)** 에 집중한다.
> 비즈니스 로직(Producer, Consumer, Registry, Kafka Listener 변경)은 Phase 2~5 상세 문서를 참고한다.

---

## 10. 검증 방법

문서 작성 후 팀원과 리뷰:

1. **ConnectionFactory 분리 방식이 적절한지**
   - 기존 `redisConnectFactory`와 `streamRedisConnectionFactory` 공존
   - `@Primary` + `@Qualifier` 패턴으로 Bean 충돌 방지
2. **non-blocking polling의 tight loop 부하가 수용 가능한지**
   - 운영 환경(VPC 내부)에서의 실측 필요
   - 필요 시 커스텀 poll loop 구현
3. **커넥션 풀 도입 시점**
   - 운영 환경 성능 테스트 후 결정
   - 멀티플렉싱에서 커넥션 풀로의 전환 경로 확인 (7.3절)

---

## 11. 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`redis-stream-development-plan.md`](./redis-stream-development-plan.md) | 전체 개발 계획 및 아키텍처 개요 |
| [`redis-stream-multiplexing-test-result.md`](./redis-stream-multiplexing-test-result.md) | 멀티플렉싱 단일 커넥션 테스트 결과 (non-blocking polling 성능, 공존 테스트) |
| [`redis-stream-standalone-test-result.md`](./redis-stream-standalone-test-result.md) | StandaloneConfiguration XREADGROUP BLOCK 근본 원인 분석 (커넥션 풀 성능 비교) |
