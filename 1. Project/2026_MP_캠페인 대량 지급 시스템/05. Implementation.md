# 캠페인 프로모션 대량 처리 시스템 구현 문서  
  
## 1. 개요  
  
### 1.1 목적  
캠페인 프로모션(포인트/상품권) 대량 지급 배치 시스템의 **Publisher** 역할을 구현합니다.  
  
### 1.2 구현 범위  
  
| 구분 | 범위 | 비고 |  
|-----|------|------|  
| **이 프로젝트** | Entity/Repository, Publisher Batch Job, Kafka 인프라 확장 | prepay-batch |  
| **제외 (타 프로젝트)** | Kafka Consumer, Retry Consumer, Money API Client | prepay-consumer 등 |  
  
### 1.3 제외 항목  
- **Redis 관련 기능**: event_summary_cache, 5초 Polling 스케줄링  
- **Kafka Consumer**: Consumer, Retry Consumer  
- **Money API Client**: Consumer에서 사용  
  
---  
  
## 2. 시스템 아키텍처  
  
### 2.1 전체 흐름  
```  
[Admin] → [DB: campaign_promotions] → [Batch Job: Publisher] → [Kafka] → [Consumer] → [Money API]  
                                              ↓  
                                    [DB: publish_status 업데이트]  
```  
  
### 2.2 배치 Job 흐름  
```  
┌─────────────────────────────────────────────────────────────────────────────┐  
│                     CampaignPromotionPublisherJob                           │  
├─────────────────────────────────────────────────────────────────────────────┤  
│  1. InitStep (Summary 초기화, promotion_status → IN_PROGRESS)               │  
│                              ↓                                               │  
│  2. PromotionTypeDecider (VOUCHER / POINT 분기)                             │  
│                    ↙                    ↘                                   │  
│  3a. VoucherPublishStep            3b. PointPublishStep                     │  
│      - Reader: PENDING 조회             - Reader: PENDING 조회              │  
│      - Processor: Kafka 발행            - Processor: Kafka 발행             │  
│      - Writer: PUBLISHED 업데이트       - Writer: PUBLISHED 업데이트        │  
└─────────────────────────────────────────────────────────────────────────────┘  
```  
  
---  
  
## 3. 모듈 구조  
  
### 3.1 persistence/rds/prepay-admin (Entity/Repository)  
```  
persistence/rds/prepay-admin/src/main/java/.../prepay/admin/  
├── entity/  
│   ├── CampaignPromotionEntity.java              # 캠페인 프로모션 정보  
│   ├── CampaignPromotionSummaryEntity.java       # 프로모션 처리 현황  
│   ├── CampaignPromotionVoucherTargetEntity.java # 바우처 대상 정보  
│   ├── CampaignPromotionVoucherResultEntity.java # 바우처 처리 결과  
│   ├── CampaignPromotionPointTargetEntity.java   # 포인트 대상 정보  
│   └── CampaignPromotionPointResultEntity.java   # 포인트 처리 결과  
└── repository/  
    ├── CampaignPromotionRepository.java  
    ├── CampaignPromotionSummaryRepository.java  
    ├── CampaignPromotionVoucherTargetRepository.java  
    ├── CampaignPromotionVoucherResultRepository.java  
    ├── CampaignPromotionPointTargetRepository.java  
    └── CampaignPromotionPointResultRepository.java  
```  
  
### 3.2 support (Enum 클래스)  
```  
support/src/main/java/.../batch/support/constant/prepay/admin/  
├── PromotionType.java      # VOUCHER, POINT  
├── PromotionStatus.java    # READY, IN_PROGRESS, COMPLETED, STOPPED, FAILED  
├── PublishStatus.java      # PENDING, PUBLISHED, FAILED  
└── ProcessStatus.java      # SUCCESS, RETRYING, FAILED  
```  
  
### 3.3 application/batch (Publisher Batch Job)  
```  
application/batch/src/main/java/.../batch/job/campaign/  
├── CampaignPromotionPublisherBatch.java       # 메인 Job 설정  
├── step/  
│   ├── CampaignPromotionInitStep.java         # Summary 초기화 Step  
│   ├── CampaignVoucherPublishStep.java        # 바우처 발행 Step  
│   └── CampaignPointPublishStep.java          # 포인트 발행 Step  
├── reader/  
│   ├── CampaignVoucherTargetReader.java       # 바우처 대상 조회  
│   └── CampaignPointTargetReader.java         # 포인트 대상 조회  
├── processor/  
│   ├── CampaignVoucherKafkaPublishProcessor.java  # 바우처 Kafka 발행  
│   └── CampaignPointKafkaPublishProcessor.java    # 포인트 Kafka 발행  
├── writer/  
│   └── CampaignTargetStatusUpdateWriter.java  # publish_status 업데이트  
├── decider/  
│   └── PromotionTypeDecider.java              # VOUCHER/POINT 분기  
└── dto/  
    ├── CampaignPromotionParameterDto.java     # Job Parameter  
    ├── CampaignVoucherTargetDto.java          # 바우처 대상 DTO  
    └── CampaignPointTargetDto.java            # 포인트 대상 DTO  
```  
  
