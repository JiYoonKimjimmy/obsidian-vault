# 캠페인 프로모션 대량 처리 시스템 구현 계획

## 1. 개요

### 1.1 목적

캠페인 프로모션(포인트/상품권) 대량 지급 배치 시스템의 **Publisher** 역할을 구현합니다.

### 1.2 구현 범위

| 구분              | 범위                                                     | 비고                |
|-----------------|--------------------------------------------------------|-------------------|
| **해당 프로젝트**     | Enum, DTO/RowMapper, Publisher Batch Job, Kafka 인프라 확장 | prepay-batch      |
| **제외 (타 프로젝트)** | Kafka Consumer, Retry Consumer, Money API Client       | prepay-consumer 등 |

### 1.3 설계 원칙

- **JPA Repository 사용 안함** - 프로젝트 방향성에 따라 JdbcTemplate 기반으로 구현
- **Entity 클래스 불필요** - DTO + RowMapper 패턴 사용

---

## 2. 모듈 구조

### 2.1 support (Enum 클래스)

```
support/src/main/java/.../batch/support/constant/prepay/admin/
├── PromotionType.java          (VOUCHER, POINT)
├── PromotionStatus.java        (READY, IN_PROGRESS, COMPLETED, STOPPED, FAILED)
├── PublishStatus.java          (PENDING, PUBLISHED, FAILED)
└── ProcessStatus.java          (SUCCESS, RETRYING, FAILED)
```

### 2.2 application/batch (Publisher Batch Job)

```
application/batch/src/main/java/.../batch/
├── decider/
│   └── PromotionTypeDecider.java              (VOUCHER/POINT 분기 - JobExecutionDecider, Plain class)
│
├── job/campaign/
│   ├── CampaignPromotionPublisherBatch.java   (메인 Job + Step Flow 정의)
│   ├── step/                                  (Step 클래스 - @Configuration)
│   │   ├── VoucherWorkerStep.java             (Voucher Worker Step 정의)
│   │   └── PointWorkerStep.java               (Point Worker Step 정의)
│   ├── reader/                                (Plain class)
│   │   ├── VoucherWorkerReader.java           (Voucher ItemReader 생성)
│   │   └── PointWorkerReader.java             (Point ItemReader 생성)
│   ├── processor/                             (Plain class)
│   │   ├── VoucherWorkerProcessor.java        (Voucher Kafka 발행)
│   │   └── PointWorkerProcessor.java          (Point Kafka 발행)
│   ├── writer/                                (Plain class)
│   │   ├── VoucherWorkerWriter.java           (Voucher 상태 업데이트)
│   │   └── PointWorkerWriter.java             (Point 상태 업데이트)
│   ├── partitioner/
│   │   └── CampaignPromotionPartitioner.java  (공통 Partitioner - @JobScope @Component)
│   └── tasklet/
│       ├── CampaignPromotionInitTasklet.java  (Init Tasklet)
│       └── CampaignPromotionFinalizeTasklet.java (Finalize Tasklet)
│
└── dto/campaign/
    ├── CampaignPromotionDto.java              (프로모션 DTO)
    ├── CampaignPromotionRowMapper.java        (프로모션 RowMapper)
    ├── CampaignVoucherTargetDto.java          (바우처 대상 DTO - 상태 변경용)
    ├── CampaignVoucherTargetRowMapper.java    (바우처 RowMapper)
    ├── CampaignPointTargetDto.java            (포인트 대상 DTO - 상태 변경용)
    └── CampaignPointTargetRowMapper.java      (포인트 RowMapper)
```

### 2.3 infrastructure/kafka (Kafka 확장)

```
infrastructure/kafka/src/main/java/.../kafka/
├── type/PocketEventType.java                  (CAMPAIGN_PROMOTION_VOUCHER_PUBLISH, CAMPAIGN_PROMOTION_POINT_PUBLISH 추가)
├── config/properties/EventProperty.java       (campaign topic 추가)
└── dto/campaign/
    ├── CampaignVoucherMessagePayload.java
    └── CampaignPointMessagePayload.java
```

---

## 3. 배치 Job 흐름

### 3.0 전체 흐름 다이어그램 (루프 구조)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                        CampaignPromotionPublisherJob                                 │
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 1. InitStep (Tasklet)                                                       │    │
│  │    - READY 상태 & 예약일시 조건 프로모션 목록 조회                                   │    │
│  │    - promotion_status: READY → IN_PROGRESS                                  │    │
│  │    - campaign_promotion_summary INSERT                                      │    │
│  │    - ExecutionContext에 promotionId, partition_count 전달                     │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                       ↓                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │ 2. PromotionTypeDecider (JobExecutionDecider)                               │    │
│  │    - promotionId=0 → "NONE" 반환 (Job 종료)                                   │    │
│  │    - promotion_type 조회 → VOUCHER / POINT 분기                               │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                          ↙           │            ↘                                  │
│  ┌─────────────────────────┐        │       ┌─────────────────────────┐             │
│  │ 3a. VoucherPublishStep  │        │       │ 3b. PointPublishStep    │             │
│  │     (Partitioned)       │        │       │     (Partitioned)       │             │
│  └────────────┬────────────┘        │       └────────────┬────────────┘             │
│               │                      │                    │                          │
│               ▼                      │                    ▼                          │
│  ┌─────────────────────────┐        │       ┌─────────────────────────┐             │
│  │ 4a. FinalizeStep        │        │       │ 4b. FinalizeStep        │             │
│  │  - COMPLETED 상태 변경   │        │       │  - COMPLETED 상태 변경   │             │
│  │  - context 초기화        │        │       │  - context 초기화        │             │
│  └────────────┬────────────┘        │       └────────────┬────────────┘             │
│               │                      │                    │                          │
│               └──────────────────────┼────────────────────┘                          │
│                                      │                                               │
│                          ┌───────────▼───────────┐                                   │
│                          │    다음 프로모션 처리    │                                   │
│                          │   InitStep으로 돌아감   │                                   │
│                          └───────────────────────┘                                   │
│                                      │                                               │
│                                      │ (NONE: 더 이상 처리할 프로모션 없음)              │
│                                      ▼                                               │
│                          ┌───────────────────────┐                                   │
│                          │        Job 종료        │                                   │
│                          └───────────────────────┘                                   │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 InitStep

- 외부 스케줄러(Jenkins)가 **1분 단위**로 배치를 호출하면, 현재 시간과 예약 일시(`reservation_at`)가 일치하는 프로모션 목록을 조회하여 처리
  - 캠페인 프로모션 기본 정보 DB 테이블: `prepay_admin.campaign_promotions`
  - 예약 일시 비교: 분 단위까지 일치 (`yyyyMMddHHmm` 형식)
- **루프 구조**: 한 번의 Job 실행에서 여러 프로모션을 우선순위대로 순차 처리
- 처리할 프로모션이 없으면 `promotionId=0` 설정 → `NONE` 분기로 Job 종료

#### 처리 흐름 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           InitStep 처리 흐름                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ 1. 예약 일시 도래 프로모션 목록 조회                                    │    │
│  │    SELECT * FROM campaign_promotions                            │    │
│  │    WHERE promotion_status = 'READY'                             │    │
│  │      AND DATE_FORMAT(reservation_at, '%Y%m%d%H%i') = ?          │    │
│  │    (현재 시간: yyyyMMddHHmm 형식)                                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    ↓                                    │
│                           (프로모션별 반복 처리)                             │
│                                    ↓                                    │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ 2. 프로모션 상태 업데이트                                             │    │
│  │    UPDATE campaign_promotions                                   │    │
│  │    SET promotion_status = 'IN_PROGRESS'                         │    │
│  │    WHERE promotion_id = ?                                       │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    ↓                                    │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ 3. Summary 데이터 생성                                             │    │
│  │    INSERT INTO campaign_promotion_summary                       │    │
│  │    (promotion_id, published_count=0, success_count=0, ...)      │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    ↓                                    │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ 4. ExecutionContext 전달 데이터 저장                                │    │
│  │    - promotionId 저장 → PublishStep으로 전달                       │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### DB 조회/업데이트 쿼리 조건

| 작업         | 테이블                          | 조건/값                                                                             | 비고                                                  |
|------------|------------------------------|----------------------------------------------------------------------------------|-----------------------------------------------------|
| **조회**     | `campaign_promotions`        | `promotion_status = 'READY'` AND `DATE_FORMAT(reservation_at, '%Y%m%d%H%i') = ?` | Job Parameter로 전달받은 reservationAt (yyyyMMddHHmm) 사용 |
| **업데이트**   | `campaign_promotions`        | `promotion_status = 'IN_PROGRESS'`                                               | READY → IN_PROGRESS 상태 변경                           |
| **INSERT** | `campaign_promotion_summary` | `published_count=0, success_count=0, fail_count=0, retry_success_count=0`        | 통계 초기화                                              |

#### ExecutionContext 전달 데이터

| 필드          | 타입   | 설명      | 비고                   |
|-------------|------|---------|----------------------|
| promotionId | Long | 프로모션 ID | 필수, PublishStep에서 사용 |

