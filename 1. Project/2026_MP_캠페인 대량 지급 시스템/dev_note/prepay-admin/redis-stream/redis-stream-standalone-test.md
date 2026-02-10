# StandaloneConfiguration XREADGROUP BLOCK 검증 테스트

## 배경

[멀티플렉싱 단일 커넥션 테스트](./redis-stream-multiplexing-test-result.md)에서
기존 `RedisStaticMasterReplicaConfiguration` 경유 `XREADGROUP BLOCK`이
ElastiCache Valkey 엔진에서 `ERR [ENGINE] Invalid command`로 거부되는 것을 확인하였다.

`StaticMasterReplicaConnection`의 라우팅/핸드셰이크 과정이 원인으로 추정되므로,
라우팅 레이어가 없는 `RedisStandaloneConfiguration`으로 Master에 직접 연결하면
`XREADGROUP BLOCK`이 정상 동작하는지 검증한다.

## 테스트 환경

| 항목 | 값 |
|------|-----|
| Redis | Valkey 7.2.6 on Amazon ElastiCache (ap-northeast-2) |
| 접속 경로 | 로컬 VPN 경유 (`127.0.0.1:40198` → 개발 ElastiCache) |
| 클라이언트 | Lettuce 6.4.2 (Spring Boot 3.4.3 / Spring Data Redis) |
| 기존 ConnectionFactory | `RedisStaticMasterReplicaConfiguration` + `ReadFrom.REPLICA_PREFERRED` + RESP2 |
| 테스트 ConnectionFactory | `RedisStandaloneConfiguration` + `LettucePoolingClientConfiguration` + RESP2 |

## 핵심 검증 포인트

`RedisStandaloneConfiguration`으로 연결하면 `StatefulRedisMasterReplicaConnection` 라우팅 레이어를
거치지 않고 `StatefulRedisConnection`으로 직접 연결된다.
이 경로에서 `XREADGROUP BLOCK`이 ElastiCache Valkey에서 정상 동작하는지 확인한다.

```
기존 (실패):
  LettuceConnectionFactory
    └── StatefulRedisMasterReplicaConnection (라우팅 레이어)
          └── XREADGROUP BLOCK → ERR [ENGINE] Invalid command

검증 대상 (성공 기대):
  LettuceConnectionFactory
    └── StatefulRedisConnection (직접 연결)
          └── XREADGROUP BLOCK → 정상 동작?
```

## 테스트 구성

### TestConfiguration

```kotlin
@TestConfiguration
class StandaloneConnectionTestConfig {

    @Bean
    fun standaloneRedisConnectionFactory(
        @Value("\${redis.master.host}") host: String,
        @Value("\${redis.master.port}") port: Int,
    ): LettuceConnectionFactory {
        val standaloneConfig = RedisStandaloneConfiguration(host, port)

        val poolConfig = GenericObjectPoolConfig<Any>().apply {
            maxTotal = 10
            maxIdle = 5
            minIdle = 0
        }

        val clientConfig = LettucePoolingClientConfiguration.builder()
            .poolConfig(poolConfig)
            .clientOptions(
                ClientOptions.builder()
                    .autoReconnect(true)
                    .protocolVersion(ProtocolVersion.RESP2)
                    .build()
            )
            .commandTimeout(Duration.ofSeconds(10))
            .build()

        return LettuceConnectionFactory(standaloneConfig, clientConfig).apply {
            afterPropertiesSet()
        }
    }

    @Bean
    fun standaloneStreamRedisTemplate(
        standaloneRedisConnectionFactory: LettuceConnectionFactory,
    ): StringRedisTemplate = StringRedisTemplate(standaloneRedisConnectionFactory)
}
```

기존 멀티플렉싱 테스트(`StreamMultiplexingTestConfig`)와의 차이:

| 항목 | 멀티플렉싱 테스트 | Standalone 테스트 |
|------|----------------|-----------------|
| Configuration | `RedisStaticMasterReplicaConfiguration` (기존 `redisConnectFactory` 재사용) | `RedisStandaloneConfiguration` (신규 생성) |
| Connection Pool | 없음 (멀티플렉싱) | `LettucePoolingClientConfiguration` + `commons-pool2` |
| ReadFrom | `REPLICA_PREFERRED` | 없음 (Standalone은 라우팅 불필요) |
| 커넥션 타입 | `StatefulRedisMasterReplicaConnection` | `StatefulRedisConnection` |

### 시나리오 1: Stream 명령 호환성 진단

멀티플렉싱 테스트와 동일한 진단을 수행하여 비교한다.