### 3.4 infrastructure/kafka (Kafka 확장)  
```  
infrastructure/kafka/src/main/java/.../kafka/  
├── type/PocketEventType.java                  # CAMPAIGN_VOUCHER_PUBLISH, CAMPAIGN_POINT_PUBLISH 추가  
├── config/properties/EventProperty.java       # campaign topic 설정 추가  
└── dto/campaign/  
    ├── CampaignVoucherMessagePayload.java     # 바우처 메시지 페이로드  
    └── CampaignPointMessagePayload.java       # 포인트 메시지 페이로드  
```  
  
---  
  
## 4. 데이터베이스 스키마  
  
### 4.1 campaign_promotions (캠페인 프로모션 정보)  
| 컬럼명 | 타입 | 설명 |  
|-------|------|------|  
| promotion_id | BIGINT | PK |  
| campaign_issued_seq | BIGINT | 캠페인 발행 SEQ |  
| external_id | VARCHAR(40) | 프로모션 UUID |  
| promotion_type | VARCHAR(20) | VOUCHER / POINT |  
| promotion_status | VARCHAR(30) | READY / IN_PROGRESS / COMPLETED / STOPPED / FAILED |  
| total_count | INT | 전체 대상 건수 |  
| total_amount | DECIMAL(10,2) | 전체 금액 |  
| partition_count | INT | 파티션 수 |  
| reservation_at | DATETIME | 예약 일시 |  
| default_reason | VARCHAR(100) | 공통 지급 사유 |  
| default_amount | DECIMAL(10,2) | 공통 지급 금액 |  
| default_expiry_at | DATETIME | 공통 만료 일시 |  
  
### 4.2 campaign_promotion_summary (처리 현황)  
| 컬럼명 | 타입 | 설명 |  
|-------|------|------|  
| promotion_summary_id | BIGINT | PK |  
| promotion_id | BIGINT | FK |  
| published_count | INT | 발행 건수 |  
| success_count | INT | 성공 건수 |  
| fail_count | INT | 실패 건수 |  
| retry_success_count | INT | 재시도 성공 건수 |  
| started_at | DATETIME | 시작 일시 |  
| completed_at | DATETIME | 완료 일시 |  
  
### 4.3 campaign_promotion_voucher_targets (바우처 대상)  
| 컬럼명 | 타입 | 설명 |  
|-------|------|------|  
| voucher_target_id | BIGINT | PK |  
| promotion_id | BIGINT | FK |  
| customer_uid | BIGINT | 고객 ID |  
| voucher_number | VARCHAR(40) | 상품권 번호 |  
| merchant_code | VARCHAR(30) | 상점 코드 |  
| merchant_brand_code | VARCHAR(20) | 브랜드 코드 |  
| amount | DECIMAL(10,2) | 지급 금액 |  
| is_withdrawal | TINYINT(1) | 인출 가능 여부 |  
| valid_until | VARCHAR(100) | 머니 유효일 |  
| reason | VARCHAR(100) | 지급 사유 |  
| partition_key | INT | 파티션 KEY |  
| publish_status | VARCHAR(20) | PENDING / PUBLISHED / FAILED |  
  
### 4.4 campaign_promotion_point_targets (포인트 대상)  
| 컬럼명 | 타입 | 설명 |  
|-------|------|------|  
| point_target_id | BIGINT | PK |  
| promotion_id | BIGINT | FK |  
| customer_uid | BIGINT | 고객 ID |  
| amount | DECIMAL(10,2) | 지급 금액 |  
| expiry_at | DATETIME | 만료 일시 |  
| reason | VARCHAR(100) | 지급 사유 |  
| partition_key | INT | 파티션 KEY |  
| publish_status | VARCHAR(20) | PENDING / PUBLISHED / FAILED |  
  
### 4.5 campaign_promotion_voucher_results / point_results (처리 결과)  
| 컬럼명 | 타입 | 설명 |  
|-------|------|------|  
| voucher_target_id / point_target_id | BIGINT | PK (복합키) |  
| promotion_id | BIGINT | PK (복합키) |  
| process_status | VARCHAR(30) | SUCCESS / RETRYING / FAILED |  
| transaction_key | VARCHAR(100) | 거래 트랜잭션 KEY |  
| error_message | VARCHAR(500) | 실패 사유 |  
  