#### 스케줄링 정보

| 항목       | 값     | 설명                            |
|----------|-------|-------------------------------|
| 호출 주기    | 5분    | 외부 스케줄러(Jenkins)에서 호출         |
| 예약 일시 비교 | 분 단위  | `reservation_at` 컬럼과 현재 시간 비교 |
| 동시 처리    | 다건 가능 | 동일 예약 시간의 여러 프로모션 순차 처리       |

#### 추상화 처리 (향후 구현)

- `campaign_promotion_summary_cache` 데이터 생성 비동기 `ApplicationEventPublisher` 발행 처리

### 3.2 PromotionTypeDecider

- `prepay_admin.campaign_promotions` 테이블의 `promotion_type` 기준 바우처 또는 포인트 대상자 발행 Step 호출

#### 분기 로직 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PromotionTypeDecider 분기 로직                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│                    ┌───────────────────────┐                            │
│                    │   ExecutionContext    │                            │
│                    │   promotionId 조회     │                            │
│                    └───────────────────────┘                            │
│                              ↓                                          │
│                    ┌───────────────────────┐                            │
│                    │  campaign_promotions  │                            │
│                    │  promotion_type 조회   │                            │
│                    └───────────────────────┘                            │
│                              ↓                                          │
│              ┌───────────────┴───────────────┐                          │
│              │       promotion_type = ?      │                          │
│              └───────────────┬───────────────┘                          │
│                              │                                          │
│         ┌────────────────────┼────────────────────┐                     │
│         │                    │                    │                     │
│         ▼                    ▼                    ▼                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐                │
│  │   VOUCHER   │     │    POINT    │     │    기타      │                │
│  │             │     │             │     │   (예외)     │                │
│  └─────────────┘     └─────────────┘     └─────────────┘                │
│         │                    │                    │                     │
│         ▼                    ▼                    ▼                     │
│  VoucherPublishStep   PointPublishStep       Job 종료                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### 분기 조건 테이블

| promotion_type | 조건              | 반환값                              | 다음 Step            | 비고          |
|----------------|-----------------|----------------------------------|--------------------|-------------|
| -              | promotionId = 0 | `FlowExecutionStatus("NONE")`    | Job 종료             | 처리할 프로모션 없음 |
| VOUCHER        | promotionId > 0 | `FlowExecutionStatus("VOUCHER")` | VoucherPublishStep | 상품권 대상자 발행  |
| POINT          | promotionId > 0 | `FlowExecutionStatus("POINT")`   | PointPublishStep   | 포인트 대상자 발행  |

### 3.3 PublishStep

- `InitStep` 에서 받은 전달 데이터 기준 프로모션 대량 처리를 위한 프로모션 대상자 `Kafka 메시지 발행` 처리
- `InitStep` 에서 전달된 `partition_count` 만큼 `Spring Partitioner` 기반 데이터 파티셔닝 후 병렬 처리

#### Worker Step 내부 처리 흐름 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Worker Step 내부 처리 흐름                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Reader (JdbcPagingItemReader)                                   │   │
│  │ ─────────────────────────────                                   │   │
│  │ SELECT * FROM campaign_promotion_<voucher|point>_targets        │   │
│  │ WHERE promotion_id = :promotionId                               │   │
│  │   AND publish_status = 'PENDING'                                │   │
│  │ ORDER BY <voucher|point>_target_id ASC                          │   │
│  │ LIMIT :pageSize                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              ↓ (Chunk 단위)                             │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Processor (ItemProcessor)                                       │   │
│  │ ─────────────────────────                                       │   │
│  │ 1. Kafka 메시지 Payload 생성                                      │   │
│  │ 2. eventProviderService.send() 호출                             │   │
│  │ 3. 성공: item.updatePublishStatus(PUBLISHED)                    │   │
│  │    실패: item.updatePublishStatus(FAILED)                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              ↓                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Writer (JdbcBatchItemWriter)                                    │   │
│  │ ─────────────────────────────                                   │   │
│  │ UPDATE campaign_promotion_<voucher|point>_targets               │   │
│  │ SET publish_status = :publishStatus, updated_at = NOW()         │   │
│  │ WHERE <voucher|point>_target_id = :targetId                     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Reader/Processor/Writer 역할 테이블

| 컴포넌트          | 역할                     | 입력                   | 출력                 |
|---------------|------------------------|----------------------|--------------------|
| **Reader**    | PENDING 상태 대상자 페이징 조회  | promotionId, PENDING | TargetDto 목록       |
| **Processor** | Kafka 메시지 발행 + 상태 변경   | TargetDto            | TargetDto (상태 변경됨) |
| **Writer**    | DB publish_status 업데이트 | TargetDto 목록         | -                  |

#### 추상화 처리 (향후 구현)

- `campaign_promotion_summary_cache` 데이터 `publish_count` 업데이트 비동기 `ApplicationEventPublisher` 발행 처리

#### Kafka 발행 메시지 구조

##### 상품권 프로모션 대상자 메시지 구조

```json
{
    "promotionId": "1",
    "promotionSummaryId": "1",
    "voucherTargetId": "1",
    "partitionKey": "0",
    "customerUid": "12345",
    "merchantCode": "merchant_code",
    "merchantBrandCode": "merchant_brand_code",
    "campaignCode": "CAMPAIGN-001",
    "amount": "10000",
    "voucherNumber": "voucher_number",
    "description": "새해맞이 프로모션 상품권 지급",
    "expiredAt": "2026-12-31",
    "isWithdrawal": false
}
```

##### 상품권 Kafka 메시지 필드 설명

| 필드                 | 타입      | 설명               | 필수 |
|--------------------|---------|------------------|----|
| promotionId        | String  | 프로모션 ID          | Y  |
| promotionSummaryId | String  | 프로모션 현황 ID       | Y  |
| voucherTargetId    | String  | 바우처 대상 ID        | Y  |
| partitionKey       | String  | 파티션 키            | Y  |
| customerUid        | String  | 고객 UID           | Y  |
| merchantCode       | String  | 상점 코드            | Y  |
| merchantBrandCode  | String  | 상점 브랜드 코드        | Y  |
| campaignCode       | String  | 캠페인 코드           | Y  |
| amount             | String  | 지급 금액            | Y  |
| voucherNumber      | String  | 상품권 번호           | Y  |
| description        | String  | 지급 사유            | Y  |
| expiredAt          | String  | 유효일 (yyyy-MM-dd) | Y  |
| isWithdrawal       | Boolean | 인출 가능 여부         | Y  |

##### 포인트 프로모션 대상자 메시지 구조

```json
{
    "promotionId": "1",
    "promotionSummaryId": "1",
    "pointTargetId": "1",
    "partitionKey": "0",
    "customerUid": "12345",
    "merchantCode": "merchant_code",
    "merchantBrandCode": "merchant_brand_code",
    "campaignCode": "CAMPAIGN-001",
    "amount": "50000",
    "description": "새해맞이 프로모션 포인트 지급",
    "expiredAt": "2026-12-31",
    "refSubId": "1"
}
```

##### 포인트 Kafka 메시지 필드 설명

| 필드                 | 타입     | 설명               | 필수 |
|--------------------|--------|------------------|----|
| promotionId        | String | 프로모션 ID          | Y  |
| promotionSummaryId | String | 프로모션 현황 ID       | Y  |
| pointTargetId      | String | 포인트 대상 ID        | Y  |
| partitionKey       | String | 파티션 키            | Y  |
| customerUid        | String | 고객 UID           | Y  |
| merchantCode       | String | 상점 코드            | Y  |
| merchantBrandCode  | String | 상점 브랜드 코드        | N  |
| campaignCode       | String | 캠페인 코드           | Y  |
| amount             | String | 지급 금액            | Y  |
| description        | String | 지급 사유            | Y  |
| expiredAt          | String | 유효일 (yyyy-MM-dd) | Y  |
| refSubId           | String | 참조 ID (point_target_id) | Y  |

### 3.4 FinalizeStep

프로모션 처리 완료 후 상태 업데이트 및 다음 프로모션 처리를 위한 context 초기화를 담당합니다.

#### 처리 흐름

1. 현재 프로모션 상태를 COMPLETED로 업데이트
2. ExecutionContext 초기화 (promotionId=0, partitionCount=0)
3. 다음 프로모션 처리를 위해 InitStep으로 돌아감

#### DB 업데이트 쿼리

| 작업     | 테이블                   | 조건/값                             |
|--------|-----------------------|----------------------------------|
| UPDATE | `campaign_promotions` | `promotion_status = 'COMPLETED'` |

---

### 3.5 상태 전이 다이어그램

#### PromotionStatus 상태 전이