```kotlin
@Test
@Order(1)
fun `진단 - StandaloneConfiguration에서 Stream 명령 호환성`() {
    // Step 1: ConnectionFactory 타입 확인
    // Step 2: XADD
    // Step 3: XLEN
    // Step 4: XREADGROUP (non-block)
    // Step 5: XREADGROUP BLOCK 100ms  ← 핵심 검증
    // Step 6: SET / GET / DEL
}
```

**기대 결과:**

| 명령 | StaticMasterReplica (기존) | Standalone (검증 대상) |
|------|:---:|:---:|
| `XADD` | OK | OK |
| `XLEN` | OK | OK |
| `XREADGROUP` (non-block) | OK | OK |
| `XREADGROUP BLOCK` | ERR | **OK (기대)** |
| `SET` / `GET` / `DEL` | OK | OK |

### 시나리오 2: Blocking polling 메시지 수신

`XREADGROUP BLOCK`이 동작한다면, `StreamMessageListenerContainer`에서 `pollTimeout > 0`으로
blocking polling 메시지 수신이 가능한지 확인한다.

```kotlin
@Test
@Order(2)
fun `Blocking polling으로 메시지 수신`() {
    val options = StreamMessageListenerContainerOptions.builder()
        .pollTimeout(Duration.ofMillis(2000))  // XREADGROUP BLOCK 2000
        .batchSize(10)
        .build()

    val container = StreamMessageListenerContainer
        .create(standaloneRedisConnectionFactory, options)

    // Consumer 1개 등록, 메시지 10건 발행, 10건 수신 확인
}
```

### 시나리오 3: Blocking polling 중 다른 Redis 명령 응답시간

BLOCK 대기 중 동일 ConnectionFactory(Pool)에서 다른 Redis 명령이 정상 동작하는지 확인한다.
커넥션 풀을 사용하므로 BLOCK이 다른 명령을 차단하지 않아야 한다.

```kotlin
@Test
@Order(3)
fun `Blocking polling 중 다른 Redis 명령 응답시간`() {
    // Container 시작 (pollTimeout=2000ms, BLOCK 모드)
    // polling 중 SET+GET 10회 측정
    // Pool에서 별도 커넥션을 할당하므로 BLOCK 영향 없어야 함
}
```

### 시나리오 4: 다중 Subscription blocking polling

Container 1개에 N개 Subscription을 등록하고 blocking polling으로 메시지 수신 및 성능을 측정한다.
멀티플렉싱 테스트의 non-blocking 결과와 비교한다.

```kotlin
@ParameterizedTest
@ValueSource(ints = [1, 2, 4, 8, 16, 32])
fun `Subscription N개에서 blocking polling 메시지 수신 + 다른 명령 응답시간`(subscriptionCount: Int) {
    // Pool maxTotal = subscriptionCount + 4
    // pollTimeout = 2000ms (BLOCK 모드)
    // 메시지 100건 발행
    // SET+GET 10회 측정
}
```

**비교 기준 (멀티플렉싱 non-blocking 결과):**

| Subscription 수 | non-blocking SET+GET 평균 | blocking SET+GET 평균 (기대) |
|:---:|:---:|:---:|
| 1 | 107ms | < 107ms |
| 32 | 704ms | < 704ms |

커넥션 풀 사용 시 BLOCK이 별도 커넥션에서 실행되므로,
Subscription 수 증가에 따른 다른 명령 응답시간 저하가 크게 줄어들 것으로 기대한다.

## 판정 기준

| 케이스 | 조건 | 판정 |
|--------|------|------|
| **Case A**: BLOCK 정상 동작 + 성능 양호 | `XREADGROUP BLOCK` 성공 + 32 sub에서 SET+GET < 300ms | `StandaloneConfiguration` 채택 |
| **Case B**: BLOCK 정상 동작 + 성능 저하 | `XREADGROUP BLOCK` 성공 + 32 sub에서 SET+GET >= 300ms | Pool 사이징 조정 후 재검증 |
| **Case C**: BLOCK 여전히 실패 | `ERR [ENGINE] Invalid command` 동일 | non-blocking polling 또는 다른 대안 검토 |

## 테스트 코드 위치

```
src/test/kotlin/.../campaign/infrastructure/redis/stream/
├── StreamMultiplexingTestConfig.kt          ← 기존 (멀티플렉싱)
├── SingleSubscriptionTest.kt               ← 기존
├── MultipleSubscriptionTest.kt             ← 기존
├── CoexistenceTest.kt                      ← 기존
├── StandaloneConnectionTestConfig.kt       ← 신규 (Standalone + Pool)
└── StandaloneBlockTest.kt                  ← 신규 (BLOCK 검증)
```

## 재현 방법

```bash
# 로컬 VPN으로 개발 Redis 연결 후
./gradlew test --tests "*StandaloneBlockTest" --info
```