---  
  
## 5. 상세 구현 명세  
  
### 5.1 Enum 클래스  
  
#### PromotionType  
```java  
public enum PromotionType {  
    VOUCHER("바우처 프로모션"),  
    POINT("포인트 프로모션");  
}  
```  
  
#### PromotionStatus  
```java  
public enum PromotionStatus {  
    READY("대기"),  
    IN_PROGRESS("진행"),  
    COMPLETED("완료"),  
    STOPPED("중단"),  
    FAILED("실패");  
}  
```  
  
#### PublishStatus  
```java  
public enum PublishStatus {  
    PENDING("대기"),  
    PUBLISHED("발행 완료"),  
    FAILED("실패");  
}  
```  
  
#### ProcessStatus  
```java  
public enum ProcessStatus {  
    SUCCESS("성공"),  
    RETRYING("재시도"),  
    FAILED("실패");  
}  
```  
  
### 5.2 Publisher Batch Job  
  
#### Job 설정 (MoneyOutboxRetryBatch 패턴 참조)  
```java  
@Configuration  
@RequiredArgsConstructor  
public class CampaignPromotionPublisherBatch {  
    private static final int CHUNK_SIZE = 1_000;  
    public static final String JOB_NAME = "campaignPromotionPublisherJob";  
  
    @Bean(name = JOB_NAME)  
    public Job job() {  
        return new JobBuilder(JOB_NAME, jobRepository)  
            .incrementer(new RunIdIncrementer())  
            .listener(batchJobListener)  
            .start(initStep)                    // Summary 초기화  
            .next(promotionTypeDecider)         // VOUCHER/POINT 분기  
                .on("VOUCHER").to(voucherPublishStep)  
            .from(promotionTypeDecider)  
                .on("POINT").to(pointPublishStep)  
            .end()  
            .build();  
    }  
}  
```  
  
#### Job Parameters  
| 파라미터 | 타입 | 필수 | 설명 |  
|---------|------|------|------|  
| promotionId | Long | Y | 프로모션 ID |  
| runDate | String | N | 실행 일자 (기본: 당일) |  
  
### 5.3 Reader (JdbcPagingItemReader)  
  
#### 바우처 대상 조회 쿼리  
```sql  
SELECT voucher_target_id, promotion_id, customer_uid, voucher_number,  
       merchant_code, merchant_brand_code, amount, is_withdrawal,  
       valid_until, reason, partition_key, publish_status  
FROM prepay_admin.campaign_promotion_voucher_targets  
WHERE promotion_id = :promotionId  
  AND publish_status = 'PENDING'  
ORDER BY voucher_target_id ASC  
```  
  
#### 포인트 대상 조회 쿼리  
```sql  
SELECT point_target_id, promotion_id, customer_uid, amount,  
       expiry_at, reason, partition_key, publish_status  
FROM prepay_admin.campaign_promotion_point_targets  
WHERE promotion_id = :promotionId  
  AND publish_status = 'PENDING'  
ORDER BY point_target_id ASC  
```  
  
### 5.4 Processor (Kafka 발행)  
  
#### EventProviderService 활용  
```java  
@Override  
public CampaignVoucherTargetDto process(CampaignVoucherTargetDto item) {  
    CampaignVoucherMessagePayload payload = CampaignVoucherMessagePayload.builder()  
        .eventId(item.getPromotionId().toString())  
        .voucherEventTargetId(item.getVoucherTargetId().toString())  
        .customerUid(item.getCustomerUid().toString())  
        .voucherNumber(item.getVoucherNumber())  
        .reason(item.getReason())  
        .partitionKey(item.getPartitionKey().toString())  
        .build();  
  
    eventProviderService.send(  
        PocketEventType.CAMPAIGN_VOUCHER_PUBLISH,  
        item.getPartitionKey().toString(),  
        payload  
    );  
  
    item.updatePublishStatus(PublishStatus.PUBLISHED);  
    return item;  
}  
```  
  
### 5.5 Writer (상태 업데이트)  
  
#### JdbcBatchItemWriter 활용  
```java  
@Bean  
public JdbcBatchItemWriter<CampaignVoucherTargetDto> voucherTargetStatusUpdateWriter() {  
    return new JdbcBatchItemWriterBuilder<CampaignVoucherTargetDto>()  
        .dataSource(prepayAdminDataSource)  
        .sql("""  
            UPDATE prepay_admin.campaign_promotion_voucher_targets  
            SET publish_status = :publishStatus, updated_at = NOW()  
            WHERE voucher_target_id = :voucherTargetId  
            """)  
        .beanMapped()  
        .build();  
}  
```  
  