```
                          ┌─────────────────────────────────────────┐
                          │              READY                      │
                          │     (Admin에서 프로모션 생성 시 초기 상태)     │
                          └─────────────────────────────────────────┘
                                           │
                                           │ InitStep 실행
                                           │ (예약일시 도래 & Job 시작)
                                           ▼
                          ┌─────────────────────────────────────────┐
                          │           IN_PROGRESS                   │
                          │    (Publisher 배치 실행 중)                │
                          └─────────────────────────────────────────┘
                                           │
                    ┌──────────────────────┼──────────────────────┐
                    │                      │                      │
                    ▼                      ▼                      ▼
    ┌───────────────────────┐  ┌───────────────────┐  ┌───────────────────┐
    │      COMPLETED        │  │      STOPPED      │  │      FAILED       │
    │ (모든 대상자 발행 완료)    │  │ (관리자 수동 중단)    │  │ (배치 실행 실패)     │
    └───────────────────────┘  └───────────────────┘  └───────────────────┘
```

#### PublishStatus 상태 전이 (대상자별)

```
    ┌─────────────────────────────────────────┐
    │              PENDING                    │
    │      (대상자 데이터 INSERT 시 초기 상태)      │
    └─────────────────────────────────────────┘
                       │
                       │ Kafka 메시지 발행 시도
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
    ┌───────────┐           ┌───────────┐
    │ PUBLISHED │           │  FAILED   │
    │ (발행 성공) │           │ (발행 실패) │
    └───────────┘           └───────────┘
                                  │
                                  │ 재시도 배치 실행 시
                                  │
                                  ▼
                          ┌───────────┐
                          │ PUBLISHED │
                          │ (재발행)    │
                          └───────────┘
```

#### ProcessStatus 상태 전이 (Consumer 처리 결과 - 참고용)

```
    ┌─────────────────────────────────────────┐
    │              (초기 상태 없음)              │
    │     Consumer가 메시지 수신 후 결과 INSERT    │
    └─────────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
    ┌───────────┐           ┌───────────┐
    │  SUCCESS  │           │ RETRYING  │
    │ (처리 성공) │           │ (재시도중)  │
    └───────────┘           └───────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                    ▼                           ▼
            ┌───────────┐               ┌───────────┐
            │  SUCCESS  │               │  FAILED   │
            │(재시도 성공) │               │ (최종 실패) │
            └───────────┘               └───────────┘
```

### 3.6 에러 핸들링 전략

#### Kafka 발행 실패 시 처리

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      Processor (Kafka 발행)                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   try {                                                                 │
│       eventProviderService.send(...)  ──────────────┐                   │
│       item.updatePublishStatus(PUBLISHED)           │                   │
│   } catch (Exception e) {                           │ 실패              │
│       log.error(...)                                ▼                   │
│       item.updatePublishStatus(FAILED)  ◄───────────┘                   │
│   }                                                                     │
│   return item;  // 항상 Writer로 전달 (PUBLISHED 또는 FAILED)             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**설계 결정**: Kafka 발행 실패 시 예외를 throw하지 않고, `FAILED` 상태로 기록 후 계속 진행
- **이유**: 일부 실패로 인해 전체 배치가 중단되는 것을 방지
- **후속 처리**: `FAILED` 상태 대상자는 별도 재시도 배치로 재처리

#### 에러 유형별 처리 방안

| 에러 유형           | 처리 방안             | 상태 변경                       |
|-----------------|-------------------|-----------------------------|
| **Kafka 연결 실패** | FAILED 기록 후 계속 진행 | `publish_status = FAILED`   |
| **메시지 직렬화 실패**  | FAILED 기록 후 계속 진행 | `publish_status = FAILED`   |
| **DB 조회 실패**    | Step 실패 → Job 실패  | `promotion_status = FAILED` |
| **DB 업데이트 실패**  | Chunk 롤백 → 재시도    | 롤백 (상태 유지)                  |

### 3.7 재시작 전략

#### Job 재시작 시나리오

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Job 재시작 시나리오                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [시나리오 1] InitStep 실패 후 재시작                                    │
│  ───────────────────────────────────────                                │
│  - promotion_status가 READY 상태 유지                                   │
│  - 동일 Job Parameters로 재실행 시 처음부터 재시작                        │
│                                                                         │
│  [시나리오 2] PublishStep 중간 실패 후 재시작                             │
│  ───────────────────────────────────────                                │
│  - promotion_status = IN_PROGRESS 상태                                  │
│  - publish_status = PENDING인 대상자만 조회하므로 중복 발행 방지          │
│  - 이미 PUBLISHED된 대상자는 자동 스킵                                   │
│                                                                         │
│  [시나리오 3] 부분 실패 (일부 FAILED) 후 재처리                           │
│  ───────────────────────────────────────                                │
│  - 별도 재시도 배치 Job 실행                                             │
│  - publish_status = FAILED인 대상자만 조회                               │
│  - FAILED → PUBLISHED로 상태 변경                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### 멱등성 보장

| 구분              | 멱등성 보장 방식                                                   |
|-----------------|-------------------------------------------------------------|
| **InitStep**    | `promotion_status = READY` 조건으로 조회 → 이미 IN_PROGRESS면 재실행 안됨 |
| **PublishStep** | `publish_status = PENDING` 조건으로 조회 → 이미 PUBLISHED면 스킵       |
| **Kafka 발행**    | Consumer에서 `voucherTargetId` / `pointTargetId` 기준 중복 체크     |

#### 재시도 배치 Job (별도 구현)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 CampaignPromotionRetryBatch (별도 Job)                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Reader: publish_status = 'FAILED' 조건 대상자 조회                      │
│  2. Processor: Kafka 재발행                                               │
│  3. Writer: publish_status = 'PUBLISHED' 업데이트                         │
│                                                                         │
│  - 실행 주기: 수동 또는 스케줄 (예: 1시간 후)                                    │
│  - 최대 재시도 횟수 제한 고려 (retry_count 컬럼 추가 가능)                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 코드 구현 상세

### 4.1 InitStep - Tasklet 패턴

**참조**: `DailyAccountingStatisticsBatch`

```java
@Bean(name = INIT_STEP)
@JobScope
public Step initStep(
    @Qualifier(PrepayAdminDbConfig.NAME_DATASOURCE) DataSource prepayAdminDataSource,
    @Value("#{jobParameters['reservationAt']}") String reservationAt  // Optional - null이면 현재 시간 사용
) {
    return new StepBuilder(INIT_STEP, jobRepository)
        .tasklet((contribution, chunkContext) -> {
            JdbcTemplate jdbcTemplate = new JdbcTemplate(prepayAdminDataSource);

            // reservationAt이 null이면 현재 시간 사용
            String targetReservationAt = (reservationAt != null)
                ? reservationAt
                : LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMddHHmm"));

            // 1. 예약 일시 도래 & READY 상태 프로모션 목록 조회
            List<CampaignPromotionDto> promotions = jdbcTemplate.query(
                "SELECT * FROM prepay_admin.campaign_promotions " +
                "WHERE promotion_status = ? AND DATE_FORMAT(reservation_at, '%Y%m%d%H%i') = ?",
                new CampaignPromotionRowMapper(),
                PromotionStatus.READY.name(), targetReservationAt
            );

            for (CampaignPromotionDto promotion : promotions) {
                // 2. promotion_status 업데이트 (READY → IN_PROGRESS)
                jdbcTemplate.update(
                    "UPDATE prepay_admin.campaign_promotions SET promotion_status = ?, updated_at = NOW() WHERE promotion_id = ?",
                    PromotionStatus.IN_PROGRESS.name(), promotion.getPromotionId()
                );

                // 3. summary 데이터 INSERT
                jdbcTemplate.update(
                    "INSERT INTO prepay_admin.campaign_promotion_summary " +
                    "(promotion_summary_id, promotion_id, published_count, success_count, fail_count, retry_success_count, started_at, created_at) " +
                    "VALUES (?, ?, 0, 0, 0, 0, NOW(), NOW())",
                    promotion.getPromotionId(), promotion.getPromotionId()
                );

                // 4. (추상화) ApplicationEventPublisher로 cache 생성 이벤트 발행
                // eventPublisher.publishEvent(new CampaignSummaryCacheCreateEvent(promotion));

                // 5. ExecutionContext에 PublishStep 전달 데이터 저장
                chunkContext.getStepContext().getStepExecution().getJobExecution()
                    .getExecutionContext().putLong("promotionId", promotion.getPromotionId());
            }

            return RepeatStatus.FINISHED;
        }, transactionManager)
        .build();
}
```

### 4.2 PromotionTypeDecider - JobExecutionDecider 패턴

**참조**: `StatisticsDecider`

```java
@Override
public FlowExecutionStatus decide(JobExecution jobExecution, StepExecution stepExecution) {
    Long promotionId = jobExecution.getExecutionContext().getLong("promotionId");
    JdbcTemplate jdbcTemplate = new JdbcTemplate(prepayAdminDataSource);

    String promotionType = jdbcTemplate.queryForObject(
        "SELECT promotion_type FROM prepay_admin.campaign_promotions WHERE promotion_id = ?",
        String.class, promotionId
    );

    return new FlowExecutionStatus(promotionType);  // VOUCHER 또는 POINT
}
```

### 4.3 Reader - Plain Class 패턴 (JdbcPagingItemReader 생성)

**특징**: `@Component`, `@StepScope` 없이 Plain class로 구현. Step 클래스에서 생성자 호출로 인스턴스 생성.

