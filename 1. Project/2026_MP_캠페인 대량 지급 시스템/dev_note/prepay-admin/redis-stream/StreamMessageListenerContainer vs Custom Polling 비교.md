## 1. 개요  
  
### 1.1 배경  
  
Phase 7에서 `StreamMessageListenerContainer`(고수준 API)를 `Custom Polling Loop`(저수준 API)로 전환하였다.  
이후 Container 기반 구현도 병렬로 작성하여 두 방식을 비교 검증하였다.  
  
이 문서는 ElastiCache Valkey 환경에서 두 방식의 구조적 차이, 장단점, 최종 판단 근거를 정리한다.  
  
### 1.2 구현 파일  
  
| 방식 | 주요 클래스 |  
|------|------------|  
| 고수준 (Container) | `DynamicStreamContainerManager`, `ContainerConsumerRegistry`, `ContainerStreamManager`, `ContainerConsumerContext` |  
| 저수준 (Custom Polling) | `PromotionStreamManager`, `PromotionConsumerRegistry`, `PromotionConsumerContext` |  
| 공통 | `PromotionStreamConsumer`, `PromotionStreamProducer`, `RedisStreamProperties` |  
  
---  
  
## 2. 아키텍처 비교  
  
### 2.1 고수준 — StreamMessageListenerContainer  
  
```  
ContainerStreamManager (오케스트레이터)  
  └─> DynamicStreamContainerManager  
      └─> StreamMessageListenerContainer.create(connectionFactory, options)  
          └─> container.receive(Consumer, StreamOffset, listener)  ×N개  
          └─> container.start()  
      └─> ScheduledExecutorService (idle monitor, 5초 간격)  
          └─> 모든 subscription idle → onIdleStop 콜백  
```  
  
- Spring의 `StreamPollTask`가 내부적으로 `do-while` 루프 실행  
- `pollTimeout(Duration.ZERO)` → non-blocking XREADGROUP (BLOCK 파라미터 없음)  
- `Subscription` 객체로 구독 관리  
  
### 2.2 저수준 — Custom Polling Loop  
  
```  
PromotionStreamManager (오케스트레이터)  
  └─> Executors.newThreadPerTaskExecutor(virtualThreadFactory)  
      └─> executor.submit(pollingTask)  ×N개  
          └─> while (!stopFlag)  
              └─> xReadGroup() (non-blocking)  
              └─> 메시지 있음: consumer.processMessage() + lastMessageTime 갱신  
              └─> 메시지 없음: idle 체크 → Thread.sleep(pollIntervalMs)  
```  
  
- 직접 작성한 `while` 루프  
- 빈 poll 시 `Thread.sleep(pollIntervalMs)` (기본 100ms) 로 busy-wait 방지  
- `AtomicBoolean(stopFlag)` + `Future.cancel(true)` 로 종료 제어  
  
---  
  
## 3. 상세 비교  
  
### 3.1 폴링 전략  
  
| | 고수준 (Container) | 저수준 (Custom Polling) |  
|---|---|---|  
| 폴링 구현 | Spring `StreamPollTask` 내부 루프 | 직접 작성 `while` 루프 |  
| XREADGROUP 호출 | Container 내부 `RedisTemplate.execute()` | `StringRedisTemplate.xReadGroup()` 직접 호출 |  
| 빈 poll 대기 | `Thread.sleep(0, 1)` — **1ns (busy loop)** | `Thread.sleep(pollIntervalMs)` — **100ms** |  
| 초당 Redis 호출 (빈 poll, consumer당) | ~수천 회 | ~10회 |  
| BLOCK 사용 | 불가 (ElastiCache 제약) | 불가 (동일 제약) |  
| poll 간격 커스터마이징 | 불가 (Container 내부 동작) | `pollIntervalMs` 프로퍼티로 제어 |  
| 에러 시 동작 | `ErrorHandler` 콜백 (기본: 로그) | `catch` 블록에서 직접 제어 + sleep |  
  
### 3.2 Shutdown 흐름  
  
| | 고수준 (Container) | 저수준 (Custom Polling) |  
|---|---|---|  
| 중지 신호 | `subscription.cancel()` + `container.stop()` | `stopFlag.set(true)` + `future.cancel(true)` |  
| 완료 대기 | `container.stop()` 동기 반환 | `executor.awaitTermination(5s)` 명시적 대기 |  
| interrupt 처리 | `idleMonitor.shutdown()` (not shutdownNow) 으로 interrupt 회피 | `Thread.interrupted()` 로 flag 클리어 후 cleanup |  
| Stream 정리 순서 | `container.stop()` → `cleanupStream()` | `stopFlag` → `cancel` → `awaitTermination` → `Thread.interrupted()` → `cleanupStream()` |  
  
**Shutdown 시 주의사항 (Container 방식):**  
  
idle monitor 콜백에서 shutdown이 트리거될 때:  
- `idleMonitor.shutdownNow()` 사용 시 → 현재 스레드(idle monitor)에 interrupt → 이후 Redis 명령 실패  
- `container.stop()` 전에 `cleanupStream()` 실행 시 → 폴링 스레드가 삭제된 stream에 XREADGROUP → NOGROUP 에러  
- **해결**: `idleMonitor.shutdown()` (not shutdownNow) + `container.stop()` 먼저 실행 후 `cleanupStream()`  
  
### 3.3 Idle 감지  
  
| | 고수준 (Container) | 저수준 (Custom Polling) |  
|---|---|---|  
| 감지 위치 | 별도 `ScheduledExecutorService` (idle monitor) | 각 polling task 내부 |  
| 감지 주체 | idle monitor가 모든 subscription 일괄 확인 | 개별 consumer가 자신의 idle 감지 |  
| 체크 간격 | 5초 고정 (scheduleAtFixedRate) | 빈 poll마다 (~100ms 간격) |  
| 활동 추적 | `AtomicReference<Instant>` per subscription | `AtomicLong(lastMessageTime)` 공유 |  
| idle 판정 | **모든** subscription이 idle → 콜백 | **첫 번째** idle consumer가 `onIdleStop` 호출 |  
  
