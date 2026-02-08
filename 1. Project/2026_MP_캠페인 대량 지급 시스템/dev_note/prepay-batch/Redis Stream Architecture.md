# Redis Stream 기반 병렬 처리 아키텍처 설계  
  
## 목차  
  
1. [개요](#1-개요)  
2. [인프라 환경](#2-인프라-환경)  
3. [현재 아키텍처 분석](#3-현재-아키텍처-분석)  
4. [목표 아키텍처](#4-목표-아키텍처)  
5. [컴포넌트 상세 설계](#5-컴포넌트-상세-설계)  
6. [처리 흐름 상세](#6-처리-흐름-상세)  
7. [장애 처리 설계](#7-장애-처리-설계)  
8. [Stream 관리 정책](#8-stream-관리-정책)  
9. [설정 설계](#9-설정-설계)  
10. [성능 추정](#10-성능-추정)  
11. [모니터링](#11-모니터링)  
12. [마이그레이션 전략](#12-마이그레이션-전략)  
  
---  
  
## 1. 개요  
  
### 1.1 배경  
  
현재 캠페인 프로모션 처리(Voucher/Point)는 Kafka Consumer가 메시지를 1건씩 순차 처리하고 있다.  
메시지 1건당 ~200ms가 소요되며, 100만건 처리 시 약 13.9시간이 걸리는 구조이다.  
  
### 1.2 목표  
  
| 항목 | 현재 | 목표 |  
|------|------|------|  
| 1건 처리 시간 | ~200ms | ~200ms (변동 없음) |  
| 초당 처리량 (4 파티션) | ~20건/s | ~640건/s 이상 |  
| 100만건 처리 시간 | ~13.9시간 | **20~30분** |  
  
### 1.3 설계 원칙  
  
- **Kafka는 메시지 전달 보장 역할만** 수행한다  
- **처리 계층은 Kafka와 분리**하여 독립적으로 동적 스케일링한다  
- 기존 인프라(Kafka + Redis)만 사용한다  
- 기존 프로세서 로직(`AbstractCampaignPromotionProcessor`)의 변경을 최소화한다  
  
### 1.4 기술 스택  
  
| 항목 | 버전/상세 |  
|------|----------|  
| Spring Boot | 3.4.3 |  
| Java | 21 (Virtual Threads 사용 가능) |  
| Kotlin | 2.1.0 |  
| Spring Data Redis | spring-boot-starter-data-redis (Lettuce) |  
| Redis(Valkey) | AWS ElastiCache Valkey 7.2.6, Standalone, Master-Replica, RESP2 |  
| Kafka | spring-kafka, Manual ACK |  
  
---  
  
## 2. 인프라 환경  
  
### 2.1 AWS ElastiCache (Valkey) 서버 정보  
  
```  
Server:  
  engine:           Valkey 7.2.6 (Redis 7.2.4 호환)  
  platform:         Amazon ElastiCache  
  region/az:        ap-northeast-2a (Seoul)  
  mode:             standalone (non-cluster)  
  architecture:     ARM (Graviton)  
  protocol:         RESP2  
  uptime:           387 days  
```  
  
### 2.2 Valkey 호환성  
  
Valkey는 Redis 7.2 기반의 오픈소스 포크로, Redis Streams 관련 모든 명령어를 완벽히 지원한다.  
  
| 명령어 | 지원 여부 | 비고 |  
|--------|:-:|------|  
| XADD | O | Stream entry 추가 |  
| XREAD / XREADGROUP | O | Consumer Group 읽기 |  
| XACK | O | 메시지 확인 |  
| XPENDING | O | Pending 조회 |  
| XCLAIM / XAUTOCLAIM | O | 메시지 소유권 이전 |  
| XTRIM | O | Stream 트리밍 |  
| XINFO | O | Stream/Group 정보 조회 |  
| XGROUP CREATE | O | Consumer Group 생성 |  
  
> Valkey 7.2는 Redis 7.2 API와 완전 호환되므로 Spring Data Redis(Lettuce)로 그대로 사용 가능하다.  
> 별도의 Valkey 전용 드라이버나 설정 변경은 필요하지 않다.  
  
### 2.3 ElastiCache 환경 제약사항  
  
#### 제한되는 명령어  
  
ElastiCache 관리형 서비스 특성상 일부 관리 명령어가 제한된다.  
  
| 제한 명령어 | 대안 |  
|-----------|------|  
| `CONFIG SET` | **ElastiCache Parameter Group**에서 설정 변경 |  
| `DEBUG` | 사용 불가 |  
| `BGSAVE` / `BGREWRITEAOF` | ElastiCache가 자동 관리 |  
| `SLAVEOF` / `REPLICAOF` | ElastiCache가 자동 관리 |  
| `CLUSTER` | Standalone 모드에서는 해당 없음 |  
  
> **Stream 관련 명령어는 모두 사용 가능하다.** 제한되는 것은 서버 관리 명령어뿐이다.  
  
#### Standalone 모드 고려사항  
  
```  
┌──────────────────────────┐  
│  ElastiCache (Standalone) │  
│  ap-northeast-2a          │  
│                           │  
│  ┌─────────┐  ┌────────┐ │  
│  │ Primary │─→│Replica │ │  
│  │ (Write) │  │ (Read) │ │  
│  └─────────┘  └────────┘ │  
└──────────────────────────┘  
```  
  
| 항목 | 상세 |  
|------|------|  
| **메모리 한계** | 단일 노드의 메모리가 상한 (노드 타입에 따라 다름) |  
| **쓰기 확장 불가** | 모든 XADD/XACK는 Primary 노드에서만 처리 |  
| **읽기 분산** | Replica에서 읽기 가능 (현재 설정: `REPLICA_PREFERRED`) |  
| **Failover** | Primary 장애 시 Replica가 승격, Stream 데이터 보존 |  
  
#### maxmemory-policy 설정 (필수 확인)  
  
```  
⚠️ 중요: ElastiCache Parameter Group에서 maxmemory-policy 확인 필요  
```  
  
| 정책 | Stream과의 호환성 |  
|------|:-:|  
| `noeviction` | **권장** - 메모리 초과 시 쓰기 에러 반환, 데이터 유실 없음 |  
| `volatile-lru` | 주의 - TTL 설정된 키만 제거, Stream에 TTL 없으면 안전 |  
| `allkeys-lru` | **위험** - Stream 키가 LRU에 의해 삭제될 수 있음 |  
| `volatile-ttl` | 주의 - TTL 기반 제거 |  
  
> **Stream을 사용하려면 `noeviction` 또는 `volatile-lru` 정책이어야 한다.**  
> 현재 ElastiCache Parameter Group의 `maxmemory-policy`를 반드시 확인하고,  
> `allkeys-lru`인 경우 `noeviction`으로 변경해야 한다.  
>  
> 변경 방법: AWS Console → ElastiCache → Parameter Groups → 해당 그룹 편집 → `maxmemory-policy` 변경  
  
#### ElastiCache 노드 타입별 메모리  
  
| 노드 타입 | 메모리 | Stream 100만건 수용 | 비고 |  
|----------|--------|:-:|------|  
| cache.r7g.large | 13.07 GB | O | 여유 있음 |  
| cache.r7g.xlarge | 26.32 GB | O | 충분 |  
| cache.m7g.large | 6.38 GB | O | 가능하나 모니터링 필요 |  
| cache.m7g.xlarge | 12.93 GB | O | 여유 있음 |  
| cache.t4g.medium | 3.09 GB | 주의 | Session + Stream 동시 사용 시 빠듯할 수 있음 |  
  
> 현재 노드 타입을 확인하여 Stream 사용에 따른 메모리 여유분을 산정해야 한다.  
> 기존 용도(Spring Session, 캐시 등)와 Stream이 메모리를 공유하므로,  
> **Stream에 할당 가능한 메모리 = 전체 메모리 - 기존 사용량 - 여유분(20%)** 으로 계산한다.  
  
### 2.4 XREADGROUP BLOCK과 Replica 읽기 관련 주의사항  
  
현재 Lettuce 설정이 `REPLICA_PREFERRED`로 되어 있다.  
  
```kotlin  
// 현재 RedisTemplateConfig 설정  
.readFrom(ReadFrom.REPLICA_PREFERRED)  
```  
  
**Stream 명령어의 읽기/쓰기 분류:**  
  
| 명령어 | 유형 | 실행 노드 |  
|--------|------|----------|  
| XADD | Write | Primary |  
| XACK | Write | Primary |  
| XCLAIM | Write | Primary |  
| XTRIM | Write | Primary |  
| XREADGROUP (>) | **Write** | **Primary** (Consumer Group 상태 변경) |  
| XREADGROUP (0) | Read | Replica 가능하나 Primary 권장 |  
| XRANGE / XLEN | Read | Replica 가능 |  
| XPENDING / XINFO | Read | Replica 가능 |  
  
> **`XREADGROUP ... >` 는 Consumer Group의 `last_delivered_id`를 변경하므로 Write 명령으로 분류된다.**  
> Lettuce는 이를 인식하여 `REPLICA_PREFERRED` 설정에서도 Primary로 라우팅한다.  
> 따라서 **기존 `RedisTemplateConfig`의 `ReadFrom.REPLICA_PREFERRED` 설정은 변경하지 않는다.**  
>  
> 단, Stream 전용 `StreamRedisConfig`에서는 **`ReadFrom.UPSTREAM`(Primary only)** 을 사용하여  
> 모든 Stream 명령어를 Primary에서 실행하도록 명시적으로 설정한다. (9.4절 참고)  
  
### 2.5 ElastiCache 연결 수 고려  
  
Worker가 많아지면 Redis 연결 수가 증가한다. ElastiCache 노드별 최대 연결 수를 확인해야 한다.  
  
```  
ElastiCache 기본 maxclients = 65,000  
  
연결 사용처 (기존 + Stream):  
├── [기존] Spring Session / 캐시         ~20 connections (멀티플렉싱, 소량)  
├── [Stream] Connection Pool             최대 80 connections (pool.max-total)  
│   ├── Stream Workers (Voucher)         ~32 connections (BLOCK으로 점유)  
│   ├── Stream Workers (Point)           ~32 connections (BLOCK으로 점유)  
│   ├── Publisher (XADD)                 ~4 connections  
│   └── Background (XCLAIM, XTRIM 등)    ~4 connections  
└── 합계                                 ~100 connections/인스턴스  
  
4 인스턴스 기준: ~400 connections (65,000 대비 충분)  
```  
  
> **중요: `XREADGROUP BLOCK`은 연결을 점유하므로 커넥션 풀이 필수이다.**  
> Lettuce 기본 단일 연결 멀티플렉싱으로는 BLOCK 명령어를 사용할 수 없다.  
> Stream 전용 `LettuceConnectionFactory`를 커넥션 풀 모드로 생성해야 한다.  
> (상세 설정은 9.4절 참고)  
  
---  
  
## 3. 현재 아키텍처 분석  
  
### 3.1 처리 흐름  
  
```  
Kafka (4 partitions)  
    │  
    ▼  
CampaignVoucherPromotionListener     (1건씩 순차 처리)  
    │  
    ▼  
AbstractCampaignPromotionProcessor.process(json)  
    ├── 1. parseJsonMessage()                      ~1ms  
    ├── 2. isPromotionInProgress() [Redis/DB]      ~5-10ms  
    ├── 3. saveResult() [DB INSERT, REQUIRES_NEW]  ~30-50ms  
    ├── 4. callMoneyApi() [Feign HTTP POST]        ~100-150ms  ← 주 병목  
    └── 5. updateSuccess() [DB UPDATE + Event]     ~20-40ms  
                                             합계: ~200ms/건  
```  
  
### 3.2 병목 원인  
  
| 원인 | 상세 |  
|------|------|  
| **순차 처리** | Kafka listener가 1건씩 동기 처리, 다음 메시지는 이전 처리 완료까지 대기 |  
| **Network I/O 블로킹** | Money API 호출(Feign)이 ~100-150ms 동안 스레드 블로킹 |  
| **스케일링 제한** | 파티션 수(4개) = 최대 Consumer 수, 그 이상 확장 불가 |  
  
---  
  
## 4. 목표 아키텍처  
  
### 4.1 전체 구조  
  
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
│                    Inbound Layer (Kafka Consumers)                   │  
│                                                                     │  
│   ┌──────────────────────────────────────────────────┐              │  
│   │  CampaignVoucherPromotionListener                │              │  
│   │  - Kafka 메시지 수신                               │              │  
│   │  - 유효성 검증 (key, message 존재 여부)              │              │  
│   │  - Redis Stream XADD                             │              │  
│   │  - Kafka ACK                                     │              │  
│   └──────────────────────────────────────────────────┘              │  
└────────────────────────────┬────────────────────────────────────────┘  
                             │ XADD  
                             ▼  
┌─────────────────────────────────────────────────────────────────────┐  
│                    Redis Stream                                      │  
│                                                                     │  
│   Stream Key: campaign:promotion:voucher:stream                     │  
│   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐         │  
│   │ Entry1 │→│ Entry2 │→│ Entry3 │→│  ...   │→│ EntryN │         │  
│   └────────┘ └────────┘ └────────┘ └────────┘ └────────┘         │  
│                                                                     │  
│   Consumer Group: campaign-voucher-worker-group                     │  
│   last_delivered_id: 1234567890-0                                   │  
│   PEL: [pending entries...]                                         │  
└────────────────────────────┬────────────────────────────────────────┘  
                             │ XREADGROUP (COUNT N, BLOCK)  
                             ▼  
┌─────────────────────────────────────────────────────────────────────┐  
│                Processing Layer (Stream Workers)                     │  
│                                                                     │  
│   StreamWorkerManager                                               │  
│   ├── Worker-1 (Virtual Thread) ──→ Processor.process()             │  
│   ├── Worker-2 (Virtual Thread) ──→ Processor.process()             │  
│   ├── Worker-3 (Virtual Thread) ──→ Processor.process()             │  
│   ├── ...                                                           │  
│   └── Worker-N (Virtual Thread) ──→ Processor.process()             │  
│                                                                     │  
│   ┌──────────────────────────────────────────────────┐              │  
│   │  특징:                                            │              │  
│   │  - Worker 수 동적 조절 가능                         │              │  
│   │  - 각 Worker가 chunk 단위로 XREADGROUP              │              │  
│   │  - 처리 완료 시 XACK                               │              │  
│   │  - 실패 시 PEL에 유지 → XAUTOCLAIM으로 재처리        │              │  
│   └──────────────────────────────────────────────────┘              │  
└─────────────────────────────────────────────────────────────────────┘  
```  
  
### 4.2 계층 역할 분리  
  
| 계층 | 역할 | 스케일링 |  
|------|------|---------|  
| **Inbound Layer** | Kafka 메시지 수신 → Redis Stream 발행 | Kafka 파티션 수에 종속 (4개) |  
| **Redis Stream** | 메시지 버퍼링, Consumer Group 기반 분배 | N/A (인프라) |  
| **Processing Layer** | 비즈니스 로직 병렬 실행 | **Worker 수 동적 조절 가능** |  
  
---  
  
## 5. 컴포넌트 상세 설계  
  
### 5.1 Lazy Lifecycle 개요  
  
대용량 프로모션 처리는 연중 몇 차례만 수행되므로, 평상시에는 리소스를 할당하지 않는다.  
Kafka 메시지가 최초 수신되는 시점에 Stream/Consumer Group/Worker를 동적으로 생성하고,  
처리가 완료되어 일정 시간 Idle 상태가 지속되면 Worker를 자동으로 종료한다.  
  
```  
┌─────────────────────────────────────────────────────────────────┐  
│                      Lifecycle State Machine                     │  
│                                                                 │  
│   ┌──────┐  첫 메시지 수신  ┌────────────┐  초기화 완료  ┌──────┐  │  
│   │ IDLE │───────────────→│ ACTIVATING │────────────→│ACTIVE│  │  
│   └──┬───┘                └────────────┘             └──┬───┘  │  
│      ▲                                                  │      │  
│      │          Idle Timeout (N분간 빈 Stream)           │      │  
│      └──────────────────────────────────────────────────┘      │  
│                                                                 │  
│   IDLE:       Worker 0개, Stream 미존재 가능, 리소스 할당 없음     │  
│   ACTIVATING: Stream 생성 + Consumer Group 생성 + Worker N개 시작 │  
│   ACTIVE:     Worker N개 가동, 메시지 처리 중                     │  
│   → IDLE:     Idle Timeout 도달 시 Worker 전체 종료              │  
└─────────────────────────────────────────────────────────────────┘  
```  
  
### 5.2 Stream Constants  
  
```kotlin  
object CampaignStreamConstants {  
    // Stream Keys  
    const val VOUCHER_STREAM_KEY = "campaign:promotion:voucher:stream"  
    const val POINT_STREAM_KEY = "campaign:promotion:point:stream"  
  
    // Consumer Group  
    const val VOUCHER_CONSUMER_GROUP = "campaign-voucher-worker-group"  
    const val POINT_CONSUMER_GROUP = "campaign-point-worker-group"  
  
    // Stream Fields  
    const val FIELD_KEY = "key"  
    const val FIELD_MESSAGE = "message"  
    const val FIELD_PUBLISHED_AT = "publishedAt"  
  
    // Dead Letter Stream  
    const val VOUCHER_DLQ_STREAM_KEY = "campaign:promotion:voucher:dlq"  
    const val POINT_DLQ_STREAM_KEY = "campaign:promotion:point:dlq"  
}  
```  
  
### 5.3 Inbound Layer - Kafka Listener 변경  
  
Kafka Listener는 메시지를 수신하면 `CampaignStreamOrchestrator`에 위임한다.  
Orchestrator가 내부적으로 Lazy Initialization과 Stream 발행을 모두 처리한다.  
  
```kotlin  
@Component  
class CampaignVoucherPromotionListener(  
    private val streamOrchestrator: CampaignStreamOrchestrator,  
    private val voucherProcessor: CampaignPromotionVoucherProcessor,  
    @Value("\${redis.stream.campaign-promotion.enabled:false}")  
    private val streamEnabled: Boolean  
) {  
    private val log = KotlinLogging.logger {}  
  
    companion object {  
        private const val LOG_PREFIX = "[CampaignPromotion]"  
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
  
        if (key.isBlank() || message.isBlank()) {  
            log.warn { "$LOG_PREFIX$COMPONENT Skipped - reason=missing key or message" }  
            return acknowledge.acknowledge()  
        }  
  
        if (streamEnabled) {  
            // 신규: Orchestrator가 lazy init + Stream 발행을 처리  
            streamOrchestrator.publishToStream(  
                streamType = StreamType.VOUCHER,  
                partitionKey = key,  
                message = message  
            )  
        } else {  
            // 기존: 직접 처리 (fallback)  
            voucherProcessor.process(message)  
        }  
  
        acknowledge.acknowledge()  
    }  
}  
```  
  
### 5.4 CampaignStreamOrchestrator (핵심 컴포넌트)  
  
Lazy Initialization, Stream 발행, Worker 라이프사이클, Scheduler, Idle Timeout을 총괄하는 컴포넌트이다.  
**Stream 타입별(Voucher/Point)로 독립적인 상태를 관리한다.**  
  
모든 백그라운드 스레드(Worker, Idle Monitor, Pending Recovery, Stream Trim)는  
Context 활성화 시 함께 시작되고, Idle Timeout 또는 앱 종료 시 함께 종료된다.  
  
```  
Context 활성화 시 시작되는 스레드:  
  
StreamContext (VOUCHER)  
├── Worker-0 ~ Worker-N     (Virtual Threads) - 메시지 처리  
├── idle-monitor            (Virtual Thread)  - Idle Timeout 감지  
├── pending-recovery        (Virtual Thread)  - XCLAIM 주기적 실행  
└── stream-trimmer          (Virtual Thread)  - XTRIM 주기적 실행  
  
→ deactivate() 호출 시 위 스레드 전부 종료  
→ 다음 메시지 수신 시 전부 재생성  
```  
  
```kotlin  
@Component  
class CampaignStreamOrchestrator(  
    @Qualifier("streamRedisTemplate")  
    private val redisTemplate: StringRedisTemplate,  
    private val workerManagerFactory: StreamWorkerManagerFactory,  
    private val streamProperties: CampaignStreamProperties,  
    private val workerProperties: CampaignStreamWorkerProperties,  
    private val streamDataSourceManager: StreamDataSourceManager  // DB Pool 동적 생성/삭제 (9.5절)  
) : DisposableBean {  
  
    private val log = KotlinLogging.logger {}  
  
    /**  
     * Stream 타입별 독립 상태 관리  
     * - ConcurrentHashMap + computeIfAbsent로 thread-safe lazy init  
     */  
    private val contexts = ConcurrentHashMap<StreamType, StreamContext>()  
  
    // ──────────────────────────────────────────────────────────────  
    // Public API  
    // ──────────────────────────────────────────────────────────────  
  
    /**  
     * Kafka Listener에서 호출하는 진입점.  
     * 최초 호출 시 Stream + Consumer Group + Workers + Schedulers를 생성한다.  
     */  
    fun publishToStream(streamType: StreamType, partitionKey: String, message: String) {  
        val context = getOrCreateContext(streamType)  
  
        val record = StreamRecords.string(  
            mapOf(  
                CampaignStreamConstants.FIELD_KEY to partitionKey,  
                CampaignStreamConstants.FIELD_MESSAGE to message,  
                CampaignStreamConstants.FIELD_PUBLISHED_AT to Instant.now().toEpochMilli().toString()  
            )  
        ).withStreamKey(context.streamKey)  
  
        val recordId = redisTemplate.opsForStream().add(record)  
            ?: throw StreamPublishException("Failed to publish to stream: ${context.streamKey}")  
  
        context.lastPublishTime.set(Instant.now())  
  
        log.debug { "[Orchestrator] Published to ${context.streamKey} - recordId=$recordId, key=$partitionKey" }  
    }  
  
    /**  
     * 현재 활성화된 Stream 타입과 상태를 반환한다.  
     */  
    fun getStatus(): Map<StreamType, StreamContextStatus> {  
        return contexts.map { (type, context) ->  
            type to StreamContextStatus(  
                state = "ACTIVE",  
                workerCount = context.workerManager.workerCount(),  
                lastPublishTime = context.lastPublishTime.get(),  
                streamKey = context.streamKey  
            )  
        }.toMap()  
    }  
  
    override fun destroy() {  
        log.info { "[Orchestrator] Shutting down all contexts" }  
        contexts.keys.toList().forEach { deactivate(it) }  
    }  
  
    // ──────────────────────────────────────────────────────────────  
    // Lifecycle: 초기화 / 종료  
    // ──────────────────────────────────────────────────────────────  
  
    private fun getOrCreateContext(streamType: StreamType): StreamContext {  
        return contexts.computeIfAbsent(streamType) { type ->  
            log.info { "[Orchestrator] Initializing stream context for $type" }  
            initializeContext(type)  
        }  
    }  
  
    /**  
     * Context 초기화: 모든 백그라운드 스레드를 한 번에 시작한다.  
     */  
    private fun initializeContext(streamType: StreamType): StreamContext {  
        val config = streamType.toConfig()  
  
        // 0. Stream 전용 DB Pool 생성 (첫 번째 Context 활성화 시만, 9.5절 참고)  
        if (contexts.isEmpty()) {  
            streamDataSourceManager.createPool()  
        }  
  
        // 1. Consumer Group 생성 (Stream이 없으면 MKSTREAM으로 자동 생성)  
        createConsumerGroup(config.streamKey, config.consumerGroup)  
  
        // 2. Worker 시작  
        val workerManager = workerManagerFactory.create(streamType)  
        workerManager.startAll()  
  
        // 3. Context 생성  
        val context = StreamContext(  
            streamType = streamType,  
            streamKey = config.streamKey,  
            consumerGroup = config.consumerGroup,  
            workerManager = workerManager,  
            lastPublishTime = AtomicReference(Instant.now()),  
            backgroundThreads = mutableListOf()  
        )  
  
        // 4. 백그라운드 스레드 시작 (모두 Context에 등록)  
        context.backgroundThreads += startIdleMonitor(context)  
        context.backgroundThreads += startPendingRecovery(context)  
        context.backgroundThreads += startStreamTrimmer(context)  
  
        log.info {  
            "[Orchestrator] Context initialized for $streamType" +  
            " - stream=${config.streamKey}, group=${config.consumerGroup}" +  
            " - workers=${workerManager.workerCount()}" +  
            " - backgroundThreads=${context.backgroundThreads.size}"  
        }  
        return context  
    }  
  
    /**  
     * Context 비활성화: Workers + 모든 백그라운드 스레드를 종료한다.  
     */  
    private fun deactivate(streamType: StreamType) {  
        val context = contexts.remove(streamType) ?: return  
  
        // 1. Worker 종료  
        context.workerManager.stopAll()  
  
        // 2. 백그라운드 스레드 종료 (Idle Monitor, Pending Recovery, Trimmer)  
        context.backgroundThreads.forEach { thread ->  
            thread.interrupt()  
        }  
  
        // 3. Stream 전용 DB Pool 삭제 (마지막 Context 비활성화 시만, 9.5절 참고)  
        if (contexts.isEmpty()) {  
            streamDataSourceManager.destroyPool()  
        }  
  
        log.info {  
            "[Orchestrator] Deactivated $streamType" +  
            " - workers stopped, ${context.backgroundThreads.size} background threads interrupted"  
        }  
    }  
  
    private fun createConsumerGroup(streamKey: String, groupName: String) {  
        try {  
            redisTemplate.opsForStream().createGroup(streamKey, ReadOffset.from("0"), groupName)  
            log.info { "[Orchestrator] Created consumer group: $groupName for stream: $streamKey" }  
        } catch (e: RedisSystemException) {  
            if (e.cause?.message?.contains("BUSYGROUP") == true) {  
                log.info { "[Orchestrator] Consumer group already exists: $groupName" }  
            } else {  
                throw e  
            }  
        }  
    }  
  
    // ──────────────────────────────────────────────────────────────  
    // Background Thread: Idle Monitor  
    // ──────────────────────────────────────────────────────────────  
  
    private fun startIdleMonitor(context: StreamContext): Thread {  
        return Thread.ofVirtual()  
            .name("idle-monitor-${context.streamType}")  
            .start {  
                val idleTimeout = streamProperties.idleTimeout  
                log.info { "[IdleMonitor] Started for ${context.streamType} - timeout=$idleTimeout" }  
  
                while (contexts.containsKey(context.streamType)) {  
                    try {  
                        Thread.sleep(streamProperties.idleCheckInterval.toMillis())  
  
                        val timeSinceLastPublish = Duration.between(  
                            context.lastPublishTime.get(), Instant.now()  
                        )  
                        val streamLen = redisTemplate.opsForStream().size(context.streamKey) ?: 0  
                        val pendingCount = getPendingCount(context)  
  
                        if (timeSinceLastPublish > idleTimeout && streamLen == 0L && pendingCount == 0L) {  
                            log.info {  
                                "[IdleMonitor] Idle timeout reached for ${context.streamType}" +  
                                " - idleTime=$timeSinceLastPublish"  
                            }  
                            deactivate(context.streamType)  
                            break  
                        }  
  
                        log.debug {  
                            "[IdleMonitor] ${context.streamType}" +  
                            " - idle=$timeSinceLastPublish, len=$streamLen, pending=$pendingCount"  
                        }  
                    } catch (e: InterruptedException) {  
                        Thread.currentThread().interrupt()  
                        break  
                    } catch (e: Exception) {  
                        log.error(e) { "[IdleMonitor] Error" }  
                    }  
                }  
                log.info { "[IdleMonitor] Stopped for ${context.streamType}" }  
            }    }  
  
    // ──────────────────────────────────────────────────────────────  
    // Background Thread: Pending Recovery (XCLAIM)  
    // ──────────────────────────────────────────────────────────────  
  
    private fun startPendingRecovery(context: StreamContext): Thread {  
        return Thread.ofVirtual()  
            .name("pending-recovery-${context.streamType}")  
            .start {  
                val interval = streamProperties.recoveryInterval  
                val claimMinIdleTime = when (context.streamType) {  
                    StreamType.VOUCHER -> workerProperties.voucher.claimMinIdleTime  
                    StreamType.POINT -> workerProperties.point.claimMinIdleTime  
                }  
                log.info { "[PendingRecovery] Started for ${context.streamType} - interval=$interval" }  
  
                while (contexts.containsKey(context.streamType)) {  
                    try {  
                        Thread.sleep(interval.toMillis())  
                        claimIdleMessages(context, claimMinIdleTime)  
                    } catch (e: InterruptedException) {  
                        Thread.currentThread().interrupt()  
                        break  
                    } catch (e: Exception) {  
                        log.error(e) { "[PendingRecovery] Error for ${context.streamType}" }  
                    }  
                }  
                log.info { "[PendingRecovery] Stopped for ${context.streamType}" }  
            }    }  
  
    private fun claimIdleMessages(context: StreamContext, claimMinIdleTime: Duration) {  
        val pending = redisTemplate.opsForStream()  
            .pending(context.streamKey, context.consumerGroup, Range.unbounded(), 100)  
  
        val idleMessages = pending.filter { it.elapsedTimeSinceLastDelivery > claimMinIdleTime }  
        if (idleMessages.isEmpty()) return  
  
        val targetConsumer = "${context.streamKey.substringAfterLast(":")}worker-0"  
        val idsToClaim = idleMessages.map { RecordId.of(it.id.value) }.toTypedArray()  
  
        redisTemplate.opsForStream().claim(  
            context.streamKey, context.consumerGroup, targetConsumer,  
            claimMinIdleTime, *idsToClaim  
        )  
  
        log.info {  
            "[PendingRecovery] Claimed ${idsToClaim.size} idle messages" +  
            " → $targetConsumer in ${context.streamKey}"  
        }  
    }  
  
    // ──────────────────────────────────────────────────────────────  
    // Background Thread: Stream Trimmer (XTRIM)  
    // ──────────────────────────────────────────────────────────────  
  
    private fun startStreamTrimmer(context: StreamContext): Thread {  
        return Thread.ofVirtual()  
            .name("stream-trimmer-${context.streamType}")  
            .start {  
                val interval = streamProperties.trimInterval  
                log.info { "[StreamTrimmer] Started for ${context.streamType} - interval=$interval" }  
  
                while (contexts.containsKey(context.streamType)) {  
                    try {  
                        Thread.sleep(interval.toMillis())  
                        trimStream(context.streamKey)  
                        trimStream(context.streamType.toConfig().dlqStreamKey)  
                    } catch (e: InterruptedException) {  
                        Thread.currentThread().interrupt()  
                        break  
                    } catch (e: Exception) {  
                        log.error(e) { "[StreamTrimmer] Error for ${context.streamType}" }  
                    }  
                }  
                log.info { "[StreamTrimmer] Stopped for ${context.streamType}" }  
            }    }  
  
    private fun trimStream(streamKey: String) {  
        val beforeLen = redisTemplate.opsForStream().size(streamKey) ?: 0  
        if (beforeLen <= streamProperties.maxLen) return  
  
        val trimmed = redisTemplate.opsForStream()  
            .trim(streamKey, streamProperties.maxLen, true)  
  
        log.info {  
            "[StreamTrimmer] Trimmed $streamKey" +  
            " - before=$beforeLen, trimmed=$trimmed, maxLen=${streamProperties.maxLen}"  
        }  
    }  
  
    // ──────────────────────────────────────────────────────────────  
    // Utility  
    // ──────────────────────────────────────────────────────────────  
  
    private fun getPendingCount(context: StreamContext): Long {  
        return try {  
            redisTemplate.opsForStream()  
                .pending(context.streamKey, context.consumerGroup)  
                .totalPendingMessages  
        } catch (e: Exception) { 0L }  
    }  
}  
```  
  
### 5.5 StreamType & StreamContext  
  
```kotlin  
enum class StreamType {  
    VOUCHER, POINT;  
  
    fun toConfig(): StreamTypeConfig = when (this) {  
        VOUCHER -> StreamTypeConfig(  
            streamKey = CampaignStreamConstants.VOUCHER_STREAM_KEY,  
            consumerGroup = CampaignStreamConstants.VOUCHER_CONSUMER_GROUP,  
            dlqStreamKey = CampaignStreamConstants.VOUCHER_DLQ_STREAM_KEY  
        )  
        POINT -> StreamTypeConfig(  
            streamKey = CampaignStreamConstants.POINT_STREAM_KEY,  
            consumerGroup = CampaignStreamConstants.POINT_CONSUMER_GROUP,  
            dlqStreamKey = CampaignStreamConstants.POINT_DLQ_STREAM_KEY  
        )  
    }  
}  
  
data class StreamTypeConfig(  
    val streamKey: String,  
    val consumerGroup: String,  
    val dlqStreamKey: String  
)  
  
data class StreamContext(  
    val streamType: StreamType,  
    val streamKey: String,  
    val consumerGroup: String,  
    val workerManager: StreamWorkerManager,  
    val lastPublishTime: AtomicReference<Instant>,  
    val backgroundThreads: MutableList<Thread> = mutableListOf()  
    // backgroundThreads: Idle Monitor, Pending Recovery, Stream Trimmer  
)  
  
data class StreamContextStatus(  
    val state: String,  
    val workerCount: Int,  
    val lastPublishTime: Instant,  
    val streamKey: String  
)  
```  
  
### 5.6 StreamWorkerManager  
  
특정 Stream 타입에 대한 Worker 풀을 관리한다. Orchestrator가 생성/소멸을 제어한다.  
  
```kotlin  
class StreamWorkerManager(  
    private val streamKey: String,  
    private val consumerGroup: String,  
    private val redisTemplate: StringRedisTemplate,  
    private val processor: AbstractCampaignPromotionProcessor<*, *>,  
    private val failureHandler: StreamFailureHandler,  
    private val workerConfig: StreamWorker.WorkerConfig,  
    private val workerCount: Int  
) {  
    private val log = KotlinLogging.logger {}  
    private val workers = ConcurrentHashMap<String, StreamWorker>()  
  
    fun startAll() {  
        repeat(workerCount) { index ->  
            val consumerName = "${streamKey.substringAfterLast(":")}worker-$index"  
            val worker = StreamWorker(  
                streamKey = streamKey,  
                consumerGroup = consumerGroup,  
                consumerName = consumerName,  
                redisTemplate = redisTemplate,  
                processor = processor,  
                failureHandler = failureHandler,  
                workerConfig = workerConfig  
            )  
            workers[consumerName] = worker  
            worker.start()  
        }  
        log.info { "[WorkerManager] Started $workerCount workers for stream=$streamKey" }  
    }  
  
    fun stopAll() {  
        log.info { "[WorkerManager] Stopping ${workers.size} workers for stream=$streamKey" }  
        workers.values.forEach { it.stop() }  
        workers.clear()  
    }  
  
    fun workerCount(): Int = workers.size  
}  
```  
  
### 5.7 StreamWorkerManagerFactory  
  
```kotlin  
@Component  
class StreamWorkerManagerFactory(  
    @Qualifier("streamRedisTemplate")  
    private val redisTemplate: StringRedisTemplate,  
    private val voucherProcessor: CampaignPromotionVoucherProcessor,  
    private val pointProcessor: CampaignPromotionPointProcessor,  
    private val failureHandler: StreamFailureHandler,  
    private val workerProperties: CampaignStreamWorkerProperties  
) {  
    fun create(streamType: StreamType): StreamWorkerManager {  
        val config = streamType.toConfig()  
        val workerTypeConfig = when (streamType) {  
            StreamType.VOUCHER -> workerProperties.voucher  
            StreamType.POINT -> workerProperties.point  
        }  
        val processor = when (streamType) {  
            StreamType.VOUCHER -> voucherProcessor  
            StreamType.POINT -> pointProcessor  
        }  
  
        return StreamWorkerManager(  
            streamKey = config.streamKey,  
            consumerGroup = config.consumerGroup,  
            redisTemplate = redisTemplate,  
            processor = processor,  
            failureHandler = failureHandler,  
            workerConfig = StreamWorker.WorkerConfig(  
                batchSize = workerTypeConfig.batchSize,  
                blockTimeout = workerTypeConfig.blockTimeout,  
                maxRetryCount = workerTypeConfig.maxRetryCount  
            ),  
            workerCount = workerTypeConfig.workerCount  
        )  
    }  
}  
```  
  
### 5.8 StreamWorker  
  
각 Worker는 독립적으로 Redis Stream에서 메시지를 읽어 처리한다.  
**이전 설계와 동일하지만, Orchestrator에 의해 동적으로 생성/소멸된다.**  
  
```kotlin  
class StreamWorker(  
    private val streamKey: String,  
    private val consumerGroup: String,  
    private val consumerName: String,  
    private val redisTemplate: StringRedisTemplate,  
    private val processor: AbstractCampaignPromotionProcessor<*, *>,  
    private val failureHandler: StreamFailureHandler,  
    private val workerConfig: WorkerConfig  
) {  
    private val log = KotlinLogging.logger {}  
    private val running = AtomicBoolean(false)  
    private lateinit var workerThread: Thread  
  
    data class WorkerConfig(  
        val batchSize: Int = 10,  
        val blockTimeout: Duration = Duration.ofSeconds(2),  
        val maxRetryCount: Int = 3,  
        val claimMinIdleTime: Duration = Duration.ofMinutes(5)  
    )  
  
    fun start() {  
        running.set(true)  
        workerThread = Thread.ofVirtual()  
            .name(consumerName)  
            .start { processLoop() }  
        log.info { "[$consumerName] Started" }  
    }  
  
    fun stop() {  
        running.set(false)  
        if (::workerThread.isInitialized) {  
            workerThread.interrupt()  
        }  
        log.info { "[$consumerName] Stopped" }  
    }  
  
    private fun processLoop() {  
        StreamWorkerContext.mark()  // Stream Worker ThreadLocal 마킹 (9.5절 DB 라우팅용)  
        try {  
            recoverPendingMessages()  
  
            while (running.get()) {  
                try {  
                    val messages = readNewMessages()  
                    if (messages.isNullOrEmpty()) continue  
                    processMessages(messages)  
                } catch (e: InterruptedException) {  
                    Thread.currentThread().interrupt()  
                    break  
                } catch (e: Exception) {  
                    log.error(e) { "[$consumerName] Unexpected error in process loop" }  
                    Thread.sleep(1000)  
                }  
            }  
        } finally {  
            StreamWorkerContext.clear()  // 마킹 해제 (반드시 finally에서)  
        }  
    }  
  
    private fun recoverPendingMessages() {  
        log.info { "[$consumerName] Recovering pending messages..." }  
        while (running.get()) {  
            val pending = readPendingMessages()  
            if (pending.isNullOrEmpty()) break  
            processMessages(pending)  
        }  
        log.info { "[$consumerName] Pending recovery complete" }  
    }  
  
    private fun readNewMessages(): List<MapRecord<String, String, String>>? {  
        @Suppress("UNCHECKED_CAST")  
        return redisTemplate.opsForStream().read(  
            Consumer.from(consumerGroup, consumerName),  
            StreamReadOptions.empty()  
                .count(workerConfig.batchSize.toLong())  
                .block(workerConfig.blockTimeout),  
            StreamOffset.create(streamKey, ReadOffset.lastConsumed())  
        ) as? List<MapRecord<String, String, String>>  
    }  
  
    private fun readPendingMessages(): List<MapRecord<String, String, String>>? {  
        @Suppress("UNCHECKED_CAST")  
        return redisTemplate.opsForStream().read(  
            Consumer.from(consumerGroup, consumerName),  
            StreamReadOptions.empty()  
                .count(workerConfig.batchSize.toLong()),  
            StreamOffset.create(streamKey, ReadOffset.from("0"))  
        ) as? List<MapRecord<String, String, String>>  
    }  
  
    private fun processMessages(messages: List<MapRecord<String, String, String>>) {  
        for (record in messages) {  
            val recordId = record.id  
            val payload = record.value  
            val message = payload[CampaignStreamConstants.FIELD_MESSAGE] ?: continue  
            val key = payload[CampaignStreamConstants.FIELD_KEY] ?: ""  
  
            try {  
                processor.process(message)  
                redisTemplate.opsForStream().acknowledge(streamKey, consumerGroup, recordId)  
                log.debug { "[$consumerName] Processed and ACKed - recordId=$recordId, key=$key" }  
            } catch (e: Exception) {  
                log.error(e) { "[$consumerName] Processing failed - recordId=$recordId, key=$key" }  
                failureHandler.handleFailure(streamKey, consumerGroup, recordId, record, e)  
            }  
        }  
    }  
}  
```  
  
---  
  
## 6. 처리 흐름 상세  
  
### 6.1 Lazy Initialization 흐름 (최초 메시지 수신)  
  
```  
시간 ──────────────────────────────────────────────────────────────→  
  
상태: IDLE (Worker 0개, Stream 미존재)  
  
[Kafka Consumer]  
   │ 메시지 수신  
   ▼  
[Orchestrator.publishToStream()]  
   │ contexts.computeIfAbsent(VOUCHER) 호출  
   │  
   ├── 0. StreamDataSourceManager.createPool()                 ~10ms  
   │      (첫 번째 Context 활성화 시만, Stream 전용 DB Pool 생성)  
   │  
   ├── 1. XGROUP CREATE campaign:promotion:voucher:stream     ~1ms  
   │      campaign-voucher-worker-group 0 MKSTREAM  
   │      (Stream + Consumer Group 동시 생성)  
   │  
   ├── 2. StreamWorkerManager.startAll()                      ~5ms  
   │      ├── Worker-0 (Virtual Thread) 시작  
   │      ├── Worker-1 (Virtual Thread) 시작  
   │      ├── ...  
   │      └── Worker-31 (Virtual Thread) 시작  
   │  
   ├── 3. Background Threads 시작                              ~1ms  
   │      ├── idle-monitor-VOUCHER    (Virtual Thread)  
   │      ├── pending-recovery-VOUCHER (Virtual Thread)  
   │      └── stream-trimmer-VOUCHER  (Virtual Thread)  
   │  
   ├── 4. XADD campaign:promotion:voucher:stream * ...        ~1ms  
   │  
   └── 상태: ACTIVE (Worker 32개 + Background 3개 가동)  
  
[Worker-0] (XREADGROUP로 즉시 메시지 수신)  
   ├── processor.process(message)                             ~200ms  
   └── XACK  
```  
  
> **최초 메시지의 지연**: 초기화 오버헤드는 ~20ms 수준이다.  
> DB Pool 생성(~10ms) + Consumer Group 생성(1ms) + Virtual Thread 32개 시작(~5ms)은 매우 가볍다.  
> 두 번째 메시지부터는 이미 초기화가 완료된 상태이므로 XADD만 수행한다.  
  
### 6.2 정상 처리 흐름 (이미 ACTIVE 상태)  
  
```  
[Kafka Consumer]  
   │ 메시지 수신  
   ▼  
[Orchestrator.publishToStream()]  
   │ contexts.get(VOUCHER) → 이미 존재  
   │ lastPublishTime 갱신  
   ├──→ XADD ...                                              ~1ms  
   │ Kafka ACK  
   ▼  
  
[Worker-3] (XREADGROUP로 할당받음)  
   ├── processor.process(message)  
   │   ├── parseJsonMessage()                         ~1ms  
   │   ├── isPromotionInProgress() [Redis cache]      ~5ms  
   │   ├── saveResult() [DB INSERT]                   ~30ms  
   │   ├── callMoneyApi() [Feign POST]                ~120ms  
   │   └── updateSuccess() [DB UPDATE + Event]        ~30ms  
   │                                            합계: ~186ms  
   ├──→ XACK ...  
   └── 다음 메시지 처리...  
```  
  
### 6.3 Idle Timeout에 의한 자동 종료  
  
```  
상태: ACTIVE  
  
마지막 메시지 처리 완료...  
   │  
   ▼ (시간 경과)  
[Idle Monitor] (매 30초마다 체크)  
   ├── lastPublishTime으로부터 경과 시간 확인  
   ├── XLEN campaign:promotion:voucher:stream → 0 (빈 Stream)  
   ├── XPENDING → 0 (pending 메시지 없음)  
   │  
   ├── idleTimeout(10분) 미도달 → 계속 대기  
   │   ... (반복) ...  
   │  
   ├── idleTimeout(10분) 도달 + streamLen=0 + pending=0  
   │   ├── StreamWorkerManager.stopAll()  
   │   │   ├── Worker-0 stop  
   │   │   ├── Worker-1 stop  
   │   │   └── ... Worker-31 stop  
   │   ├── contexts.remove(VOUCHER)  
   │   └── Idle Monitor 종료  
   │  
   └── 상태: IDLE (Worker 0개, 리소스 해제)  
  
다음 Kafka 메시지 수신 시 → 다시 6.1 흐름으로 재초기화  
```  
  
> **Idle Timeout 조건** (3가지 모두 충족해야 종료):  
> 1. `lastPublishTime`으로부터 N분 경과 (Kafka에서 새 메시지가 없음)  
> 2. `XLEN` = 0 (Stream에 미처리 메시지가 없음)  
> 3. `XPENDING` = 0 (PEL에 pending 메시지가 없음)  
>  
> 이 3가지를 모두 확인하므로 처리 중인 메시지가 있을 때 Worker가 종료되는 일은 없다.  
  
### 6.4 병렬 처리 동작 예시  
  
```  
시간 ──→  
  
Worker-0: ├─ msg1(200ms) ─┤├─ msg5(200ms) ─┤├─ msg9(200ms) ─┤...  
Worker-1: ├─ msg2(200ms) ─┤├─ msg6(200ms) ─┤├─ msg10(200ms)─┤...  
Worker-2: ├─ msg3(200ms) ─┤├─ msg7(200ms) ─┤├─ msg11(200ms)─┤...  
Worker-3: ├─ msg4(200ms) ─┤├─ msg8(200ms) ─┤├─ msg12(200ms)─┤...  
  ...         ...              ...              ...  
Worker-31:├─ msg32(200ms)─┤├─ msg64(200ms)─┤├─ msg96(200ms)─┤...  
  
→ 32 Workers: 200ms당 32건 = 초당 160건/인스턴스  
→ 4 인스턴스: 초당 640건  
```  
  
### 6.5 Kafka ACK → Redis Stream 사이 유실 시나리오  
  
```  
[Kafka Consumer]  
   ├── 메시지 수신  
   ├── XADD (Redis Stream 발행)  ← 여기서 Redis 장애 발생 시?  
   └── Kafka ACK                 ← 아직 ACK 전이므로 Kafka가 재전달  
  
방어: XADD 실패 시 Kafka ACK하지 않고 예외를 던진다.  
     → Kafka가 메시지를 재전달한다.  
     → 기존 프로세서의 idempotency(unique constraint)가 중복 처리를 방지한다.  
```  
  
```kotlin  
// CampaignStreamOrchestrator.publishToStream() 내부 방어 코드  
val recordId = redisTemplate.opsForStream().add(record)  
    ?: throw StreamPublishException("Failed to publish to stream: ${context.streamKey}")  
  
// XADD 실패 시 예외 발생 → Kafka Listener에서 ACK하지 않음  
// → Kafka가 메시지를 재전달  
// → 기존 프로세서의 idempotency(unique constraint)가 중복 처리를 방지  
```  
  
---  
  
## 7. 장애 처리 설계  
  
### 7.1 처리 실패 시 흐름  
  
```  
Worker가 메시지 처리 실패  
    │  
    ▼  
ACK하지 않음 → PEL에 유지  
    │  
    ▼  
XPENDING으로 delivery count 확인  
    │  
    ├── deliveryCount < maxRetryCount  
    │       → PEL에 유지, 다른 Worker가 XAUTOCLAIM으로 재처리  
    │  
    └── deliveryCount >= maxRetryCount  
            → Dead Letter Stream으로 이동 후 XACK  
```  
  
### 7.2 StreamFailureHandler  
  
```kotlin  
@Component  
class StreamFailureHandler(  
    @Qualifier("streamRedisTemplate")  
    private val redisTemplate: StringRedisTemplate  
) {  
    private val log = KotlinLogging.logger {}  
  
    companion object {  
        private const val DEFAULT_MAX_RETRY = 3  
    }  
  
    fun handleFailure(  
        streamKey: String,  
        consumerGroup: String,  
        recordId: RecordId,  
        record: MapRecord<String, String, String>,  
        exception: Exception  
    ) {  
        val pendingInfo = getPendingInfo(streamKey, consumerGroup, recordId)  
        val deliveryCount = pendingInfo?.totalDeliveryCount ?: 1  
  
        if (deliveryCount >= DEFAULT_MAX_RETRY) {  
            // Dead Letter Stream으로 이동  
            moveToDlq(streamKey, consumerGroup, recordId, record, exception)  
        } else {  
            log.warn {  
                "[FailureHandler] Message will be retried" +  
                " - streamKey=$streamKey, recordId=$recordId" +  
                " - deliveryCount=$deliveryCount/$DEFAULT_MAX_RETRY" +  
                " - error=${exception.message}"  
            }  
            // ACK하지 않고 PEL에 유지 → 자동 재시도  
        }  
    }  
  
    private fun moveToDlq(  
        streamKey: String,  
        consumerGroup: String,  
        recordId: RecordId,  
        record: MapRecord<String, String, String>,  
        exception: Exception  
    ) {  
        val dlqKey = getDlqStreamKey(streamKey)  
        val dlqRecord = StreamRecords.string(  
            record.value.toMutableMap().apply {  
                put("originalStreamKey", streamKey)  
                put("originalRecordId", recordId.value)  
                put("errorMessage", exception.message ?: "unknown")  
                put("failedAt", Instant.now().toEpochMilli().toString())  
            }  
        ).withStreamKey(dlqKey)  
  
        redisTemplate.opsForStream().add(dlqRecord)  
        redisTemplate.opsForStream().acknowledge(streamKey, consumerGroup, recordId)  
  
        log.error {  
            "[FailureHandler] Moved to DLQ" +  
            " - from=$streamKey, to=$dlqKey, recordId=$recordId" +  
            " - error=${exception.message}"  
        }  
    }  
  
    private fun getDlqStreamKey(streamKey: String): String {  
        return when (streamKey) {  
            CampaignStreamConstants.VOUCHER_STREAM_KEY -> CampaignStreamConstants.VOUCHER_DLQ_STREAM_KEY  
            CampaignStreamConstants.POINT_STREAM_KEY -> CampaignStreamConstants.POINT_DLQ_STREAM_KEY  
            else -> "$streamKey:dlq"  
        }  
    }  
  
    private fun getPendingInfo(  
        streamKey: String,  
        consumerGroup: String,  
        recordId: RecordId  
    ): PendingMessage? {  
        return try {  
            val pending = redisTemplate.opsForStream()  
                .pending(streamKey, consumerGroup, Range.closed(recordId.value, recordId.value), 1)  
            pending.firstOrNull()  
        } catch (e: Exception) {  
            log.warn(e) { "[FailureHandler] Failed to get pending info - recordId=$recordId" }  
            null  
        }  
    }  
}  
```  
  
### 7.3 Pending Recovery & Stream Trimmer (Orchestrator 내장)  
  
> **이전 설계에서는 `@Scheduled` 기반의 독립 Bean(`StreamPendingRecoveryScheduler`, `StreamMaintenanceScheduler`)으로  
> 구현하여 앱이 실행되는 동안 항상 스레드가 동작했다.**  
>  
> **변경된 설계에서는 Orchestrator가 Context 활성화 시 Virtual Thread로 시작하고,  
> Idle Timeout에 의해 Context가 비활성화되면 함께 종료된다.**  
  
Pending Recovery와 Stream Trimmer의 구현은 `CampaignStreamOrchestrator` 내부 메서드로 통합되어 있다.  
(5.4절의 `startPendingRecovery()`, `startStreamTrimmer()` 참고)  
  
```  
Context 라이프사이클과 Scheduler의 관계:  
  
IDLE 상태:     Scheduler 스레드 없음 (리소스 0)  
    │  
    ▼ 첫 메시지 수신  
ACTIVE 상태:   Scheduler 스레드 활성  
    ├── pending-recovery-VOUCHER  (5분마다 XCLAIM)  
    └── stream-trimmer-VOUCHER   (10분마다 XTRIM)  
    │  
    ▼ Idle Timeout (10분)  
IDLE 상태:     Scheduler 스레드 종료 (interrupt)  
               → contexts.remove() 호출 시 while 루프 탈출  
```  
  
### 7.4 ElastiCache Failover 시 동작  
  
ElastiCache Standalone 모드에서 Primary 장애가 발생하면 Replica가 자동 승격된다.  
  
```  
정상 상태:  
  Primary ──replica──→ Replica  
  (Read/Write)         (Read Only)  
  
Failover 발생:  
  Primary (장애) ──X──→ Replica → New Primary (승격)  
                                   (Read/Write)  
```  
  
**Failover 시 Stream 데이터 영향:**  
  
| 시나리오 | Stream 데이터 | 대응 |  
|---------|:-:|------|  
| 정상 Failover | 보존 (Replica에 복제됨) | 자동 복구, 일시적 연결 끊김 발생 |  
| ReplicationLag 있는 상태에서 Failover | **일부 유실 가능** | Lag 크기만큼 최근 데이터 손실 |  
| 양쪽 모두 장애 | **전체 유실** | Kafka에서 재처리 (idempotency 보장) |  
  
**Lettuce 자동 재연결:**  
  
기존 `RedisTemplateConfig`와 Stream 전용 `StreamRedisConfig` 모두 동일한 autoReconnect 설정을 적용한다.  
Failover 후 자동으로 새 Primary에 재연결된다.  
  
```kotlin  
// RedisTemplateConfig, StreamRedisConfig 모두 동일 설정  
ClientOptions.builder()  
    .autoReconnect(true)                                         // 자동 재연결 활성화  
    .disconnectedBehavior(ClientOptions.DisconnectedBehavior.REJECT_COMMANDS)  // 연결 끊김 시 에러 반환  
    .protocolVersion(ProtocolVersion.RESP2)  
    .build()  
```  
  
**Worker의 Failover 대응:**  
  
```  
Failover 발생 시:  
  1. XREADGROUP BLOCK 중인 Worker → RedisConnectionException 발생  
  2. Worker catch 블록 → 1초 backoff 후 재시도  
  3. Lettuce 자동 재연결 → 새 Primary에 연결  
  4. Worker 정상 동작 재개  
  5. Pending 메시지는 PEL에 유지되므로 재처리됨  
```  
  
> Failover 시 최대 수 초간의 일시 중단이 발생하지만,  
> Worker의 backoff 루프와 Lettuce 자동 재연결에 의해 자동 복구된다.  
> **Kafka에서 아직 ACK하지 않은 메시지는 Kafka가 재전달하고,  
> 이미 Redis Stream에 있는 메시지는 PEL에 의해 보호된다.**  
  
---  
  
## 8. Stream 관리 정책  
  
### 8.1 XTRIM 정책  
  
처리 완료(ACK)된 메시지가 무한히 쌓이지 않도록 주기적으로 트리밍한다.  
  
> **이전 설계에서는 `@Scheduled` 기반의 독립 Bean(`StreamMaintenanceScheduler`)으로 구현하여  
> 앱이 실행되는 동안 항상 스레드가 동작했다.**  
>  
> **변경된 설계에서는 `CampaignStreamOrchestrator`가 Context 활성화 시 Virtual Thread로 시작하고,  
> Idle Timeout에 의해 Context가 비활성화되면 함께 종료된다.**  
  
Stream Trimmer의 구현은 `CampaignStreamOrchestrator` 내부 메서드로 통합되어 있다.  
(5.4절의 `startStreamTrimmer()` 참고)  
  
```  
Context 라이프사이클과 Stream Trimmer의 관계:  
  
IDLE 상태:     Trimmer 스레드 없음 (리소스 0)  
    │  
    ▼ 첫 메시지 수신  
ACTIVE 상태:   Trimmer 스레드 활성  
    └── stream-trimmer-VOUCHER  (10분마다 XTRIM)  
    │  
    ▼ Idle Timeout (10분)  
IDLE 상태:     Trimmer 스레드 종료 (interrupt)  
               → contexts.remove() 호출 시 while 루프 탈출  
```  
  
**Trim 대상:** 메인 Stream + DLQ Stream 모두 트리밍한다.  
approximate 모드(`~` 플래그)를 사용하여 Redis 성능에 미치는 영향을 최소화한다.  
  
```  
XTRIM campaign:promotion:voucher:stream MAXLEN ~ 100000  
XTRIM campaign:promotion:voucher:dlq    MAXLEN ~ 100000  
```  
  
### 8.2 ElastiCache 메모리 관리  
  
| 항목 | 값 |  
|------|------|  
| 메시지 1건 평균 크기 | ~500 bytes (JSON payload + metadata) |  
| Stream entry 오버헤드 | ~100 bytes (ID, 내부 구조) |  
| 100만건 미처리 백로그 | ~600MB |  
| MAXLEN 10만건 유지 시 | ~60MB |  
| DLQ 1만건 유지 시 | ~6MB |  
  
> MAXLEN을 적절히 설정하면 메모리 사용량을 안전한 수준으로 유지할 수 있다.  
> 100만건이 한꺼번에 쌓이는 것이 아니라, Worker가 즉시 소비하므로 실제 백로그는 훨씬 적다.  
  
**ElastiCache 메모리 사용량 모니터링:**  
  
```  
⚠️ CloudWatch 알람 설정 권장  
  
메트릭: DatabaseMemoryUsagePercentage  
  - Warning: > 70%  
  - Critical: > 85%  
  
메트릭: EngineCPUUtilization  
  - Warning: > 65%  
  - Critical: > 80%  
```  
  
ElastiCache Standalone 모드에서는 단일 노드의 메모리가 전부이므로,  
기존 용도(Spring Session, promotionStatus 캐시 등)와의 메모리 경합에 주의해야 한다.  
  
| 용도 | 예상 메모리 | 비고 |  
|------|:-:|------|  
| Spring Session | ~100MB | 동시 세션 수에 따라 변동 |  
| promotionStatus 캐시 | ~10MB | TTL 10분, 소량 |  
| **Stream (정상 시)** | **~30-60MB** | Worker가 즉시 소비, 백로그 최소 |  
| **Stream (백로그 시)** | **~600MB** | 100만건 누적 시 최대치 |  
| DLQ | ~6MB | MAXLEN 1만건 기준 |  
| 기타 | ~50MB | 여유분 |  
  
---  
  
## 9. 설정 설계  
  
### 9.1 Properties 클래스  
  
```kotlin  
@ConfigurationProperties(prefix = "redis.stream.campaign-promotion")  
data class CampaignStreamProperties(  
    val enabled: Boolean = false,                                // Feature Toggle  
    val maxLen: Long = 100_000,                                  // Stream 최대 항목 수  
    val trimInterval: Duration = Duration.ofMinutes(10),         // Trim 주기  
    val recoveryInterval: Duration = Duration.ofMinutes(5),      // Pending 복구 주기  
    val idleTimeout: Duration = Duration.ofMinutes(10),          // Idle 상태 유지 후 Worker 종료  
    val idleCheckInterval: Duration = Duration.ofSeconds(30)     // Idle 체크 주기  
)  
  
@ConfigurationProperties(prefix = "redis.stream.campaign-promotion.worker")  
data class CampaignStreamWorkerProperties(  
    val voucher: WorkerTypeConfig = WorkerTypeConfig(),  
    val point: WorkerTypeConfig = WorkerTypeConfig()  
) {  
    data class WorkerTypeConfig(  
        val workerCount: Int = 32,                               // Worker 스레드 수  
        val batchSize: Int = 10,                                 // XREADGROUP COUNT  
        val blockTimeout: Duration = Duration.ofSeconds(2),      // XREADGROUP BLOCK  
        val maxRetryCount: Int = 3,                              // 최대 재시도 횟수  
        val claimMinIdleTime: Duration = Duration.ofMinutes(5)   // XAUTOCLAIM idle 기준  
    )  
}  
```  
  
### 9.2 redis.yml 추가 설정  
  
기존 `redis.yml`의 `redis:` 하위에 `stream.campaign-promotion` 프로퍼티를 추가한다.  
  
```yaml  
# redis.yml  
redis:  
  # ... 기존 설정 (master, slave, lettuce 등) ...  
  
  stream:  
    campaign-promotion:  
      enabled: true                # Feature Toggle (false면 기존 직접 처리)  
      max-len: 100000              # Stream 최대 항목 수 (approximate trim)  
      trim-interval: 10m           # Trim 주기  
      recovery-interval: 5m        # Pending 복구 주기  
      idle-timeout: 10m            # Worker 자동 종료까지 유휴 시간  
      idle-check-interval: 30s     # Idle 상태 체크 주기  
      connection:                  # Stream 전용 Redis 연결 설정 (9.4절 참고)  
        command-timeout: 10s       # XREADGROUP BLOCK(2s)보다 충분히 큰 값  
        pool:  
          max-total: 80            # 최대 커넥션 수 (Voucher 32 + Point 32 + 여유)  
          max-idle: 50             # ACTIVE 상태에서의 최대 유휴 연결  
          min-idle: 0              # IDLE 상태에서는 연결 유지하지 않음  
      db-pool:                       # Stream 전용 DB Connection Pool (9.5절 참고)  
        pool-size: 20                # Stream 전용 Pool 크기  
        connection-timeout: 3000     # 커넥션 획득 대기 시간 (ms)  
        leak-detection-threshold: 3000  # 커넥션 누수 감지 (ms)  
      worker:  
        voucher:  
          worker-count: 32         # Voucher Worker 수  
          batch-size: 10           # 배치 크기  
          block-timeout: 2s        # 블로킹 대기 시간  
          max-retry-count: 3       # 최대 재시도  
          claim-min-idle-time: 5m  
        point:  
          worker-count: 32         # Point Worker 수  
          batch-size: 10  
          block-timeout: 2s  
          max-retry-count: 3  
          claim-min-idle-time: 5m  
```  
  
> `redis.yml`은 이미 `application.yml`의 `spring.config.import`에 포함되어 있으므로  
> 별도의 import 설정 추가는 필요하지 않다.  
  
### 9.3 환경별 Worker 수 조절 가이드  
  
| 환경 | Voucher Workers | Point Workers | 근거 |  
|------|:-:|:-:|------|  
| local | 4 | 4 | 개발 환경 리소스 절약 |  
| dev | 8 | 8 | 테스트용 적정 규모 |  
| staging | 16 | 16 | 운영 환경 절반 수준으로 검증 |  
| production | 32 | 32 | 목표 처리량 달성 기준 |  
  
### 9.4 Stream 전용 Redis 설정  
  
#### 기존 설정의 문제점  
  
현재 `RedisTemplateConfig`는 일반적인 Redis 용도(Spring Session, 캐시)에 최적화되어 있다.  
Redis Stream 의 `XREADGROUP BLOCK` 명령어와 함께 사용하면 다음 문제가 발생한다.  
  
| # | 문제 | 원인 | 영향 |  
|---|------|------|------|  
| 1 | **BLOCK 시 연결 점유** | Lettuce 기본값은 단일 연결 멀티플렉싱. `XREADGROUP BLOCK`이 연결을 점유하면 다른 모든 Redis 명령이 대기 | 32개 Worker가 동시에 BLOCK하면 사실상 Redis 사용 불가 |  
| 2 | **hashValueSerializer 불일치** | `GenericJackson2JsonRedisSerializer`가 Stream entry 값에 JSON 타입 정보를 추가 | Stream에 `"\"hello\""` 같은 이중 인코딩 발생 |  
| 3 | **commandTimeout 충돌 가능** | `redis.connect-timeout` 값이 `XREADGROUP BLOCK` 시간보다 짧을 수 있음 | Worker가 정상적으로 BLOCK 대기하지 못하고 타임아웃 |  
  
```  
기존 RedisTemplateConfig 분석:  
  
LettuceClientConfiguration (멀티플렉싱 - 단일 연결)  
├── autoReconnect: true                          ← OK  
├── disconnectedBehavior: REJECT_COMMANDS        ← OK  
├── protocolVersion: RESP2                       ← OK  
├── commandTimeout: ${redis.connect-timeout}     ← ⚠️ BLOCK보다 짧을 수 있음  
├── readFrom: REPLICA_PREFERRED                  ← ⚠️ Stream은 Primary 중심  
└── 연결 방식: 단일 연결 멀티플렉싱               ← ✗ BLOCK에 부적합  
  
RedisTemplate<String, String>  
├── keySerializer: StringRedisSerializer         ← OK  
├── valueSerializer: StringRedisSerializer       ← OK  
├── hashKeySerializer: StringRedisSerializer     ← OK  
└── hashValueSerializer: GenericJackson2JsonRedis ← ✗ Stream에 부적합  
```  
  
#### 해결: Stream 전용 ConnectionFactory + RedisTemplate 분리  
  
```  
┌─────────────────────────────────────────────────────────────────┐  
│                    Redis Connection 구조                          │  
│                                                                 │  
│  RedisTemplateConfig (기존 - 변경 최소화)                         │  
│  ├── redisConnectFactory (@Primary)                             │  
│  │   └── 단일 연결 멀티플렉싱 (REPLICA_PREFERRED)                 │  
│  │       → Spring Session, 캐시, Spring Data Redis Repository   │  
│  └── redisTemplate                                              │  
│      └── hashValueSerializer = GenericJackson2JsonRedis          │  
│                                                                 │  
│  StreamRedisConfig (신규)                                        │  
│  ├── streamRedisConnectionFactory                               │  
│  │   └── 커넥션 풀 (maxTotal=80, UPSTREAM)                       │  
│  │       → XREADGROUP BLOCK 시 연결 점유 지원                     │  
│  └── streamRedisTemplate (StringRedisTemplate)                  │  
│      └── 모든 Serializer = StringRedisSerializer                 │  
│          → Stream entry 순수 문자열 저장                          │  
└─────────────────────────────────────────────────────────────────┘  
```  
  
#### StreamRedisConfig 구현  
  
```kotlin  
@Configuration  
class StreamRedisConfig(  
    @Value("\${redis.master.host}") private val masterHost: String,  
    @Value("\${redis.master.port}") private val masterPort: Int,  
    @Value("\${redis.slave.host}") private val replicaHost: String,  
    @Value("\${redis.slave.port}") private val replicaPort: Int,  
    @Value("\${redis.stream.campaign-promotion.connection.command-timeout:10s}") private val commandTimeout: Duration,  
    @Value("\${redis.stream.campaign-promotion.connection.pool.max-total:80}") private val poolMaxTotal: Int,  
    @Value("\${redis.stream.campaign-promotion.connection.pool.max-idle:50}") private val poolMaxIdle: Int,  
    @Value("\${redis.stream.campaign-promotion.connection.pool.min-idle:0}") private val poolMinIdle: Int  
) {  
  
    /**  
     * Stream 전용 ConnectionFactory.  
     *  
     * 기존 redisConnectFactory와의 차이:  
     * 1. 커넥션 풀 사용 (LettucePoolingClientConfiguration)  
     *    - XREADGROUP BLOCK이 연결을 점유하므로 Worker별 독립 연결 필요  
     * 2. ReadFrom.UPSTREAM (Primary only)  
     *    - Stream 명령어 대부분이 Write (XADD, XREADGROUP >, XACK, XCLAIM)  
     *    - 일관성을 위해 Read 명령어(XLEN, XPENDING)도 Primary에서 실행  
     * 3. commandTimeout = 10초 (설정 가능)  
     *    - XREADGROUP BLOCK 2초 + 충분한 여유시간  
     */  
    @Bean  
    fun streamRedisConnectionFactory(): LettuceConnectionFactory {  
        val poolConfig = GenericObjectPoolConfig<Any>().apply {  
            maxTotal = poolMaxTotal  // Voucher(32) + Point(32) + Publisher + Background 여유분  
            maxIdle = poolMaxIdle    // ACTIVE 상태에서의 유휴 연결  
            minIdle = poolMinIdle    // IDLE 상태에서는 연결 유지하지 않음 (Lazy Lifecycle)  
        }  
  
        val clientConfig = LettucePoolingClientConfiguration.builder()  
            .poolConfig(poolConfig)  
            .clientOptions(  
                ClientOptions.builder()  
                    .autoReconnect(true)  
                    .disconnectedBehavior(ClientOptions.DisconnectedBehavior.REJECT_COMMANDS)  
                    .protocolVersion(ProtocolVersion.RESP2)  
                    .build()  
            )  
            .commandTimeout(commandTimeout)           // > blockTimeout(2s)  
            .readFrom(ReadFrom.UPSTREAM)              // Stream은 Primary에서 실행  
            .build()  
  
        val masterReplicaConfig = RedisStaticMasterReplicaConfiguration(masterHost, masterPort)  
        masterReplicaConfig.addNode(replicaHost, replicaPort)  
  
        return LettuceConnectionFactory(masterReplicaConfig, clientConfig)  
    }  
  
    /**  
     * Stream 전용 RedisTemplate.  
     *  
     * StringRedisTemplate은 모든 Serializer가 StringRedisSerializer이므로  
     * Stream entry의 field-value가 순수 문자열로 저장/조회된다.  
     *  
     * 기존 redisTemplate과의 차이:  
     * - hashValueSerializer = StringRedisSerializer (기존: GenericJackson2JsonRedisSerializer)  
     */  
    @Bean  
    fun streamRedisTemplate(  
        @Qualifier("streamRedisConnectionFactory") connectionFactory: LettuceConnectionFactory  
    ): StringRedisTemplate {  
        return StringRedisTemplate(connectionFactory)  
    }  
}  
```  
  
#### 기존 RedisTemplateConfig 변경사항  
  
두 개의 `RedisConnectionFactory` Bean이 존재하므로, 기존 팩토리에 `@Primary`를 추가하여  
Spring 자동 주입(Spring Session, Spring Data Redis Repository 등)이 기존 팩토리를 사용하도록 한다.  
  
```kotlin  
// RedisTemplateConfig.kt - 변경사항 (최소 변경)  
@Bean  
@Primary  // ← 추가: Spring Session, Repository 등이 이 팩토리를 자동 주입  
fun redisConnectFactory(): RedisConnectionFactory? {  
    // ... 기존 코드 동일 ...  
}  
```  
  
#### Stream 컴포넌트에서의 사용  
  
모든 Stream 관련 컴포넌트는 `@Qualifier("streamRedisTemplate")`로 Stream 전용 Template을 주입받는다.  
  
```kotlin  
@Component  
class CampaignStreamOrchestrator(  
    @Qualifier("streamRedisTemplate")           // ← Stream 전용  
    private val redisTemplate: StringRedisTemplate,  
    private val workerManagerFactory: StreamWorkerManagerFactory,  
    private val streamProperties: CampaignStreamProperties,  
    private val workerProperties: CampaignStreamWorkerProperties  
) : DisposableBean {  
    // ...  
}  
  
// StreamWorkerManager, StreamFailureHandler 등도 동일하게 @Qualifier 적용  
```  
  
#### 커넥션 풀 사이징 가이드  
  
| 시나리오 | VOUCHER Workers | POINT Workers | Publisher + 기타 | 필요 연결 수 | pool.max-total |  
|---------|:-:|:-:|:-:|:-:|:-:|  
| VOUCHER만 활성 | 32 | 0 | ~6 | ~38 | 80 (여유) |  
| POINT만 활성 | 0 | 32 | ~6 | ~38 | 80 (여유) |  
| 둘 다 활성 | 32 | 32 | ~8 | ~72 | 80 (적정) |  
| Worker 수 증가 (64+64) | 64 | 64 | ~10 | ~138 | **150으로 증가 필요** |  
  
> **`pool.min-idle = 0`** 설정이 핵심이다.  
> Lazy Lifecycle에 따라 IDLE 상태에서는 Stream 연결을 유지하지 않으며,  
> 첫 메시지 수신 시 풀이 동적으로 연결을 생성한다.  
  
#### 추가 의존성 (build.gradle.kts)  
  
Lettuce 커넥션 풀을 사용하려면 `commons-pool2` 의존성이 필요하다.  
  
```kotlin  
// build.gradle.kts  
dependencies {  
    // ... 기존 의존성 ...  
    implementation("org.apache.commons:commons-pool2")  // Lettuce 커넥션 풀  
}  
```  
  
> `spring-boot-starter-data-redis`에는 Lettuce가 포함되지만 `commons-pool2`는 포함되지 않는다.  
> 이 의존성이 없으면 `LettucePoolingClientConfiguration` 사용 시 런타임 에러가 발생한다.  
  
#### redis.yml 설정  
  
`redis.stream.campaign-promotion.connection.*` 하위에 설정한다. (9.2절의 redis.yml 참고)  
  
### 9.5 DB Connection Pool 관리  
  
Stream Worker가 병렬로 메시지를 처리하면서 DB에 동시 접근하게 되므로,  
**Stream 전용 DB Connection Pool을 별도 생성하고 처리 완료 후 삭제**하는 방식으로 관리한다.  
  
#### 현재 DB 환경  
  
| 항목 | 값 |  
|------|-----|  
| DataSource 수 | 6개 (prepay-admin, member, money, voucher, statistics, notification) |  
| prepay-admin Writer Pool | `maximum-pool-size: 5` |  
| prepay-admin Reader Pool | `maximum-pool-size: 5` |  
| DB 엔진 | AWS Aurora MySQL (aws-advanced-jdbc-wrapper) |  
| Connection Timeout | 3,000ms |  
| Leak Detection | 3,000ms |  
| Writer/Reader 분리 | `DbRoutingDataSource` + `LazyConnectionDataSourceProxy` |  
| Transaction Manager | `prepayAdminTransactionManager` (`@Primary`) |  
  
현재 Bean 구조:  
```  
prepayAdminWriterDataSource (HikariDataSource) ──┐  
prepayAdminReaderDataSource (HikariDataSource) ──┤  
                                                  ↓  
prepayAdminDbRoutingDataSource (DbRoutingDataSource, @Primary)  
├── WRITER → writerDataSource  
├── READER → readerDataSource  
└── default → readerDataSource  
                                                  ↓  
prepayAdminDataSource (LazyConnectionDataSourceProxy)  
                                                  ↓  
prepayAdminEntityManagerFactory (LocalContainerEntityManagerFactoryBean)  
                                                  ↓  
prepayAdminTransactionManager (JpaTransactionManager, @Primary)  
```  
  
#### 문제: Worker 수 vs Pool 크기  
  
Stream Worker 32개가 동시에 메시지를 처리하면서 DB에 접근한다.  
현재 Writer Pool은 `maximum-pool-size: 5`이므로, 동시 접근 시 커넥션 확보 대기(timeout)가 발생한다.  
  
#### 트랜잭션 분석  
  
현재 `AbstractCampaignPromotionProcessor.process()` 의 처리 흐름을 분석하면:  
  
```  
메시지 1건 처리 (~200ms)  
├── parseJsonMessage()            ~1ms   (DB 미사용)  
├── isPromotionInProgress()       ~5ms   (Reader - 캐시 우선)  
├── saveResult()                  ~30ms  (Writer - @Transactional(REQUIRES_NEW))  
│   └── INSERT 실행 → 즉시 COMMIT → 커넥션 반환  
├── callMoneyApi()                ~150ms (Feign HTTP - DB 미사용 ★)  
│   └── 이 구간에서는 DB 커넥션을 점유하지 않음  
├── updateSuccess()               ~30ms  (Writer - @Transactional(REQUIRES_NEW))  
│   └── UPDATE 실행 → 즉시 COMMIT → 커넥션 반환  
└── 총 DB 점유 시간: ~60ms / 200ms (30%)  
```  
  
핵심: **`@Transactional(propagation = REQUIRES_NEW)`** 덕분에 각 DB 작업이 독립된 짧은 트랜잭션으로 실행되고,  
Money API 호출(~150ms) 구간에서는 DB 커넥션을 전혀 점유하지 않는다.  
  
#### 동시 커넥션 수 추정  
  
```  
Worker 32개, 메시지 처리 200ms, DB 점유 60ms (saveResult 30ms + updateSuccess 30ms)  
  
동시에 DB를 사용하는 Worker 확률:  
- 각 Worker가 200ms 중 60ms만 DB 사용 → DB 사용 확률 = 60/200 = 30%  
- 32 Workers × 30% = 평균 ~10개 동시 커넥션  
  
피크 시나리오 (95th percentile):  
- 이항분포 B(32, 0.3) → P(X ≤ 15) ≈ 0.98  
- 피크: ~15~16개 동시 커넥션  
  
두 StreamType 동시 활성 시:  
- 64 Workers × 30% = 평균 ~19개, 피크 ~25~28개 동시 커넥션  
```  
  
#### 해결 방안: Stream 전용 DataSource 동적 생성/삭제  
  
기존 Connection Pool을 런타임에 변경하지 않고, **Stream Context 활성화 시 전용 `HikariDataSource`를 새로 생성**한다.  
Stream Worker 스레드에서 Writer DB 접근 시 이 전용 풀을 사용하며, 모든 Context 비활성화 시 풀을 닫고 삭제한다.  
  
```  
Stream Context 활성화 시:  
┌─────────────────────────────────────────────────────────┐  
│ 기존 Writer Pool (pool=5)       ← 일반 요청용 (변경 없음)  │  
│ Stream Writer Pool (pool=20)    ← Stream Worker 전용 (신규) │  
└─────────────────────────────────────────────────────────┘  
  
Stream Context 비활성화 시:  
┌─────────────────────────────────────────────────────────┐  
│ 기존 Writer Pool (pool=5)       ← 일반 요청용 (변경 없음)  │  
│ (Stream Writer Pool 삭제됨)                               │  
└─────────────────────────────────────────────────────────┘  
```  
  
장점:  
- 기존 Pool 설정을 런타임에 변경하지 않음 (사이드이펙트 없음)  
- Stream과 일반 요청 간 커넥션 완전 격리  
- Pool 생성/삭제가 Orchestrator Lifecycle과 정확히 일치  
  
#### 설계 개요  
  
```  
┌─ PrepayAdminDbConfig (변경) ───────────────────────────────────┐  
│                                                                │  
│  prepayAdminWriterHikariDataSource   ← 기존 HikariDataSource   │  
│         │                                (Bean 분리)           │  
│         ▼                                                      │  
│  StreamAwareDataSourceProxy                                    │  
│  (= prepayAdminWriterDataSource)                               │  
│         │                                                      │  
│         ├── Stream Worker 스레드 → StreamDataSourceManager      │  
│         │                           .getStreamPool()           │  
│         │                           (전용 HikariDataSource)    │  
│         │                                                      │  
│         └── 일반 스레드 → 기존 Writer HikariDataSource          │  
│                                                                │  
│  prepayAdminDbRoutingDataSource (기존과 동일, 변경 없음)         │  
│  prepayAdminDataSource (기존과 동일, 변경 없음)                  │  
│  prepayAdminEntityManagerFactory (변경 없음)                    │  
│  prepayAdminTransactionManager (변경 없음)                      │  
└────────────────────────────────────────────────────────────────┘  
```  
  
> 핵심: Writer DataSource를 `StreamAwareDataSourceProxy`로 감싸서,  
> `getConnection()` 시점에 **호출 스레드**에 따라 기존 풀과 Stream 전용 풀을 분기한다.  
> `DbRoutingDataSource` 이하의 JPA 인프라(EntityManagerFactory, TransactionManager)는 **변경 없이 동작**한다.  
  
#### StreamWorkerContext (ThreadLocal 마커)  
  
Stream Worker 스레드를 식별하기 위한 ThreadLocal 컨텍스트.  
  
```kotlin  
object StreamWorkerContext {  
    private val isStreamWorker = ThreadLocal.withInitial { false }  
  
    fun mark() { isStreamWorker.set(true) }  
    fun clear() { isStreamWorker.set(false) }  
    fun isStreamWorker(): Boolean = isStreamWorker.get()  
}  
```  
  
> Virtual Thread에서도 `ThreadLocal`은 정상 동작한다.  
> 각 Virtual Thread는 고유한 ThreadLocal 저장소를 가진다.  
  
#### StreamDataSourceManager  
  
Stream 전용 `HikariDataSource`의 생성과 삭제를 담당한다.  
원본 Writer `HikariDataSource`의 JDBC URL, 인증 정보, Aurora 플러그인 설정을 복사하여 동일 DB에 연결한다.  
  
```kotlin  
@Component  
class StreamDataSourceManager(  
    @Qualifier("prepayAdminWriterHikariDataSource")  
    private val originalWriterPool: HikariDataSource,  
    @Value("\${redis.stream.campaign-promotion.db-pool.pool-size:20}")  
    private val streamPoolSize: Int,  
    @Value("\${redis.stream.campaign-promotion.db-pool.connection-timeout:3000}")  
    private val connectionTimeout: Long,  
    @Value("\${redis.stream.campaign-promotion.db-pool.leak-detection-threshold:3000}")  
    private val leakDetectionThreshold: Long  
) {  
    private val log = KotlinLogging.logger {}  
    private val streamPool = AtomicReference<HikariDataSource?>(null)  
  
    /**  
     * Stream 전용 DB Connection Pool 생성.  
     * 원본 Writer Pool의 연결 정보를 복사하여 동일 DB에 연결한다.  
     * 첫 번째 Context 활성화 시 1회만 호출된다.  
     */  
    fun createPool() {  
        if (streamPool.get() != null) {  
            log.warn { "[StreamDataSourceManager] Pool already exists, skipping creation" }  
            return  
        }  
  
        val pool = HikariDataSource().apply {  
            poolName = "stream-writer-pool"  
            jdbcUrl = originalWriterPool.jdbcUrl  
            username = originalWriterPool.username  
            password = originalWriterPool.password  
            driverClassName = originalWriterPool.driverClassName  
            maximumPoolSize = streamPoolSize  
            this.connectionTimeout = this@StreamDataSourceManager.connectionTimeout  
            this.leakDetectionThreshold = this@StreamDataSourceManager.leakDetectionThreshold  
            // Aurora JDBC Wrapper 설정 복사 (failover, efm 등)  
            dataSourceProperties = Properties().apply {  
                putAll(originalWriterPool.dataSourceProperties)  
            }  
        }  
        streamPool.set(pool)  
        log.info {  
            "[StreamDataSourceManager] Created stream pool" +  
            " - poolName=${pool.poolName}, maxSize=$streamPoolSize"  
        }  
    }  
  
    /**  
     * Stream 전용 DB Connection Pool 삭제.  
     * 마지막 Context 비활성화 시 호출된다.  
     * HikariDataSource.close()는 모든 유휴 커넥션을 즉시 반환하고,  
     * 사용 중인 커넥션은 반환 시점에 close된다.  
     */  
    fun destroyPool() {  
        val pool = streamPool.getAndSet(null)  
        if (pool != null) {  
            pool.close()  
            log.info { "[StreamDataSourceManager] Destroyed stream pool" }  
        }  
    }  
  
    /**  
     * 현재 활성화된 Stream 전용 Pool을 반환한다.  
     * Pool이 없으면 null (= 일반 Writer Pool 사용).  
     */  
    fun getStreamPool(): HikariDataSource? = streamPool.get()  
}  
```  
  
#### StreamAwareDataSourceProxy  
  
기존 Writer `DataSource`를 감싸는 프록시.  
`getConnection()` 호출 시 현재 스레드가 Stream Worker인지 확인하여  
Stream 전용 풀 또는 기존 Writer 풀로 분기한다.  
  
```kotlin  
class StreamAwareDataSourceProxy(  
    private val originalDataSource: DataSource,  
    private val streamPoolProvider: () -> DataSource?  
) : DelegatingDataSource(originalDataSource) {  
  
    override fun getConnection(): Connection {  
        return resolveDataSource().getConnection()  
    }  
  
    override fun getConnection(username: String, password: String): Connection {  
        return resolveDataSource().getConnection(username, password)  
    }  
  
    private fun resolveDataSource(): DataSource {  
        if (StreamWorkerContext.isStreamWorker()) {  
            streamPoolProvider()?.let { return it }  
        }  
        return originalDataSource  
    }}  
```  
  
> `DelegatingDataSource`는 Spring이 제공하는 DataSource 래퍼로,  
> 나머지 메서드(`getLoginTimeout`, `isWrapperFor` 등)는 원본에 위임한다.  
> Stream Pool이 null이면 (IDLE 상태) 원본 Writer 풀로 자연스럽게 fallback된다.  
  
#### PrepayAdminDbConfig 변경  
  
기존 Writer DataSource Bean을 분리하고 `StreamAwareDataSourceProxy`로 감싼다:  
  
```kotlin  
// PrepayAdminDbConfig 변경사항  
  
// 기존: prepayAdminWriterDataSource() 하나로 HikariDataSource 직접 반환  
// 변경: HikariDataSource Bean을 분리하고, Proxy로 감싸서 반환  
  
/**  
 * Writer용 HikariDataSource (raw pool).  
 * StreamDataSourceManager에서 연결 정보 복사 시에도 사용된다.  
 */  
@Bean(PREPAY_ADMIN_NAME_WRITER_HIKARI_DATASOURCE)  
@ConfigurationProperties(prefix = "persistence-rds-prepay-admin.datasource.writer")  
fun prepayAdminWriterHikariDataSource(): HikariDataSource {  
    return DataSourceBuilder.create().type(HikariDataSource::class.java).build()  
}  
  
/**  
 * Writer DataSource (Stream-aware proxy).  
 * DbRoutingDataSource에 이 Bean이 주입된다.  
 * Stream Worker 스레드 → Stream 전용 풀 / 일반 스레드 → 기존 Writer 풀.  
 */  
@Bean(PREPAY_ADMIN_NAME_MASTER_DATASOURCE)  
fun prepayAdminWriterDataSource(  
    @Qualifier(PREPAY_ADMIN_NAME_WRITER_HIKARI_DATASOURCE)  
    writerHikari: HikariDataSource,  
    streamDataSourceManager: StreamDataSourceManager  
): DataSource {  
    return StreamAwareDataSourceProxy(writerHikari) {  
        streamDataSourceManager.getStreamPool()  
    }  
}  
  
companion object {  
    // 기존 상수들에 추가  
    const val PREPAY_ADMIN_NAME_WRITER_HIKARI_DATASOURCE = "prepayAdminWriterHikariDataSource"  
}  
```  
  
변경 후 Bean 구조:  
```  
prepayAdminWriterHikariDataSource (HikariDataSource, raw pool) ←── NEW  
        │  
        ▼  
prepayAdminWriterDataSource (StreamAwareDataSourceProxy) ←── 변경 (기존 HikariDataSource → Proxy)  
        │  
        ├── Stream Worker → streamDataSourceManager.getStreamPool()  
        │                   (stream-writer-pool, 동적 생성/삭제)  
        │  
        └── 일반 스레드 → writerHikari (기존 Writer pool=5)  
  
prepayAdminReaderDataSource (HikariDataSource, 변경 없음)  
  
prepayAdminDbRoutingDataSource (DbRoutingDataSource, 변경 없음)  
├── WRITER → prepayAdminWriterDataSource (= StreamAwareDataSourceProxy)  
├── READER → prepayAdminReaderDataSource  
└── default → prepayAdminReaderDataSource  
  
prepayAdminDataSource (LazyConnectionDataSourceProxy, 변경 없음)  
prepayAdminEntityManagerFactory (변경 없음)  
prepayAdminTransactionManager (변경 없음)  
```  
  
> **기존 코드 영향 범위가 최소화된다:**  
> - `DbRoutingDataSource`는 WRITER 키로 `prepayAdminWriterDataSource`를 받는데, 타입이 `DataSource`이므로 Proxy여도 동일하게 동작  
> - `LazyConnectionDataSourceProxy`, `EntityManagerFactory`, `TransactionManager`는 변경 없음  
> - 기존의 모든 `@Transactional(PREPAY_ADMIN_TRANSACTION_MANAGER_NAME)` 코드는 수정 불필요  
  
#### StreamWorker에 ThreadLocal 적용  
  
```kotlin  
// StreamWorker.run() 내부  
override fun run() {  
    StreamWorkerContext.mark()  // Stream Worker 마킹  
    try {  
        while (running.get()) {  
            // ... XREADGROUP + 처리(saveResult, callMoneyApi, updateSuccess) + XACK ...  
        }  
    } finally {  
        StreamWorkerContext.clear()  // 마킹 해제 (반드시 finally에서)  
    }  
}  
```  
  
#### Orchestrator 통합  
  
`initializeContext()`와 `deactivate()`에 `StreamDataSourceManager` 호출을 추가한다:  
  
```kotlin  
@Component  
class CampaignStreamOrchestrator(  
    // ... 기존 의존성 ...  
    private val streamDataSourceManager: StreamDataSourceManager  // 추가  
) : DisposableBean {  
  
    private fun initializeContext(streamType: StreamType): StreamContext {  
        val config = streamType.toConfig()  
  
        // 0. Stream 전용 DB Pool 생성 (첫 번째 Context 활성화 시만 생성)  
        if (contexts.isEmpty()) {  
            streamDataSourceManager.createPool()  
        }  
  
        // 1. Consumer Group 생성  
        createConsumerGroup(config.streamKey, config.consumerGroup)  
  
        // 2. Worker 시작  
        val workerManager = workerManagerFactory.create(streamType)  
        workerManager.startAll()  
  
        // 3~4. Context 생성 + 백그라운드 스레드 시작  
        // ... (기존 코드와 동일)  
    }  
  
    private fun deactivate(streamType: StreamType) {  
        val context = contexts.remove(streamType) ?: return  
  
        // 1. Worker 종료 (모든 Worker가 DB 작업 완료 후 멈춤)  
        context.workerManager.stopAll()  
  
        // 2. 백그라운드 스레드 종료  
        context.backgroundThreads.forEach { it.interrupt() }  
  
        // 3. Stream 전용 DB Pool 삭제 (마지막 Context 비활성화 시만 삭제)  
        if (contexts.isEmpty()) {  
            streamDataSourceManager.destroyPool()  
        }  
  
        log.info { "[Orchestrator] Deactivated $streamType" }  
    }  
}  
```  
  
> **순서가 중요하다**:  
> - 활성화: Pool 생성 → Worker 시작 (Pool이 준비된 후 Worker가 DB 접근)  
> - 비활성화: Worker 종료(stopAll 대기) → Pool 삭제 (사용 중인 커넥션이 없는 상태에서 삭제)  
  
#### Pool 크기 설정  
  
| 시나리오 | 기존 Writer Pool | Stream Writer Pool | 예상 동시 커넥션 | 여유율 |  
|---------|:-:|:-:|:-:|:-:|  
| Stream 미활성 (IDLE) | 5 | (없음) | ~1-2 | 충분 |  
| 1개 StreamType (32 Workers) | 5 (변경 없음) | **20** | avg ~10, peak ~16 | 25% |  
| 2개 StreamType (64 Workers) | 5 (변경 없음) | **30** | avg ~19, peak ~28 | 7% |  
  
> 2개 StreamType 동시 활성 시 피크가 ~28이므로, `pool-size`를 **30**으로 설정하는 것을 권장한다.  
> Stream Pool은 Stream Worker만 사용하므로, 기존 Writer Pool(5)과 합산할 필요 없이 독립적으로 산정한다.  
  
#### 설정 (redis.yml)  
  
```yaml  
redis:  
  stream:  
    campaign-promotion:  
      db-pool:  
        pool-size: 20                    # Stream 전용 Pool 크기  
        connection-timeout: 3000         # 커넥션 획득 대기 시간 (ms)  
        leak-detection-threshold: 3000   # 커넥션 누수 감지 (ms)  
```  
  
#### Aurora MySQL 서버 커넥션 한계 검증  
  
```  
Aurora MySQL max_connections 기본값:  
- db.r6g.large (2 vCPU, 16GB): ~1,000  
- db.r6g.xlarge (4 vCPU, 32GB): ~2,000  
  
인스턴스 4대 × (기존 Pool 5 + Stream Pool 20) = 100 커넥션  
→ Aurora max_connections(1,000~2,000) 대비 5~10% 수준 — 충분한 여유  
  
참고: 다른 DataSource (member, money, voucher 등)는 Reader 전용이거나  
Stream Worker가 접근하지 않으므로 Pool 크기 변경 불필요  
```  
  
#### 향후 Bulk 처리 시 영향  
  
현재 단건 처리 방식에서 Bulk 처리 (DB 1회 → Money API N회 → DB 1회)로 전환하면:  
  
```  
현재 (단건): Worker 1개가 메시지 1건당 DB 2회 접근  
→ 32 Workers × 메시지당 DB 60ms → 동시 ~10 커넥션  
  
Bulk (10건 묶음): Worker 1개가 메시지 10건당 DB 2회 접근  
→ 32 Workers × 배치당 DB 60ms (INSERT/UPDATE도 Batch) → 동시 ~10 커넥션  
→ 단, 처리량은 ~5배 증가 (Money API 병렬 호출)  
→ DB 접근 빈도가 1/10로 감소 → pool-size를 줄일 수 있음  
```  
  
Bulk 처리 전환 시 `pool-size`를 `20 → 10` 수준으로 낮출 수 있다.  
  
---  
  
## 10. 성능 추정  
  
### 10.1 단일 인스턴스  
  
```  
전제:  
- 메시지 1건 처리: ~200ms (Money API 호출이 지배적)  
- Worker 수: 32개 (Virtual Threads)  
  
계산:  
- 1 Worker = 200ms당 1건 = 초당 5건  
- 32 Workers = 초당 160건  
  
100만건 처리:  
- 1,000,000 / 160 = 6,250초 = 약 104분  
```  
  
### 10.2 다중 인스턴스 (4 인스턴스)  
  
```  
전제:  
- 인스턴스 4대, 각각 32 Workers  
- 동일 Consumer Group으로 Redis Stream 공유  
  
계산:  
- 4 인스턴스 × 160건/s = 초당 640건  
- 1,000,000 / 640 = 1,562초 = 약 26분 ✓  
  
목표 달성: 100만건 / 26분 (목표: 20~30분)  
```  
  
### 10.3 Worker 수에 따른 처리 시간 추정  
  
| Workers (전체) | 초당 처리량 | 100만건 처리 시간 |  
|:-:|:-:|:-:|  
| 16 | 80건/s | ~3.5시간 |  
| 32 | 160건/s | ~104분 |  
| 64 | 320건/s | ~52분 |  
| **128** | **640건/s** | **~26분** |  
| 256 | 1,280건/s | ~13분 |  
  
> **주의**: Worker 수를 무한히 늘릴 수 없다.  
> - Money API 서버의 동시 요청 처리 한계  
> - DB 커넥션 풀 크기 제한  
> - Redis 연결 수 제한  
>  
> **Money API의 허용 동시 요청 수를 확인한 후 Worker 수를 결정해야 한다.**  
  
### 10.4 병목 이동 예상  
  
Worker 수를 늘리면 병목이 다른 곳으로 이동할 수 있다.  
  
| Worker 수 | 병목 지점 | 대응 |  
|:-:|------|------|  
| ~32 | Money API 응답 시간 | 정상 범위 |  
| ~64 | DB 커넥션 풀 고갈 가능 | Stream 전용 DataSource `pool-size` 증가 (9.5절) |  
| ~128 | Money API 동시 요청 한계 | Money 팀과 협의, rate limit 확인 |  
| ~256+ | ElastiCache 연결 수/CPU 한계 | 노드 타입 확인, CloudWatch EngineCPUUtilization 모니터링 |  
  
---  
  
## 11. 모니터링  
  
### 11.1 핵심 메트릭 (Application)  
  
```kotlin  
@Component  
class StreamMetricsCollector(  
    @Qualifier("streamRedisTemplate")  
    private val redisTemplate: StringRedisTemplate,  
    private val meterRegistry: MeterRegistry  
) {  
    @Scheduled(fixedRate = 30_000) // 30초마다  
    fun collectMetrics() {  
        collectStreamMetrics(  
            CampaignStreamConstants.VOUCHER_STREAM_KEY,  
            CampaignStreamConstants.VOUCHER_CONSUMER_GROUP,  
            "voucher"  
        )  
        collectStreamMetrics(  
            CampaignStreamConstants.POINT_STREAM_KEY,  
            CampaignStreamConstants.POINT_CONSUMER_GROUP,  
            "point"  
        )  
    }  
  
    private fun collectStreamMetrics(streamKey: String, group: String, type: String) {  
        // Stream 길이 (백로그)  
        val streamLen = redisTemplate.opsForStream().size(streamKey) ?: 0  
        meterRegistry.gauge("campaign.stream.length", Tags.of("type", type), streamLen)  
  
        // Pending 메시지 수  
        val pending = redisTemplate.opsForStream().pending(streamKey, group)  
        meterRegistry.gauge(  
            "campaign.stream.pending",  
            Tags.of("type", type),  
            pending.totalPendingMessages  
        )  
  
        // DLQ 길이  
        val dlqKey = if (type == "voucher")  
            CampaignStreamConstants.VOUCHER_DLQ_STREAM_KEY  
        else  
            CampaignStreamConstants.POINT_DLQ_STREAM_KEY  
        val dlqLen = redisTemplate.opsForStream().size(dlqKey) ?: 0  
        meterRegistry.gauge("campaign.stream.dlq.length", Tags.of("type", type), dlqLen)  
    }  
}  
```  
  
### 11.2 CloudWatch 메트릭 (ElastiCache)  
  
ElastiCache에서 제공하는 CloudWatch 메트릭으로 Redis 인프라 수준의 모니터링을 구성한다.  
  
| CloudWatch 메트릭 | 알람 조건 | 의미 |  
|-------------------|----------|------|  
| `DatabaseMemoryUsagePercentage` | > 70% Warning, > 85% Critical | Stream 백로그 과다 또는 메모리 누수 |  
| `EngineCPUUtilization` | > 65% Warning, > 80% Critical | 처리 부하 과다, Worker 수 조절 필요 |  
| `CurrConnections` | > 1,000 | 연결 수 이상 증가 |  
| `NetworkBytesIn` / `NetworkBytesOut` | 급증 시 | 트래픽 패턴 변화 감지 |  
| `ReplicationLag` | > 1s | Replica 지연, Failover 시 데이터 유실 위험 |  
| `CommandsProcessed` | - | Stream 명령어 처리량 트렌드 |  
| `Evictions` | > 0 | **긴급** - maxmemory-policy에 의한 키 제거 발생 |  
  
> `Evictions > 0` 알람은 반드시 설정해야 한다. Stream 키가 eviction되면 데이터 유실이 발생한다.  
  
### 11.3 Application 모니터링 대시보드 항목  
  
| 메트릭 | 알람 조건 | 의미 |  
|--------|----------|------|  
| `campaign.stream.length` | > 50,000 | 처리 속도가 유입 속도를 따라가지 못함 |  
| `campaign.stream.pending` | > 1,000 | Worker 장애 또는 처리 지연 |  
| `campaign.stream.dlq.length` | > 0 | 재시도 초과 실패 메시지 발생 |  
| Worker 스레드 active count | = 0 | Worker 전체 중단 |  
  
### 11.4 운영 Redis CLI 명령어  
  
```bash  
# Stream 길이 확인  
XLEN campaign:promotion:voucher:stream  
  
# Consumer Group 상태 확인  
XINFO GROUPS campaign:promotion:voucher:stream  
  
# 각 Consumer별 상태 확인  
XINFO CONSUMERS campaign:promotion:voucher:stream campaign-voucher-worker-group  
  
# Pending 메시지 요약  
XPENDING campaign:promotion:voucher:stream campaign-voucher-worker-group  
  
# Pending 메시지 상세 (상위 10건)  
XPENDING campaign:promotion:voucher:stream campaign-voucher-worker-group - + 10  
  
# DLQ 확인  
XLEN campaign:promotion:voucher:dlq  
XRANGE campaign:promotion:voucher:dlq - + COUNT 10  
  
# 메모리 사용량 확인 (ElastiCache에서 사용 가능)  
INFO memory  
  
# Stream별 메모리 사용량 확인  
MEMORY USAGE campaign:promotion:voucher:stream  
  
# 클라이언트 연결 수 확인  
INFO clients  
```  
  
> **주의**: ElastiCache에서는 `redis-cli`로 직접 접속 시 VPC 내부에서만 가능하다.  
> EC2 bastion 호스트 또는 VPN을 통해 접속해야 한다.  
  
---  
  
## 12. 마이그레이션 전략  
  
### 12.1 단계별 적용 계획  
  
```  
Phase 0: ElastiCache 사전 확인 (필수)  
├── ElastiCache 노드 타입 및 가용 메모리 확인  
├── maxmemory-policy 확인 (noeviction 또는 volatile-lru 필수)  
│   └── 변경 필요 시 Parameter Group 수정 → 재부팅 불필요 (즉시 적용)  
├── 현재 메모리 사용량 확인 (INFO memory)  
├── Stream 사용에 따른 메모리 여유분 산정  
└── 예상 기간: 0.5일  
  
Phase 1: 인프라 준비  
├── commons-pool2 의존성 추가  
├── StreamRedisConfig 생성 (커넥션 풀 + StringRedisTemplate)  
├── 기존 RedisTemplateConfig에 @Primary 추가  
├── 개발 환경에서 Redis Stream 연결 확인  
└── 예상 기간: 1일  
  
Phase 2: 핵심 컴포넌트 구현  
├── CampaignStreamOrchestrator (Lazy Init, 발행, Worker 관리, Scheduler 통합)  
├── StreamWorker + StreamWorkerManager + StreamWorkerManagerFactory  
├── StreamFailureHandler  
├── StreamDataSourceManager + StreamAwareDataSourceProxy + StreamWorkerContext  
├── PrepayAdminDbConfig 변경 (Writer HikariDataSource Bean 분리 + Proxy 래핑)  
├── CampaignStreamConstants, StreamType, StreamContext  
└── 예상 기간: 3일  
  
Phase 3: Kafka Listener 전환  
├── 기존 Listener에 Feature Toggle 적용  
│   ├── toggle ON  → Orchestrator 경유 (Redis Stream 병렬 처리)  
│   └── toggle OFF → 기존 직접 처리 (fallback)  
├── 기존 프로세서 코드는 변경하지 않음  
└── 예상 기간: 1일  
  
Phase 4: 운영 컴포넌트 추가  
├── StreamMetricsCollector  
├── CloudWatch 알람 설정 (Evictions, MemoryUsage, CPU)  
└── 예상 기간: 1일  
  
Phase 5: 테스트 및 검증  
├── 개발 환경에서 1만건 처리 테스트  
├── Worker 수 조절에 따른 처리량 검증  
├── 장애 시나리오 테스트 (Worker 강제 종료 등)  
├── ElastiCache 메모리 사용량 모니터링 (CloudWatch)  
├── ElastiCache Failover 시나리오 테스트  
└── 예상 기간: 2일  
  
Phase 6: 운영 배포  
├── ElastiCache Parameter Group 확인 (maxmemory-policy)  
├── CloudWatch 알람 설정 (Evictions, MemoryUsage, CPU)  
├── staging 환경 배포 및 검증  
├── production 배포 (Feature Toggle ON)  
├── 모니터링 및 Worker 수 튜닝  
└── 기존 직접 처리 코드 제거 (안정화 후)  
```  
  
### 12.2 Feature Toggle  
  
5.3절의 Kafka Listener 변경과 동일하다.  
`redis.stream.campaign-promotion.enabled` 설정값에 따라 Orchestrator 경유 또는 기존 직접 처리를 선택한다.  
  
```yaml  
# Feature Toggle (redis.yml)  
redis:  
  stream:  
    campaign-promotion:  
      enabled: true   # true → Orchestrator 경유 (Redis Stream 병렬 처리)  
                      # false → 기존 직접 처리 (fallback)  
```  
  
> 상세 코드는 5.3절 참고  
  
### 12.3 롤백 계획  
  
문제 발생 시 `redis.stream.campaign-promotion.enabled=false`로 변경하면 즉시 기존 방식으로 롤백된다.  
  
```yaml  
# 긴급 롤백 (redis.yml)  
redis:  
  stream:  
    campaign-promotion:  
      enabled: false  # Redis Stream 비활성화 → 기존 직접 처리로 복귀  
```  
  
---  
  
## 참고  
  
### 변경되는 컴포넌트  
  
| 컴포넌트 | 변경 사항 |  
|---------|----------|  
| `CampaignVoucherPromotionListener` | Stream 발행 로직 추가 (Feature Toggle) |  
| `CampaignPointPromotionListener` | Stream 발행 로직 추가 (Feature Toggle) |  
| `RedisTemplateConfig` | `@Primary` 추가 (Stream 전용 ConnectionFactory와의 Bean 충돌 방지) |  
| `PrepayAdminDbConfig` | Writer `HikariDataSource` Bean 분리 + `StreamAwareDataSourceProxy`로 래핑 |  
  
### 신규 컴포넌트  
  
| 컴포넌트 | 역할 |  
|---------|------|  
| `CampaignStreamOrchestrator` | **핵심** - Lazy Init, Stream 발행, Worker 라이프사이클, Idle Timeout 총괄 |  
| `CampaignStreamConstants` | Stream key, Consumer Group 이름 등 상수 |  
| `StreamType` / `StreamContext` | Stream 타입별 상태 관리 enum/data class |  
| `StreamWorkerManager` | 특정 Stream 타입의 Worker 풀 관리 (start/stop) |  
| `StreamWorkerManagerFactory` | StreamWorkerManager 생성 팩토리 |  
| `StreamWorker` | 개별 Worker 스레드 (XREADGROUP + 처리 + XACK) |  
| `StreamFailureHandler` | 실패 처리 + DLQ 이동 |  
| `StreamRedisConfig` | Stream 전용 ConnectionFactory(커넥션 풀) + StringRedisTemplate |  
| `StreamDataSourceManager` | Stream 전용 DB Connection Pool 동적 생성/삭제 |  
| `StreamAwareDataSourceProxy` | Stream Worker 스레드 감지 → Stream 전용 Pool로 라우팅 |  
| `StreamWorkerContext` | Stream Worker 스레드 식별용 ThreadLocal |  
| `StreamMetricsCollector` | 모니터링 메트릭 수집 |  
| `CampaignStreamProperties` | Stream 설정 (idle-timeout, idle-check-interval 포함) |  
| `CampaignStreamWorkerProperties` | Worker 설정 |  
  
### 제거된 컴포넌트 (이전 설계 대비)  
  
| 컴포넌트 | 제거 이유 |  
|---------|----------|  
| ~~`CampaignStreamInitializer`~~ | Orchestrator가 lazy하게 초기화하므로 앱 시작 시 초기화 불필요 |  
| ~~`CampaignStreamPublisher`~~ | Orchestrator가 발행 기능을 내장 |  
| ~~`CampaignVoucherStreamWorkerFactory`~~ | 통합 `StreamWorkerManagerFactory`로 대체 |  
| ~~`CampaignPointStreamWorkerFactory`~~ | 통합 `StreamWorkerManagerFactory`로 대체 |  
| ~~`StreamPendingRecoveryScheduler`~~ | Orchestrator 내부 `startPendingRecovery()` Virtual Thread로 통합 |  
| ~~`StreamMaintenanceScheduler`~~ | Orchestrator 내부 `startStreamTrimmer()` Virtual Thread로 통합 |  
  
### 변경하지 않는 컴포넌트  
  
| 컴포넌트 | 이유 |  
|---------|------|  
| `AbstractCampaignPromotionProcessor` | 기존 비즈니스 로직 그대로 재사용 |  
| `CampaignPromotionVoucherProcessor` | Worker가 기존 `process()` 호출 |  
| `CampaignPromotionPointProcessor` | Worker가 기존 `process()` 호출 |  
| `CampaignPromotionResultUpdateService` | 변경 불필요 |  
| `MoneyCampaignChargeApi` | 변경 불필요 |  
| `CampaignPromotionStatusCacheService` | 변경 불필요 |