#### 4.3.1 VoucherWorkerReader.java

`job/campaign/reader/VoucherWorkerReader.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.reader;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignVoucherTargetDto;
import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignVoucherTargetRowMapper;
import com.musinsapayments.prepay.application.batch.job.campaign.CampaignPromotionPublisherBatch;
import com.musinsapayments.prepay.batch.support.constant.prepay.admin.PublishStatus;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.database.JdbcPagingItemReader;
import org.springframework.batch.item.database.Order;
import org.springframework.batch.item.database.builder.JdbcPagingItemReaderBuilder;
import org.springframework.batch.item.database.support.SqlPagingQueryProviderFactoryBean;

import javax.annotation.Nonnull;
import javax.sql.DataSource;
import java.util.HashMap;
import java.util.Map;

@Slf4j
public class VoucherWorkerReader {

    private final DataSource dataSource;

    public VoucherWorkerReader(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public JdbcPagingItemReader<CampaignVoucherTargetDto> create(Long promotionId, Integer partitionKey) throws Exception {
        Map<String, Object> params = new HashMap<>();
        params.put("promotionId", promotionId);
        params.put("partitionKey", partitionKey);
        params.put("publishStatus", PublishStatus.PENDING.name());

        return new JdbcPagingItemReaderBuilder<CampaignVoucherTargetDto>()
                .name("voucherWorkerReader")
                .dataSource(dataSource)
                .queryProvider(createQueryProvider().getObject())
                .parameterValues(params)
                .rowMapper(new CampaignVoucherTargetRowMapper())
                .pageSize(CampaignPromotionPublisherBatch.CHUNK_SIZE)
                .build();
    }

    private SqlPagingQueryProviderFactoryBean createQueryProvider() {
        SqlPagingQueryProviderFactoryBean provider = new SqlPagingQueryProviderFactoryBean();
        provider.setDataSource(dataSource);
        provider.setSelectClause(select());
        provider.setFromClause(from());
        provider.setWhereClause(getWhereClause());
        provider.setSortKeys(Map.of("voucher_target_id", Order.ASCENDING));
        return provider;
    }

    private String select() {
        return """
                voucher_target_id, promotion_id, customer_uid, voucher_number,
                merchant_code, merchant_brand_code, amount, is_withdrawal,
                expired_at, reason, partition_key, publish_status,
                created_at, updated_at
                """;
    }

    @Nonnull
    private static String from() {
        return "prepay_admin.campaign_promotion_voucher_targets";
    }

    @Nonnull
    private static String getWhereClause() {
        return """
                promotion_id = :promotionId
                AND partition_key = :partitionKey
                AND publish_status = :publishStatus
                """;
    }
}
```

#### 4.3.2 PointWorkerReader.java

`job/campaign/reader/PointWorkerReader.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.reader;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignPointTargetDto;
import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignPointTargetRowMapper;
import com.musinsapayments.prepay.application.batch.job.campaign.CampaignPromotionPublisherBatch;
import com.musinsapayments.prepay.batch.support.constant.prepay.admin.PublishStatus;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.database.JdbcPagingItemReader;
import org.springframework.batch.item.database.Order;
import org.springframework.batch.item.database.builder.JdbcPagingItemReaderBuilder;
import org.springframework.batch.item.database.support.SqlPagingQueryProviderFactoryBean;

import javax.annotation.Nonnull;
import javax.sql.DataSource;
import java.util.HashMap;
import java.util.Map;

@Slf4j
public class PointWorkerReader {

    private final DataSource dataSource;

    public PointWorkerReader(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public JdbcPagingItemReader<CampaignPointTargetDto> create(Long promotionId, Integer partitionKey) throws Exception {
        Map<String, Object> params = new HashMap<>();
        params.put("promotionId", promotionId);
        params.put("partitionKey", partitionKey);
        params.put("publishStatus", PublishStatus.PENDING.name());

        return new JdbcPagingItemReaderBuilder<CampaignPointTargetDto>()
                .name("pointWorkerReader")
                .dataSource(dataSource)
                .queryProvider(createQueryProvider().getObject())
                .parameterValues(params)
                .rowMapper(new CampaignPointTargetRowMapper())
                .pageSize(CampaignPromotionPublisherBatch.CHUNK_SIZE)
                .build();
    }

    private SqlPagingQueryProviderFactoryBean createQueryProvider() {
        SqlPagingQueryProviderFactoryBean provider = new SqlPagingQueryProviderFactoryBean();
        provider.setDataSource(dataSource);
        provider.setSelectClause(select());
        provider.setFromClause(from());
        provider.setWhereClause(getWhereClause());
        provider.setSortKeys(Map.of("point_target_id", Order.ASCENDING));
        return provider;
    }

    private String select() {
        return """
                point_target_id, promotion_id, customer_uid, merchant_code, merchant_brand_code, amount,
                expired_at, reason, partition_key, publish_status,
                created_at, updated_at
                """;
    }

    @Nonnull
    private static String from() {
        return "prepay_admin.campaign_promotion_point_targets";
    }

    @Nonnull
    private static String getWhereClause() {
        return """
                promotion_id = :promotionId
                AND partition_key = :partitionKey
                AND publish_status = :publishStatus
                """;
    }
}
```

#### Reader 클래스 구조

| 구성 요소                                 | 역할                           | 비고                                 |
|---------------------------------------|------------------------------|------------------------------------|
| **Plain class**                       | Spring Bean으로 등록하지 않음        | Step 클래스에서 직접 생성                   |
| **생성자**                               | DataSource 주입                | Step 클래스에서 전달                      |
| **create()**                          | JdbcPagingItemReader 인스턴스 생성 | promotionId, partitionKey 파라미터로 전달 |
| **SqlPagingQueryProviderFactoryBean** | 페이징 쿼리 제공자 생성                | sortKeys로 정렬 기준 설정                 |
| **JdbcPagingItemReaderBuilder**       | JdbcPagingItemReader 빌더      | pageSize = CHUNK_SIZE              |

### 4.4 Processor - Plain Class 패턴 (ItemProcessor 구현)

**특징**: `@Component`, `@StepScope` 없이 Plain class로 구현. Step 클래스에서 생성자 호출로 인스턴스 생성.

#### 4.4.1 VoucherWorkerProcessor.java

`job/campaign/processor/VoucherWorkerProcessor.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.processor;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignVoucherTargetDto;
import com.musinsapayments.prepay.batch.support.constant.prepay.admin.PublishStatus;
import com.musinsapayments.prepay.infrastructure.kafka.dto.campaign.CampaignPromotionVoucherMessagePayload;
import com.musinsapayments.prepay.infrastructure.kafka.service.EventProviderService;
import com.musinsapayments.prepay.infrastructure.kafka.type.PocketEventType;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.ItemProcessor;

import javax.annotation.Nonnull;

@Slf4j
@RequiredArgsConstructor
public class VoucherWorkerProcessor implements ItemProcessor<CampaignVoucherTargetDto, CampaignVoucherTargetDto> {

    private final EventProviderService eventProviderService;

    @Override
    public CampaignVoucherTargetDto process(@Nonnull CampaignVoucherTargetDto item) {
        try {
            CampaignPromotionVoucherMessagePayload payload = CampaignPromotionVoucherMessagePayload.builder()
                .promotionId(item.getPromotionId().toString())
                .promotionSummaryId(item.getPromotionSummaryId().toString())
                .voucherTargetId(item.getVoucherTargetId().toString())
                .partitionKey(item.getPartitionKey().toString())
                .customerUid(item.getCustomerUid().toString())
                .merchantCode(item.getMerchantCode())
                .merchantBrandCode(item.getMerchantBrandCode())
                .campaignCode(item.getCampaignCode())
                .amount(item.getAmount().toPlainString())
                .voucherNumber(item.getVoucherNumber())
                .description(item.getReason())
                .expiredAt(item.getExpiredAt())
                .isWithdrawal(item.getIsWithdrawal())
                .build();

            eventProviderService.send(
                PocketEventType.CAMPAIGN_PROMOTION_VOUCHER_PUBLISH,
                item.getPartitionKey().toString(),
                payload
            );

            item.updatePublishStatus(PublishStatus.PUBLISHED.name());
            log.debug("Kafka publish success - voucherTargetId: {}", item.getVoucherTargetId());

        } catch (Exception e) {
            log.error("Kafka publish failed - voucherTargetId: {}", item.getVoucherTargetId(), e);
            item.updatePublishStatus(PublishStatus.FAILED.name());
        }

        return item;
    }
}
```

#### 4.4.2 PointWorkerProcessor.java