---  
  
## 6. Kafka 설정  
  
### 6.1 Topic 설정  
```yaml  
# application-infrastructure-kafka.yml  
kafka:  
  topic:  
    campaignVoucherPublish: prepay.campaign.voucher.publish  
    campaignPointPublish: prepay.campaign.point.publish  
```  
  
### 6.2 PocketEventType 추가  
```java  
CAMPAIGN_VOUCHER_PUBLISH("CAMPAIGN_VOUCHER_PUBLISH", "캠페인 바우처 발행 이벤트"),  
CAMPAIGN_POINT_PUBLISH("CAMPAIGN_POINT_PUBLISH", "캠페인 포인트 발행 이벤트");  
```  
  
### 6.3 메시지 포맷  
  
#### 바우처 메시지  
```json  
{  
  "sentAt": "2026-01-21T10:30:00",  
  "version": 20231010,  
  "topic": "prepay.campaign.voucher.publish",  
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
  "topic": "prepay.campaign.point.publish",  
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
  
## 7. 구현 순서  
  
### Phase 1: Entity/Repository (prepay-admin 모듈)  
| 순서 | 작업 | 파일 |  
|-----|------|------|  
| 1-1 | Enum 클래스 생성 | PromotionType, PromotionStatus, PublishStatus, ProcessStatus |  
| 1-2 | Entity 클래스 생성 | 6개 테이블 매핑 Entity |  
| 1-3 | Repository 인터페이스 생성 | 6개 Repository |  
  
### Phase 2: Kafka 인프라 확장  
| 순서 | 작업 | 파일 |  
|-----|------|------|  
| 2-1 | EventType 추가 | PocketEventType.java |  
| 2-2 | EventProperty 추가 | EventProperty.java |  
| 2-3 | Topic 설정 추가 | application-infrastructure-kafka.yml |  
| 2-4 | EventProviderService 확장 | EventProviderService.java |  
| 2-5 | Payload DTO 생성 | CampaignVoucherMessagePayload, CampaignPointMessagePayload |  
  
### Phase 3: Publisher Batch Job  
| 순서 | 작업 | 파일 |  
|-----|------|------|  
| 3-1 | Job Parameter DTO | CampaignPromotionParameterDto |  
| 3-2 | Target DTO | CampaignVoucherTargetDto, CampaignPointTargetDto |  
| 3-3 | Reader | CampaignVoucherTargetReader, CampaignPointTargetReader |  
| 3-4 | Processor | CampaignVoucherKafkaPublishProcessor, CampaignPointKafkaPublishProcessor |  
| 3-5 | Writer | CampaignTargetStatusUpdateWriter |  
| 3-6 | Init Step | CampaignPromotionInitStep |  
| 3-7 | Decider | PromotionTypeDecider |  
| 3-8 | Publish Steps | CampaignVoucherPublishStep, CampaignPointPublishStep |  
| 3-9 | Main Job | CampaignPromotionPublisherBatch |  
  
---  
  
## 8. 참조 파일  
  
| 파일 | 용도 |  
|-----|------|  
| `persistence/rds/prepay-admin/prod/query/20260206_01_DDL_prepay_admin.sql` | DDL 스키마 |  
| `application/batch/.../job/MoneyOutboxRetryBatch.java` | Batch Job 패턴 참조 |  
| `infrastructure/kafka/.../service/EventProviderService.java` | Kafka 발행 서비스 |  
| `infrastructure/kafka/.../type/PocketEventType.java` | Event Type |  
| `persistence/rds/prepay-admin/.../config/PrepayAdminDbConfig.java` | DB 설정 |  
  
---  
  
## 9. 검증 방법  
  
### 9.1 단위 테스트  
- Reader: 쿼리 결과 검증  
- Processor: Kafka 메시지 발행 검증  
- Writer: 상태 업데이트 검증  
  
### 9.2 통합 테스트  
- H2 + Embedded Kafka 환경에서 전체 Job 흐름 테스트  
  
### 9.3 E2E 테스트  
1. Jenkins에서 배치 실행  
2. Kafka 토픽 메시지 확인  
3. DB 상태 변경 확인 (publish_status: PENDING → PUBLISHED)  
  
---  
  
## 10. 변경 이력  
  
| 버전 | 날짜 | 작성자 | 내용 |  
|-----|------|-------|------|  
| 1.0 | 2026-01-21 | - | 최초 작성 |