### 3.4 상태 관리 (Context)  
  
```kotlin  
// 고수준 — 동시성 프리미티브가 DynamicStreamContainerManager 내부에 캡슐화  
data class ContainerConsumerContext(  
    val containerManager: DynamicStreamContainerManager,  
    val streamKey: String,  
    val consumerGroup: String,  
    val consumerNames: List<String>,  
    val streamRedisTemplate: StringRedisTemplate,  
    val startedAt: Instant,  
)  
  
// 저수준 — 동시성 상태를 직접 관리  
data class PromotionConsumerContext(  
    val pollingFutures: List<Future<*>>,  
    val stopFlag: AtomicBoolean,  
    val lastMessageTime: AtomicLong,  
    val executor: ExecutorService,  
    val streamKey: String,  
    val consumerGroup: String,  
    val consumerNames: List<String>,  
    val streamRedisTemplate: StringRedisTemplate,  
    val startedAt: Instant,  
)  
```  
  
---  
  
## 4. 장단점 요약  
  
### 4.1 고수준 (StreamMessageListenerContainer)  
  
**장점:**  
- Spring 공식 API — `Subscription` 기반 선언적 구독/해제  
- `container.stop()` 한 번으로 N개 consumer 일괄 중지 (atomic)  
- Context가 단순 (동시성 프리미티브가 Manager 내부에 캡슐화)  
- `ErrorHandler` 인터페이스로 표준화된 에러 핸들링 파이프라인  
  
**단점:**  
- `pollTimeout(Duration.ZERO)` 시 **busy loop** — ElastiCache에서 BLOCK 불가이므로 회피 불가  
- poll 간격 커스터마이징 불가 (Container 내부 `StreamPollTask` 동작에 의존)  
- 동적 생성/파기를 위한 래퍼 클래스(`DynamicStreamContainerManager`) 필요  
- shutdown 시 경쟁 조건 주의 필요 (interrupt, NOGROUP)  
  
### 4.2 저수준 (Custom Polling)  
  
**장점:**  
- `Thread.sleep(pollIntervalMs)` 로 poll 간격 제어 → Redis 부하 관리  
- 에러 핸들링, retry sleep 등 모든 동작 직접 제어  
- 외부 라이브러리 내부 동작에 의존하지 않음  
- 래퍼 클래스 불필요 — Manager가 직접 executor/task 관리  
  
**단점:**  
- 동시성 코드 직접 작성 (`stopFlag`, `Future`, `executor`, `interrupt` 처리)  
- Context에 동시성 프리미티브 노출 (9개 필드)  
- polling loop 로직을 직접 유지보수  
  
---  
  
## 5. 코드량 비교  
  
| | 고수준 (Container) | 저수준 (Custom Polling) |  
|---|---|---|  
| Manager (오케스트레이터) | `ContainerStreamManager` (~140줄) | `PromotionStreamManager` (~200줄) |  
| Container/Polling 래퍼 | `DynamicStreamContainerManager` (~135줄) | 없음 (Manager에 포함) |  
| Registry | `ContainerConsumerRegistry` (~89줄) | `PromotionConsumerRegistry` (~99줄) |  
| Context | `ContainerConsumerContext` (~13줄) | `PromotionConsumerContext` (~20줄) |  
| **합계** | **~377줄 (4파일)** | **~319줄 (3파일)** |  
  
고수준 방식이 Container를 감싸기 위한 `DynamicStreamContainerManager` 추가로 오히려 파일 수와 코드량이 증가하였다.  
  
---  
  
## 6. 판단  
  
### 6.1 핵심 제약: ElastiCache Valkey의 XREADGROUP BLOCK 거부  
  
`StreamMessageListenerContainer`의 핵심 가치는 `BLOCK` 기반 효율적 폴링이다.  
`pollTimeout`을 non-zero로 설정하면 내부적으로 `XREADGROUP ... BLOCK <ms>`가 실행되어, 메시지가 없을 때 서버 측에서 대기하여 불필요한 네트워크 왕복을 제거한다.  
  
그러나 **ElastiCache Valkey는 신규 커넥션의 XREADGROUP BLOCK을 거부**하므로, `pollTimeout(Duration.ZERO)` (non-blocking)으로만 사용 가능하다.  
이 경우 Container 내부의 `StreamPollTask`는 `Thread.sleep(0, 1)` (1ns) 간격의 tight loop으로 동작하며, poll 간격을 제어할 수 없다.  
  
### 6.2 결론  
  
| 기준 | 판단 |  
|------|------|  
| Redis 부하 | 저수준 우세 — `pollIntervalMs` 로 poll 간격 제어 |  
| 코드 복잡도 | 동등 — 고수준은 래퍼 클래스 추가로 상쇄 |  
| 제어 가능성 | 저수준 우세 — 에러 핸들링, sleep, idle 체크 모두 직접 제어 |  
| Spring 생태계 통합 | 고수준 우세 — 하지만 동적 생성 시 이점 제한적 |  
| 유지보수성 | 동등 — 두 방식 모두 이해하기 어렵지 않은 수준 |  
  
**ElastiCache 환경에서는 저수준 Custom Polling이 더 적합하다.**  
고수준 API의 가장 큰 장점(BLOCK 기반 효율적 폴링)을 활용할 수 없고, 나머지 장점(Subscription 추상화, atomic stop)은 저수준 방식에서도 충분히 달성 가능하기 때문이다.