`job/campaign/processor/PointWorkerProcessor.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.processor;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignPointTargetDto;
import com.musinsapayments.prepay.batch.support.constant.prepay.admin.PublishStatus;
import com.musinsapayments.prepay.infrastructure.kafka.dto.campaign.CampaignPromotionPointMessagePayload;
import com.musinsapayments.prepay.infrastructure.kafka.service.EventProviderService;
import com.musinsapayments.prepay.infrastructure.kafka.type.PocketEventType;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.ItemProcessor;

import javax.annotation.Nonnull;

@Slf4j
@RequiredArgsConstructor
public class PointWorkerProcessor implements ItemProcessor<CampaignPointTargetDto, CampaignPointTargetDto> {

    private final EventProviderService eventProviderService;

    @Override
    public CampaignPointTargetDto process(@Nonnull CampaignPointTargetDto item) {
        try {
            CampaignPromotionPointMessagePayload payload = CampaignPromotionPointMessagePayload.builder()
                .promotionId(item.getPromotionId().toString())
                .promotionSummaryId(item.getPromotionSummaryId().toString())
                .pointTargetId(item.getPointTargetId().toString())
                .partitionKey(item.getPartitionKey().toString())
                .customerUid(item.getCustomerUid().toString())
                .merchantCode(item.getMerchantCode())
                .merchantBrandCode(item.getMerchantBrandCode())
                .campaignCode(item.getCampaignCode())
                .amount(item.getAmount().toPlainString())
                .description(item.getReason())
                .expiredAt(item.getExpiryAt())
                .refSubId(item.getPointTargetId().toString())
                .build();

            eventProviderService.send(
                PocketEventType.CAMPAIGN_PROMOTION_POINT_PUBLISH,
                item.getPartitionKey().toString(),
                payload
            );

            item.updatePublishStatus(PublishStatus.PUBLISHED.name());
            log.debug("Kafka publish success - pointTargetId: {}", item.getPointTargetId());

        } catch (Exception e) {
            log.error("Kafka publish failed - pointTargetId: {}", item.getPointTargetId(), e);
            item.updatePublishStatus(PublishStatus.FAILED.name());
        }

        return item;
    }
}
```

#### Processor 클래스 구조

| 구성 요소                        | 역할                    | 비고                         |
|------------------------------|-----------------------|----------------------------|
| **Plain class**              | Spring Bean으로 등록하지 않음 | Step 클래스에서 직접 생성           |
| **@RequiredArgsConstructor** | 생성자 주입 (final 필드)     | EventProviderService 전달    |
| **EventProviderService**     | Kafka 메시지 발행 서비스      | Step 클래스에서 전달              |
| **process()**                | Kafka 발행 + 상태 변경      | PUBLISHED 또는 FAILED 상태로 변경 |

### 4.5 Writer - Plain Class 패턴 (ItemWriter 구현)

**특징**: `@Component`, `@StepScope` 없이 Plain class로 구현. Step 클래스에서 생성자 호출로 인스턴스 생성.

#### 4.5.1 VoucherWorkerWriter.java

`job/campaign/writer/VoucherWorkerWriter.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.writer;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignVoucherTargetDto;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.Chunk;
import org.springframework.batch.item.ItemWriter;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import javax.sql.DataSource;
import java.util.Map;

@Slf4j
public class VoucherWorkerWriter implements ItemWriter<CampaignVoucherTargetDto> {

    private final NamedParameterJdbcTemplate jdbcTemplate;

    public VoucherWorkerWriter(DataSource prepayAdminDataSource) {
        this.jdbcTemplate = new NamedParameterJdbcTemplate(prepayAdminDataSource);
    }

    @Override
    public void write(Chunk<? extends CampaignVoucherTargetDto> chunk) {
        for (CampaignVoucherTargetDto item : chunk) {
            Map<String, Object> params = Map.of(
                "publishStatus", item.getPublishStatus(),
                "voucherTargetId", item.getVoucherTargetId()
            );

            jdbcTemplate.update(getUpdateStatusQuery(), params);

            log.debug("Updated voucher target status - voucherTargetId: {}, publishStatus: {}",
                item.getVoucherTargetId(), item.getPublishStatus());
        }
    }

    private String getUpdateStatusQuery() {
        return """
            UPDATE prepay_admin.campaign_promotion_voucher_targets
            SET publish_status = :publishStatus, updated_at = NOW()
            WHERE voucher_target_id = :voucherTargetId
            """;
    }
}
```

#### 4.5.2 PointWorkerWriter.java

`job/campaign/writer/PointWorkerWriter.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.writer;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignPointTargetDto;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.item.Chunk;
import org.springframework.batch.item.ItemWriter;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import javax.sql.DataSource;
import java.util.Map;

@Slf4j
public class PointWorkerWriter implements ItemWriter<CampaignPointTargetDto> {

    private final NamedParameterJdbcTemplate jdbcTemplate;

    public PointWorkerWriter(DataSource prepayAdminDataSource) {
        this.jdbcTemplate = new NamedParameterJdbcTemplate(prepayAdminDataSource);
    }

    @Override
    public void write(Chunk<? extends CampaignPointTargetDto> chunk) {
        for (CampaignPointTargetDto item : chunk) {
            Map<String, Object> params = Map.of(
                "publishStatus", item.getPublishStatus(),
                "pointTargetId", item.getPointTargetId()
            );

            jdbcTemplate.update(getUpdateStatusQuery(), params);

            log.debug("Updated point target status - pointTargetId: {}, publishStatus: {}",
                item.getPointTargetId(), item.getPublishStatus());
        }
    }

    private String getUpdateStatusQuery() {
        return """
            UPDATE prepay_admin.campaign_promotion_point_targets
            SET publish_status = :publishStatus, updated_at = NOW()
            WHERE point_target_id = :pointTargetId
            """;
    }
}
```

#### Writer 클래스 구조

| 구성 요소                          | 역할                     | 비고                           |
|--------------------------------|------------------------|------------------------------|
| **Plain class**                | Spring Bean으로 등록하지 않음  | Step 클래스에서 직접 생성             |
| **생성자**                        | DataSource 주입          | Step 클래스에서 전달                |
| **NamedParameterJdbcTemplate** | 쿼리 파라미터 바인딩            | `:paramName` 형식 지원           |
| **write()**                    | Chunk 단위로 DB UPDATE 실행 | PUBLISHED 또는 FAILED 상태 업데이트  |

### 4.6 Worker Step - @Configuration 클래스 패턴

**특징**: Step을 별도 `@Configuration` 클래스로 분리하여 Reader/Processor/Writer를 private helper methods로 조합.

#### 4.6.1 VoucherWorkerStep.java

`job/campaign/step/VoucherWorkerStep.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.step;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignVoucherTargetDto;
import com.musinsapayments.prepay.application.batch.job.campaign.CampaignPromotionPublisherBatch;
import com.musinsapayments.prepay.application.batch.job.campaign.processor.VoucherWorkerProcessor;
import com.musinsapayments.prepay.application.batch.job.campaign.reader.VoucherWorkerReader;
import com.musinsapayments.prepay.application.batch.job.campaign.writer.VoucherWorkerWriter;
import com.musinsapayments.prepay.infrastructure.kafka.service.EventProviderService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.configuration.annotation.StepScope;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.database.JdbcPagingItemReader;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;

@Slf4j
@Configuration
public class VoucherWorkerStep {

    public static final String STEP_NAME = CampaignPromotionPublisherBatch.JOB_NAME + "_voucherWorkerStep";

    private final JobRepository jobRepository;
    private final PlatformTransactionManager transactionManager;
    private final DataSource prepayAdminDataSource;
    private final EventProviderService eventProviderService;

    public VoucherWorkerStep(
        JobRepository jobRepository,
        PlatformTransactionManager transactionManager,
        DataSource prepayAdminDataSource,
        EventProviderService eventProviderService
    ) {
        this.jobRepository = jobRepository;
        this.transactionManager = transactionManager;
        this.prepayAdminDataSource = prepayAdminDataSource;
        this.eventProviderService = eventProviderService;
    }

    @StepScope
    @Bean(name = STEP_NAME)
    public Step voucherWorkerStep(
        @Value("#{jobExecutionContext['promotionId']}") Long promotionId,
        @Value("#{stepExecutionContext['partitionKey']}") Integer partitionKey
    ) throws Exception {
        return new StepBuilder(STEP_NAME, jobRepository)
                .<CampaignVoucherTargetDto, CampaignVoucherTargetDto>chunk(CampaignPromotionPublisherBatch.CHUNK_SIZE, transactionManager)
                .reader(reader(promotionId, partitionKey))
                .processor(processor())
                .writer(writer())
                .build();
    }

    private JdbcPagingItemReader<CampaignVoucherTargetDto> reader(Long promotionId, Integer partitionKey) throws Exception {
        return new VoucherWorkerReader(prepayAdminDataSource).create(promotionId, partitionKey);
    }

    private VoucherWorkerProcessor processor() {
        return new VoucherWorkerProcessor(eventProviderService);
    }

    private VoucherWorkerWriter writer() {
        return new VoucherWorkerWriter(prepayAdminDataSource);
    }
}
```

#### 4.6.2 PointWorkerStep.java

