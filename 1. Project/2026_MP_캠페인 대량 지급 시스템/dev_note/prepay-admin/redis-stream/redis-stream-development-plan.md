# Redis Stream 프로모션 병렬 처리 개발 계획

## 개요

### 배경

현재 캠페인 프로모션 처리(Voucher/Point)는 Kafka Consumer가 1건씩 순차 처리하며, 100만건 기준 약 13.9시간이 소요된다.
Kafka → Redis Stream → 병렬 Consumer 아키텍처를 6단계(Phase)로 나누어 구현하여 **100만건을 20~30분 내에 처리**하는 것이 목표이다.

### 인프라 결정 사항 요약

| 항목 | 결정 | 근거                                                 |
|------|------|----------------------------------------------------|
| polling 방식 | **non-blocking** (`pollTimeout(Duration.ZERO)`) | ElastiCache Valkey가 신규 커넥션의 `XREADGROUP BLOCK`을 거부 |
| 커넥션 구성 | **멀티플렉싱 단일 커넥션** (커넥션 풀 없음) | 커넥션 풀 도입은 추후 개발 예정(테스트 비교하여 팀 공유 예정)               |
| ConnectionFactory | Stream 전용 별도 ConnectionFactory | Serializer 불일치, 관심사 분리                             |
| ACK 방식 | 수동 ACK (`receive`) | Voucher/Point 발급은 금전적 처리이므로 메시지 유실 불가              |

### 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kafka Cluster                                │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐                 │
│   │ Part.0  │ │ Part.1  │ │ Part.2  │ │ Part.3  │                 │
│   └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘                 │
└────────┼───────────┼───────────┼───────────┼───────────────────────┘
         │           │           │           │
         ▼           ▼           ▼           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Inbound Layer (Kafka Listeners)                   │