`job/campaign/step/PointWorkerStep.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.step;

import com.musinsapayments.prepay.application.batch.dto.campaign.CampaignPointTargetDto;
import com.musinsapayments.prepay.application.batch.job.campaign.CampaignPromotionPublisherBatch;
import com.musinsapayments.prepay.application.batch.job.campaign.processor.PointWorkerProcessor;
import com.musinsapayments.prepay.application.batch.job.campaign.reader.PointWorkerReader;
import com.musinsapayments.prepay.application.batch.job.campaign.writer.PointWorkerWriter;
import com.musinsapayments.prepay.infrastructure.kafka.service.EventProviderService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.configuration.annotation.StepScope;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.database.JdbcPagingItemReader;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;

@Slf4j
@Configuration
public class PointWorkerStep {

    public static final String STEP_NAME = CampaignPromotionPublisherBatch.JOB_NAME + "_pointWorkerStep";

    private final JobRepository jobRepository;
    private final PlatformTransactionManager transactionManager;
    private final DataSource prepayAdminDataSource;
    private final EventProviderService eventProviderService;

    public PointWorkerStep(
        JobRepository jobRepository,
        PlatformTransactionManager transactionManager,
        DataSource prepayAdminDataSource,
        EventProviderService eventProviderService
    ) {
        this.jobRepository = jobRepository;
        this.transactionManager = transactionManager;
        this.prepayAdminDataSource = prepayAdminDataSource;
        this.eventProviderService = eventProviderService;
    }

    @StepScope
    @Bean(name = STEP_NAME)
    public Step pointWorkerStep(
        @Value("#{jobExecutionContext['promotionId']}") Long promotionId,
        @Value("#{stepExecutionContext['partitionKey']}") Integer partitionKey
    ) throws Exception {
        return new StepBuilder(STEP_NAME, jobRepository)
                .<CampaignPointTargetDto, CampaignPointTargetDto>chunk(CampaignPromotionPublisherBatch.CHUNK_SIZE, transactionManager)
                .reader(reader(promotionId, partitionKey))
                .processor(processor())
                .writer(writer())
                .build();
    }

    private JdbcPagingItemReader<CampaignPointTargetDto> reader(Long promotionId, Integer partitionKey) throws Exception {
        return new PointWorkerReader(prepayAdminDataSource).create(promotionId, partitionKey);
    }

    private PointWorkerProcessor processor() {
        return new PointWorkerProcessor(eventProviderService);
    }

    private PointWorkerWriter writer() {
        return new PointWorkerWriter(prepayAdminDataSource);
    }
}
```

#### Step 클래스 구조

| 구성 요소                   | 역할                                 | 비고                                                          |
|-------------------------|------------------------------------|-------------------------------------------------------------|
| **@Configuration**      | Spring Bean 설정 클래스                 | Step Bean 정의                                                |
| **@StepScope @Bean**    | Step 실행 시점 Bean 생성                 | `@Value`로 jobExecutionContext, stepExecutionContext 파라미터 주입 |
| **private reader()**    | Reader 인스턴스 생성 (private helper)    | Plain class 생성자 호출 + `create()` 메서드                         |
| **private processor()** | Processor 인스턴스 생성 (private helper) | Plain class 생성자 호출                                          |
| **private writer()**    | Writer 인스턴스 생성 (private helper)    | Plain class 생성자 호출                                          |

#### Step 클래스 패턴의 장점

| 항목          | 설명                                            |
|-------------|-----------------------------------------------|
| **캡슐화**     | Reader/Processor/Writer 생성 로직을 Step 클래스에 캡슐화  |
| **파라미터 주입** | `@StepScope` Step 메서드에서 `@Value`로 런타임 파라미터 주입 |
| **테스트 용이성** | Step 클래스 단위로 통합 테스트 가능                        |
| **책임 분리**   | Job 클래스는 Flow 정의만, Step 클래스는 Step 구성만 담당      |

### 4.7 Partitioner - @JobScope @Component 패턴

**참조**: Spring Batch Partitioner 패턴

Worker Step을 파티션 단위로 분할하여 병렬 처리하는 공통 Partitioner를 `@JobScope @Component`로 구현합니다.

#### 4.7.1 CampaignPromotionPartitioner.java

`job/campaign/partitioner/CampaignPromotionPartitioner.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign.partitioner;

import lombok.NonNull;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.core.configuration.annotation.JobScope;
import org.springframework.batch.core.partition.support.Partitioner;
import org.springframework.batch.item.ExecutionContext;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;

@Slf4j
@JobScope
@Component
public class CampaignPromotionPartitioner implements Partitioner {

    private final Integer partitionCount;

    public CampaignPromotionPartitioner(
        @Value("#{jobExecutionContext['partitionCount']}") Integer partitionCount
    ) {
        this.partitionCount = (partitionCount != null && partitionCount > 0) ? partitionCount : 1;
    }

    @NonNull
    @Override
    public Map<String, ExecutionContext> partition(int gridSize) {
        Map<String, ExecutionContext> partitions = new HashMap<>();

        log.info("CampaignTargetPartitioner - partitionCount: {}", partitionCount);

        for (int i = 0; i < partitionCount; i++) {
            ExecutionContext context = new ExecutionContext();
            context.putInt("partitionKey", i);
            partitions.put("partition" + i, context);
        }

        return partitions;
    }
}
```

#### Partitioner 클래스 구조

| 구성 요소              | 역할                                    | 비고                               |
|--------------------|---------------------------------------|----------------------------------|
| **@JobScope**      | Job 실행 시점 Bean 생성                     | JobExecutionContext Parameter 주입 |
| **@Component**     | Spring Bean 등록                        | 자동 주입 가능                         |
| **partitionCount** | 파티션 개수 (DB에서 조회한 값)                   | InitStep에서 저장, null 방어 로직 포함     |
| **partition()**    | partitionCount 만큼 ExecutionContext 분할 | partitionKey를 각 Context에 저장      |

#### Manager Step 구성 (Job Bean에서 사용)

공통 Partitioner를 Voucher/Point Manager Step에서 각각 사용합니다:

```java
// Voucher Manager Step (Job Bean 내부)
@Bean(name = VOUCHER_MANAGER_STEP)
@JobScope
public Step voucherManagerStep(
    CampaignPromotionPartitioner partitioner,  // 공통 Partitioner 주입
    @Qualifier(VOUCHER_WORKER_STEP) Step voucherWorkerStep,
    @Value("#{jobExecutionContext['partitionCount']}") Integer partitionCount
) {
    return new StepBuilder(VOUCHER_MANAGER_STEP, jobRepository)
        .partitioner(VOUCHER_WORKER_STEP, partitioner)
        .step(voucherWorkerStep)
        .gridSize(partitionCount != null ? partitionCount : 1)
        .taskExecutor(taskExecutor)
        .build();
}

// Point Manager Step (Job Bean 내부)
@Bean(name = POINT_MANAGER_STEP)
@JobScope
public Step pointManagerStep(
    CampaignPromotionPartitioner partitioner,  // 공통 Partitioner 주입
    @Qualifier(POINT_WORKER_STEP) Step pointWorkerStep,
    @Value("#{jobExecutionContext['partitionCount']}") Integer partitionCount
) {
    return new StepBuilder(POINT_MANAGER_STEP, jobRepository)
        .partitioner(POINT_WORKER_STEP, partitioner)
        .step(pointWorkerStep)
        .gridSize(partitionCount != null ? partitionCount : 1)
        .taskExecutor(taskExecutor)
        .build();
}
```

#### Manager Step 구성 요소

| 구성 요소                            | 역할                       | 스코프         |
|----------------------------------|--------------------------|-------------|
| **CampaignPromotionPartitioner** | 공통 Partitioner 클래스       | `@JobScope` |
| **Manager Step**                 | Worker Step을 파티션별로 병렬 실행 | `@JobScope` |
| **gridSize**                     | 파티션 개수 (partitionCount)  | -           |
| **taskExecutor**                 | 병렬 실행을 위한 TaskExecutor   | -           |

### 4.8 Job Bean - Step Bean 주입 + 루프 Flow 구성

**특징**: Worker Step은 별도 `@Configuration` 클래스로 분리하고, Job Bean에서는 Step Bean만 주입받아 Flow를 구성합니다. Finalize Step 후 다시 Init Step으로 돌아가는 루프 구조를 사용합니다.

#### 4.8.1 CampaignPromotionPublisherBatch.java

`job/campaign/CampaignPromotionPublisherBatch.java`:

```java
package com.musinsapayments.prepay.application.batch.job.campaign;

import com.musinsapayments.prepay.application.batch.decider.PromotionTypeDecider;
import com.musinsapayments.prepay.application.batch.job.campaign.partitioner.CampaignPromotionPartitioner;
import com.musinsapayments.prepay.application.batch.job.campaign.step.PointWorkerStep;
import com.musinsapayments.prepay.application.batch.job.campaign.step.VoucherWorkerStep;
import com.musinsapayments.prepay.application.batch.job.campaign.tasklet.CampaignPromotionFinalizeTasklet;
import com.musinsapayments.prepay.application.batch.job.campaign.tasklet.CampaignPromotionInitTasklet;
import com.musinsapayments.prepay.application.batch.listener.BatchJobListener;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.launch.support.RunIdIncrementer;
import org.springframework.batch.core.partition.support.TaskExecutorPartitionHandler;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.task.SimpleAsyncTaskExecutor;
import org.springframework.core.task.TaskExecutor;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;

@Slf4j
@RequiredArgsConstructor
@Configuration
public class CampaignPromotionPublisherBatch {

    public static final String JOB_NAME = "CampaignPromotionPublisherJob";
    public static final int CHUNK_SIZE = 1000;
    public static final int POOL_SIZE = 10;

    private static final String INIT_STEP = JOB_NAME + "_initStep";
    private static final String VOUCHER_MANAGER_STEP = JOB_NAME + "_voucherManagerStep";
    private static final String POINT_MANAGER_STEP = JOB_NAME + "_pointManagerStep";
    private static final String FINALIZE_STEP = JOB_NAME + "_finalizeStep";

    private final JobRepository jobRepository;
    private final PlatformTransactionManager transactionManager;
    private final BatchJobListener batchJobListener;
    private final DataSource prepayAdminDataSource;

    // ========== Job (루프 구조) ==========
    @Bean(name = JOB_NAME)
    public Job campaignPromotionPublisherJob(
        @Qualifier(INIT_STEP) Step initStep,
        @Qualifier(VOUCHER_MANAGER_STEP) Step voucherManagerStep,
        @Qualifier(POINT_MANAGER_STEP) Step pointManagerStep,
        @Qualifier(FINALIZE_STEP) Step finalizeStep,
        PromotionTypeDecider promotionTypeDecider
    ) {
        return new JobBuilder(JOB_NAME, jobRepository)
            .incrementer(new RunIdIncrementer())
            .listener(batchJobListener)
            .start(initStep)
            .next(promotionTypeDecider)
                .on("VOUCHER").to(voucherManagerStep)
                    .next(finalizeStep)
                    .next(initStep)  // 루프: 다음 프로모션 처리
            .from(promotionTypeDecider)
                .on("POINT").to(pointManagerStep)
                    .next(finalizeStep)
                    .next(initStep)  // 루프: 다음 프로모션 처리
            .from(promotionTypeDecider)
                .on("NONE").end()    // 처리할 프로모션 없으면 종료
            .from(promotionTypeDecider)
                .on("*").end()       // 예외 상황 시 종료
            .end()
            .build();
    }

    // ========== InitStep (Tasklet - Plain class) ==========
    @Bean(name = INIT_STEP)
    public Step initStep() {
        CampaignPromotionInitTasklet tasklet = new CampaignPromotionInitTasklet(prepayAdminDataSource);
        return new StepBuilder(INIT_STEP, jobRepository)
                .tasklet(tasklet, transactionManager)
                .build();
    }

    // ========== PromotionTypeDecider (Plain class Bean) ==========
    @Bean
    public PromotionTypeDecider promotionTypeDecider() {
        return new PromotionTypeDecider(prepayAdminDataSource);
    }

    // ========== FinalizeStep (Tasklet - Plain class) ==========
    @Bean(name = FINALIZE_STEP)
    public Step finalizeStep() {
        CampaignPromotionFinalizeTasklet tasklet = new CampaignPromotionFinalizeTasklet(prepayAdminDataSource);
        return new StepBuilder(FINALIZE_STEP, jobRepository)
            .tasklet(tasklet, transactionManager)
            .build();
    }

    // ========== Voucher Manager Step (Partitioned) ==========
    @Bean(name = VOUCHER_MANAGER_STEP)
    public Step voucherManagerStep(
        CampaignPromotionPartitioner partitioner,
        @Qualifier(VoucherWorkerStep.STEP_NAME) Step voucherWorkerStep
    ) {
        TaskExecutorPartitionHandler partitionHandler = new TaskExecutorPartitionHandler();
        partitionHandler.setStep(voucherWorkerStep);
        partitionHandler.setTaskExecutor(taskExecutor());
        partitionHandler.setGridSize(POOL_SIZE);

        return new StepBuilder(VOUCHER_MANAGER_STEP, jobRepository)
            .partitioner(VoucherWorkerStep.STEP_NAME, partitioner)
            .partitionHandler(partitionHandler)
            .build();
    }

    // ========== Point Manager Step (Partitioned) ==========
    @Bean(name = POINT_MANAGER_STEP)
    public Step pointManagerStep(
        CampaignPromotionPartitioner partitioner,
        @Qualifier(PointWorkerStep.STEP_NAME) Step pointWorkerStep
    ) {
        TaskExecutorPartitionHandler partitionHandler = new TaskExecutorPartitionHandler();
        partitionHandler.setStep(pointWorkerStep);
        partitionHandler.setTaskExecutor(taskExecutor());
        partitionHandler.setGridSize(POOL_SIZE);

        return new StepBuilder(POINT_MANAGER_STEP, jobRepository)
            .partitioner(PointWorkerStep.STEP_NAME, partitioner)
            .partitionHandler(partitionHandler)
            .build();
    }

    // ========== TaskExecutor ==========
    @Bean(name = JOB_NAME + "_taskExecutor")
    public TaskExecutor taskExecutor() {
        SimpleAsyncTaskExecutor taskExecutor = new SimpleAsyncTaskExecutor();
        taskExecutor.setConcurrencyLimit(POOL_SIZE);
        return taskExecutor;
    }
}
```

#### Job Flow 다이어그램 (루프 구조)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CampaignPromotionPublisherJob Flow (루프)                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                           ┌──────────────┐                          │   │
│   │                      ┌───►│  InitStep    │◄───────────────────┐     │   │
│   │                      │    │  (Tasklet)   │                    │     │   │
│   │                      │    └──────┬───────┘                    │     │   │
│   │                      │           │                            │     │   │
│   │                      │           ▼                            │     │   │
│   │                      │    ┌──────────────────────┐            │     │   │
│   │                      │    │ PromotionTypeDecider │            │     │   │
│   │                      │    └──────────┬───────────┘            │     │   │
│   │                      │               │                        │     │   │
│   │                      │      ┌────────┼────────┬───────┐       │     │   │
│   │                      │      │        │        │       │       │     │   │
│   │                      │      ▼        ▼        ▼       ▼       │     │   │
│   │                      │  "VOUCHER" "POINT"  "NONE"   "*"       │     │   │
│   │                      │      │        │        │       │       │     │   │
│   │                      │      ▼        ▼        ▼       ▼       │     │   │
│   │                      │  ┌──────┐ ┌──────┐  ┌─────┐ ┌─────┐    │     │   │
│   │                      │  │Voucher│ │Point │  │ END │ │ END │    │     │   │
│   │                      │  │Manager│ │Manager│  └─────┘ └─────┘    │     │   │
│   │                      │  │ Step │ │ Step │                      │     │   │
│   │                      │  └──┬───┘ └──┬───┘                      │     │   │
│   │                      │     │        │                          │     │   │
│   │                      │     ▼        ▼                          │     │   │
│   │                      │  ┌────────────────┐                     │     │   │
│   │                      │  │ FinalizeStep   │                     │     │   │
│   │                      │  │ (상태 COMPLETED) │                    │     │   │
│   │                      │  └───────┬────────┘                     │     │   │
│   │                      │          │                              │     │   │
│   │                      └──────────┘ (루프: 다음 프로모션 처리)         │     │   │
│   │                                                                 │     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Job Bean 구성 요소

| 구성 요소                                | 역할                            | 패턴                    |
|--------------------------------------|-------------------------------|-----------------------|
| **CampaignPromotionInitTasklet**     | 예약일시 도래 프로모션 조회 & 상태 변경       | Plain class Tasklet   |
| **PromotionTypeDecider**             | VOUCHER/POINT/NONE 분기 결정      | Plain class Bean      |
| **VoucherWorkerStep**                | Voucher Worker Step 정의        | 별도 @Configuration 클래스 |
| **PointWorkerStep**                  | Point Worker Step 정의          | 별도 @Configuration 클래스 |
| **CampaignPromotionFinalizeTasklet** | 상태 COMPLETED 변경 & context 초기화 | Plain class Tasklet   |
| **CampaignPromotionPartitioner**     | 파티션 분할                        | @JobScope @Component  |
| **TaskExecutorPartitionHandler**     | 파티션 병렬 실행 핸들러                 | POOL_SIZE 만큼 병렬 실행    |

#### 설계 포인트

| 항목                               | 설명                                                       |
|----------------------------------|----------------------------------------------------------|
| **Step 클래스 분리**                  | Worker Step은 별도 `@Configuration` 클래스로 분리하여 책임 분산         |
| **Plain class Tasklet**          | Init/Finalize Tasklet은 `@Component` 없이 Plain class로 구현   |
| **루프 구조**                        | Finalize Step 후 Init Step으로 돌아가 다음 프로모션 처리               |
| **TaskExecutorPartitionHandler** | Manager Step에서 `TaskExecutorPartitionHandler` 사용하여 병렬 처리 |
| **POOL_SIZE 상수**                 | 병렬 실행 스레드 수를 상수로 관리 (기본값: 10)                            |

---

## 5. Kafka 설정

### 5.1 Topic 설정