│                                                                     │
│   CampaignVoucherPromotionListener / CampaignPointPromotionListener │
│   └── processor.processTopicMessage(json)                            │
│       - enabled=true  → 상태확인 → 결과저장 → Stream enqueue (XADD)  │
│       - enabled=false → 상태확인 → 결과저장 → Money API (기존 직접처리)│
│                                                                     │
│   CampaignPromotionStartedListener (enabled=true 전용)              │
│   └── streamManager.startConsumers() → Consumer 자동 기동            │
└────────────────────────────┬────────────────────────────────────────┘
                             │ XADD
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Redis Stream                                      │
│                                                                     │
│   Stream Key: campaign-promotion-{id}:voucher:stream                │
│   Consumer Group: campaign-promotion-{id}-voucher-group             │
│                                                                     │
│   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐         │
│   │ Entry1 │→│ Entry2 │→│ Entry3 │→│  ...   │→│ EntryN │         │
│   └────────┘ └────────┘ └────────┘ └────────┘ └────────┘         │
└────────────────────────────┬────────────────────────────────────────┘
                             │ XREADGROUP (non-blocking, 수동 ACK)
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│          Processing Layer (StreamMessageListenerContainer)           │
│                                                                     │
│   PromotionConsumerRegistry                                         │
│   ├── Promotion A                                                   │
│   │   ├── Container (StreamMessageListenerContainer)                │
│   │   │   ├── Subscription-0 → PromotionStreamConsumer.onMessage() │
│   │   │   ├── Subscription-1 → PromotionStreamConsumer.onMessage() │
│   │   │   └── Subscription-N → PromotionStreamConsumer.onMessage() │
│   │   └── 공유 streamRedisConnectionFactory (멀티플렉싱)              │
│   ├── Promotion B                                                   │
│   │   └── ...                                                       │
│   └── @PreDestroy → shutdownAll()                                   │
│                                                                     │
│   PromotionStreamConsumer.onMessage(MapRecord)                      │
│   └── Processor.processStreamMessage(json)                           │
│       → findResult → isAlreadyProcessed 체크 → Money API → 결과 업데이트│
└─────────────────────────────────────────────────────────────────────┘
```

| 계층 | 역할 | 스케일링 |
|------|------|---------|
| **Inbound Layer** | Kafka 메시지 수신 → `processTopicMessage()`: 상태 확인, 결과 저장, Stream 발행 (XADD) | Kafka 파티션 수에 종속 (4개) |
| **Redis Stream** | 메시지 버퍼링, Consumer Group 기반 분배 | N/A (인프라) |
| **Processing Layer** | `StreamMessageListenerContainer` 기반 병렬 소비 → `processStreamMessage()`: Money API 호출 + 결과 업데이트 | **Consumer(Subscription) 수 동적 조절 가능** |

---

## Phase 요약

| Phase | 내용 | 상세 문서 |
|:---:|------|----------|
| 1 | 인프라 환경 구성 & 테스트 | [phase1-redis-stream-infrastructure.md](./phase1-redis-stream-infrastructure.md) |
| 2 | Consumer 구현 & 다중 Consumer 수신 테스트 | [phase2-redis-stream-consumer.md](./phase2-redis-stream-consumer.md) |
| 3 | Producer 구현 & Producer→Consumer 연동 테스트 | [phase3-redis-stream-producer.md](./phase3-redis-stream-producer.md) |
| 4 | Consumer 동적 생성/파괴 & 테스트 | [phase4-redis-stream-manager.md](./phase4-redis-stream-manager.md) |
| 5 | Kafka Listener 연동 (PromotionStartedListener) | [phase5-kafka-listener-integration.md](./phase5-kafka-listener-integration.md) |
| 6-1 | Processor 리팩토링 — `processTopicMessage()` (Kafka Listener 경로) | [phase6-processor-refactoring.md](./phase6-processor-refactoring.md#4-phase-6-1-processtopicmessage--kafka-listener-경로) |
| 6-2 | Processor 리팩토링 — `processStreamMessage()` (Stream Consumer 경로) | [phase6-processor-refactoring.md](./phase6-processor-refactoring.md#5-phase-6-2-processstreammessage--stream-consumer-경로) |

---

## Phase 1: 인프라 환경 구성 & 테스트

**목표**: Stream 전용 ConnectionFactory, Container 설정, 프로퍼티를 구성하고 Redis Stream 연결이 정상 동작하는지 검증한다.

**주요 컴포넌트**:
- `RedisStreamConfig` — Stream 전용 ConnectionFactory + StringRedisTemplate
- `RedisStreamProperties` — `@ConfigurationProperties(prefix = "redis.stream")`
- `RedisTemplateConfig` 수정 — `@Primary` 추가 (Bean 충돌 방지)
- `redis.yml` 수정 — `redis.stream.*` 프로퍼티 추가

**상세 문서**: [phase1-redis-stream-infrastructure.md](./phase1-redis-stream-infrastructure.md)

---

## Phase 2: Consumer 구현 & 다중 Consumer 수신 테스트

**목표**: `PromotionStreamConsumer`를 구현하고, Container에 다중 Subscription을 등록하여 메시지 수신이 정상 동작하는지 검증한다.

**주요 컴포넌트**:
- `PromotionStreamConsumer` — `StreamListener<String, MapRecord<String, String, String>>` 구현
  - `onMessage()` → `Processor.processStreamMessage()` 호출 (Phase 6에서 리네이밍)
  - 수동 ACK (`acknowledge()`) 처리
- `StreamMessageListenerContainer` 수동 생성 및 Subscription 등록
- 다중 Subscription 수신 검증 (동일 Consumer Group 내 메시지 분배 확인)

---

## Phase 3: Producer 구현 & Producer→Consumer 연동 테스트

**목표**: `PromotionStreamProducer`를 구현하고, Producer가 발행한 메시지를 Consumer가 정상적으로 수신·처리하는 연동 흐름을 검증한다.

**주요 컴포넌트**:
- `PromotionStreamProducer` — Redis Stream에 XADD 발행
  - `enqueue(streamKey, key, message)` → `XADD` + `MAXLEN ~` trim
- Producer → Consumer 연동 테스트 (발행 → 수신 → 처리 → ACK 전체 흐름)

---

## Phase 4: Consumer 동적 생성/파괴 & 테스트

**목표**: Promotion별로 Container를 동적으로 생성/파괴하는 오케스트레이터를 구현하고, Consumer 수를 totalCount 기반으로 동적 결정하는 로직을 검증한다.

**주요 컴포넌트**:
- `PromotionStreamManager` — 오케스트레이터
  - `startConsumers(promotionId, totalCount, type)` — Container 동적 생성, Subscription 등록, Registry 등록
  - `stopConsumers(promotionId)` — Subscription 취소, Container 중지, Stream 정리
  - `calculateConsumerCountPerInstance(totalCount, maxConsumerPerInstance)` — Consumer 수 동적 계산
- `PromotionConsumerRegistry` — Promotion별 Container 컨텍스트 관리
  - `register()`, `shutdown()`, `shutdownAll()` (`@PreDestroy`)
  - `cleanupStream()` — 다중 인스턴스 환경에서 안전한 Stream/ConsumerGroup 정리

---

## Phase 5: Kafka Listener 연동 (PromotionStartedListener)

**목표**: 신규 Kafka 이벤트(`prepay-campaign-promotion-started`)로 Consumer를 자동 기동하는 Listener를 구현한다.

**주요 컴포넌트**:
- `CampaignPromotionStartedListener` — `@ConditionalOnProperty(redis.stream.enabled=true)`
  - 이벤트 수신 → `PromotionStreamManager.startConsumers()` 호출
  - 인스턴스별 고유 groupId (hostname-pid 기반 브로드캐스트)
  - `@Retryer` 적용 (팀 공통 규칙)
- `PromotionStartedMessage` DTO — `promotionId`, `totalCount`, `type`
- `kafka.yml` — `campaign-promotion-started` 토픽 추가
- Kafka Listener(Voucher/Point)는 변경하지 않음 — enqueue는 Phase 6에서 Processor 내부로 이동

**상세 문서**: [phase5-kafka-listener-integration.md](./phase5-kafka-listener-integration.md)

---

## Phase 6: Processor 리팩토링 — Stream Enqueue 및 Money API 분리

**목표**: `AbstractCampaignPromotionProcessor.process()`를 리팩토링하여, `saveResult()` 이후 Stream enqueue와 Money API 호출을 분리한다.

변경 범위가 크므로 **Kafka 경로 / Stream 경로** 기준으로 2단계로 분리하여 개발한다.

### Phase 6-1: processTopicMessage() — Kafka Listener 경로

- `process()` → `processTopicMessage()` 리네이밍
- `executeMoneyApi()` 공통 로직 추출
- stream enqueue 분기 (`enabled` 플래그)
- 추상 메서드 2개: `getPromotionTypeEnum()`, `getPartitionKey()`
- Voucher/Point Processor: 생성자 파라미터 추가, 추상 메서드 2개 구현
- Kafka Listener: `process()` → `processTopicMessage()` 호출 변경
- 순환 의존성 방지: `PromotionStreamManager` 대신 `PromotionStreamProducer` 직접 주입

### Phase 6-2: processStreamMessage() — Stream Consumer 경로

- `processStreamMessage()` 신규 메서드 (Phase 6-1의 `executeMoneyApi()` 재사용)
- 추상 메서드 2개: `findResult()`, `isAlreadyProcessed()`
- Voucher/Point Processor: 추상 메서드 2개 구현
- `PromotionStreamConsumer`: `process()` → `processStreamMessage()` 호출 변경

**상세 문서**: [phase6-processor-refactoring.md](./phase6-processor-refactoring.md)

---

## 근거 문서 링크

| 문서 | 내용 |
|------|------|
| [`redis-stream-standalone-test-result.md`](./redis-stream-standalone-test-result.md) | StandaloneConfiguration XREADGROUP BLOCK 근본 원인 분석 |
| [`redis-stream-standalone-test.md`](./redis-stream-standalone-test.md) | Standalone 테스트 프롬프트 |
| [`redis-stream-multiplexing-test-result.md`](./redis-stream-multiplexing-test-result.md) | 멀티플렉싱 단일 커넥션 테스트 결과 (non-blocking polling 성능) |
| [`redis-stream-multiplexing-test.md`](./redis-stream-multiplexing-test.md) | 멀티플렉싱 테스트 프롬프트 |