```yaml
# application-infrastructure-kafka.yml
kafka:
  topic:
    # Campaign Promotion Events
    campaignPromotionVoucherPublish: campaign-promotion-voucher-publish
    campaignPromotionPointPublish: campaign-promotion-point-publish
```

### 5.2 EventProperty 프로퍼티

```java
// EventProperty.java에 추가
// Campaign Promotion Events
private String campaignPromotionVoucherPublish;
private String campaignPromotionPointPublish;
```

### 5.3 PocketEventType enum

```java
// PocketEventType.java에 추가
// Campaign Promotion Events
CAMPAIGN_PROMOTION_VOUCHER_PUBLISH("CAMPAIGN_PROMOTION_VOUCHER_PUBLISH", "캠페인 프로모션 상품권 발행 이벤트"),
CAMPAIGN_PROMOTION_POINT_PUBLISH("CAMPAIGN_PROMOTION_POINT_PUBLISH", "캠페인 프로모션 포인트 발행 이벤트"),
```

### 5.4 EventProviderService switch case

```java
// EventProviderService.getEventTopic()에 추가
case CAMPAIGN_PROMOTION_VOUCHER_PUBLISH -> eventProperty.getCampaignPromotionVoucherPublish();
case CAMPAIGN_PROMOTION_POINT_PUBLISH -> eventProperty.getCampaignPromotionPointPublish();
```

### 5.5 메시지 포맷

#### 바우처 메시지

```json
{
  "sentAt": "2026-01-21T10:30:00",
  "version": 20231010,
  "topic": "campaign-promotion-voucher-publish",
  "payload": {
    "eventId": "1",
    "voucherEventTargetId": "1",
    "customerUid": "12345",
    "voucherNumber": "voucher_number",
    "merchantCode": "MUSINSA",
    "merchantBrandCode": "STANDARD",
    "amount": "10000",
    "isWithdrawal": false,
    "validUntil": "20261231235959",
    "reason": "새해맞이 이벤트 상품권 지급",
    "partitionKey": "0"
  }
}
```

#### 포인트 메시지

```json
{
  "sentAt": "2026-01-21T10:30:00",
  "version": 20231010,
  "topic": "campaign-promotion-point-publish",
  "payload": {
    "eventId": "1",
    "pointEventTargetId": "1",
    "customerUid": "12345",
    "amount": "50000",
    "expiryAt": "20260131235959",
    "reason": "새해맞이 이벤트 포인트 지급",
    "partitionKey": "0"
  }
}
```

---

## 6. 구현 순서

> 상세 구현 체크리스트는 별도 문서로 분리되었습니다.
>
> **[IMPLEMENTATION_CHECKLIST.md](IMPLEMENTATION_CHECKLIST.md)** 참조

### 구현 Phase 요약

| Phase | 내용                  | 주요 파일                                                                                              |
|:-----:|---------------------|----------------------------------------------------------------------------------------------------|
|   1   | Enum 클래스            | `PromotionType`, `PromotionStatus`, `PublishStatus`, `ProcessStatus`                               |
|   2   | Kafka 인프라 확장        | `PocketEventType`, `EventProperty`, `CampaignVoucherMessagePayload`, `CampaignPointMessagePayload` |
|   3   | DTO + RowMapper     | `CampaignPromotionDto`, `CampaignVoucherTargetDto`, `CampaignPointTargetDto` + RowMapper           |
|   4   | Publisher Batch Job | Decider, Partitioner, Reader, Processor, Writer, `CampaignPromotionPublisherBatch`                 |
|   5   | 의존성 설정              | `build.gradle.kts`                                                                                 |
|   6   | 테스트 코드              | 통합 테스트, 단위 테스트                                                                                     |

### Git 브랜치 정보

- **Jira 티켓**: PREPAY-952
- **최종 MR 브랜치**: `feature/PREPAY-952` → `staging`
- **Phase별 브랜치**: `feature/PREPAY-952-phase{N}-{name}` → `feature/PREPAY-952`

---

## 7. 핵심 파일 참조

### 7.1 기존 참조 파일 (패턴 참고용)

| 파일                                    | 용도                                                            |
|---------------------------------------|---------------------------------------------------------------|
| `MoneyOutboxRetryBatch.java`          | JdbcPagingItemReader + JdbcBatchItemWriter + ItemProcessor 패턴 |
| `DailyAccountingStatisticsBatch.java` | Tasklet에서 JdbcTemplate 직접 사용 패턴                               |
| `StatisticsDecider.java`              | JobExecutionDecider 구현 패턴                                     |
| `MoneyOutboxDto.java`                 | 상태 변경 가능 DTO 패턴 (updateStatus 메서드)                            |
| `PrepayAdminDbConfig.java`            | prepay-admin DataSource 설정 (NAME_DATASOURCE 상수)               |
| `EventProviderService.java`           | Kafka 발행 서비스                                                  |
| `PocketEventType.java`                | Event Type 확장                                                 |
| `20260206_01_DDL_prepay_admin.sql`    | DDL 스키마                                                       |

### 7.2 구현된 파일 목록

| 파일                                      | 경로                          | 역할                           |
|-----------------------------------------|-----------------------------|------------------------------|
| `CampaignPromotionPublisherBatch.java`  | `job/campaign/`             | 메인 Job Flow 정의               |
| `VoucherWorkerStep.java`                | `job/campaign/step/`        | Voucher Worker Step 정의       |
| `PointWorkerStep.java`                  | `job/campaign/step/`        | Point Worker Step 정의         |
| `VoucherWorkerReader.java`              | `job/campaign/reader/`      | Voucher JdbcPagingItemReader |
| `PointWorkerReader.java`                | `job/campaign/reader/`      | Point JdbcPagingItemReader   |
| `VoucherWorkerProcessor.java`           | `job/campaign/processor/`   | Voucher Kafka 발행 Processor   |
| `PointWorkerProcessor.java`             | `job/campaign/processor/`   | Point Kafka 발행 Processor     |
| `VoucherWorkerWriter.java`              | `job/campaign/writer/`      | Voucher 상태 업데이트 Writer       |
| `PointWorkerWriter.java`                | `job/campaign/writer/`      | Point 상태 업데이트 Writer         |
| `CampaignPromotionPartitioner.java`     | `job/campaign/partitioner/` | 공통 Partitioner               |
| `CampaignPromotionInitTasklet.java`     | `job/campaign/tasklet/`     | Init Step Tasklet            |
| `CampaignPromotionFinalizeTasklet.java` | `job/campaign/tasklet/`     | Finalize Step Tasklet        |
| `PromotionTypeDecider.java`             | `decider/`                  | VOUCHER/POINT 분기 Decider     |

---

## 8. 설계 결정 요약

| 구분                    | 결정                             | 근거                                          |
|-----------------------|--------------------------------|---------------------------------------------|
| Entity 사용             | **불필요**                        | DTO + RowMapper로 충분                         |
| Repository 사용         | **불필요**                        | JdbcTemplate 직접 사용                          |
| 별도 DAO 클래스            | **불필요**                        | Plain class Reader/Writer로 구현               |
| InitStep/FinalizeStep | **Plain class Tasklet**        | 단일 조회/UPDATE 작업, Bean으로 직접 등록               |
| Decider               | **Plain class + Bean 등록**      | JdbcTemplate.queryForObject()               |
| Partitioner           | **@JobScope @Component**       | JobExecutionContext에서 partitionCount 주입     |
| Reader                | **Plain class + create() 메서드** | JdbcPagingItemReader 생성, Step 클래스에서 호출      |
| Processor             | **Plain class**                | Kafka 발행 + 상태 변경, Step 클래스에서 생성자 호출         |
| Writer                | **Plain class**                | DB UPDATE, Step 클래스에서 생성자 호출                |
| Worker Step           | **별도 @Configuration 클래스**      | Reader/Processor/Writer를 private helper로 조합 |
| Job Flow              | **루프 구조**                      | Finalize → Init 반복으로 다음 프로모션 처리             |
| 트랜잭션                  | **Chunk 단위 자동 관리**             | Spring Batch 기본 동작                          |

---

## 9. Job Parameters

| 파라미터          | 타입     | 필수 | 설명                             | 예시                            |
|---------------|--------|----|--------------------------------|-------------------------------|
| reservationAt | String | N  | 예약 일시 (분 단위까지), 미입력 시 현재 시간 사용 | `202601221030` (yyyyMMddHHmm) |

**스케줄링 예시**:
- Jenkins에서 5분 단위로 cron 설정: `*/5 * * * *`
- 호출 시 `reservationAt` 파라미터 미전달 → 배치가 현재 시간 기준으로 자동 조회

---

## 10. 검증 방법

1. **단위 테스트**: 각 컴포넌트별 테스트 (Reader, Processor, Writer)
2. **통합 테스트**: Batch Job 전체 흐름 테스트 (H2 + Embedded Kafka)
3. **E2E 테스트**:
   - Jenkins에서 배치 실행
   - Kafka 메시지 발행 확인 (토픽 모니터링)
   - DB 상태 변경 확인 (publish_status: PENDING → PUBLISHED)
