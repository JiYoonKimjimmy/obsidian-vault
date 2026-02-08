# 캠페인 프로모션 Publisher Batch 구현 체크리스트

> 이 문서는 [IMPLEMENTATION.md](IMPLEMENTATION.md)의 구현 순서를 체크리스트 형식으로 분리한 문서입니다.
> 각 Phase 완료 시 코드 리뷰 및 Git 커밋을 진행합니다.
> 
> (Git 커밋 시, `Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"` 문구는 제외)

---

## 구현 시 참고사항

| 참고 문서                                      | 내용                    |
|--------------------------------------------|-----------------------|
| **[IMPLEMENTATION.md](IMPLEMENTATION.md)** | 비즈니스 로직, 코드 예시, 상세 설계 |

**구현 전 반드시 확인할 내용**:
- 배치 Job 흐름 및 다이어그램 (Section 3)
- DTO/RowMapper 필드 정의 (Section 4)
- Kafka 메시지 Payload 구조 (Section 3.3)
- 에러 핸들링 전략 (Section 3.5)
- 핵심 파일 참조 - 기존 코드 패턴 (Section 7)

---

## Git 브랜치 전략

### Jira 티켓
- **티켓 번호**: PREPAY-952
- **최종 MR 브랜치**: `feature/PREPAY-952`
- **Target 브랜치**: `staging`

### Phase별 브랜치

| Phase | 브랜치명                              | 기반 브랜치                              | 머지 대상                |
|:-----:|-----------------------------------|-------------------------------------|----------------------|
|   -   | `feature/PREPAY-952`              | `staging`                           | `staging` (최종 MR)    |
|   1   | `feature/PREPAY-952-phase1-enums` | `feature/PREPAY-952`                | `feature/PREPAY-952` |
|   2   | `feature/PREPAY-952-phase2-kafka` | `feature/PREPAY-952` (Phase 1 머지 후) | `feature/PREPAY-952` |
|   3   | `feature/PREPAY-952-phase3-dto`   | `feature/PREPAY-952` (Phase 2 머지 후) | `feature/PREPAY-952` |
|   4   | `feature/PREPAY-952-phase4-batch` | `feature/PREPAY-952` (Phase 3 머지 후) | `feature/PREPAY-952` |
|   5   | `feature/PREPAY-952-phase5-deps`  | `feature/PREPAY-952` (Phase 4 머지 후) | `feature/PREPAY-952` |
|   6   | `feature/PREPAY-952-phase6-test`  | `feature/PREPAY-952` (Phase 5 머지 후) | `feature/PREPAY-952` |
|   7   | `feature/PREPAY-952-phase7-kafka` | `feature/PREPAY-952` (Phase 6 머지 후) | `feature/PREPAY-952` |

### 브랜치 워크플로우

1. staging에서 feature/PREPAY-952 생성
2. Phase별 브랜치 생성 및 작업:
   - feature/PREPAY-952에서 phase1 브랜치 생성 → 작업 → 머지
   - 머지된 feature/PREPAY-952에서 phase2 브랜치 생성 → 작업 → 머지
   - (반복 ~ phase7까지)
3. 모든 Phase 완료 후 feature/PREPAY-952 → staging MR 생성

### 롤백 전략

- **특정 Phase 수정 필요 시**: 해당 Phase 브랜치 체크아웃 → 수정 → 이후 Phase 순차 재머지
- **이전 상태로 복원 시**: `feature/PREPAY-952`를 원하는 Phase 머지 시점 커밋으로 리셋

### Git 커밋 규칙

- **Co-Authored-By 제외**: 커밋 메시지에 `Co-Authored-By` 라인을 포함하지 않음

---

## Phase 1: Enum 클래스 (support 모듈)

### 구현 항목
- [x] 1-1. `PromotionType.java` - VOUCHER, POINT
- [x] 1-2. `PromotionStatus.java` - READY, IN_PROGRESS, COMPLETED, STOPPED, FAILED
- [x] 1-3. `PublishStatus.java` - PENDING, PUBLISHED, FAILED
- [x] 1-4. `ProcessStatus.java` - SUCCESS, RETRYING, FAILED

### Phase 1 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 1: Enum 클래스

- PromotionType (VOUCHER, POINT)
- PromotionStatus (READY, IN_PROGRESS, COMPLETED, STOPPED, FAILED)
- PublishStatus (PENDING, PUBLISHED, FAILED)
- ProcessStatus (SUCCESS, RETRYING, FAILED)
```

---

## Phase 2: Kafka 인프라 확장

### 구현 항목
- [x] 2-1. `PocketEventType.java` - CAMPAIGN_PROMOTION_VOUCHER_PUBLISH, CAMPAIGN_PROMOTION_POINT_PUBLISH 추가
- [x] 2-2. `EventProperty.java` - campaign topic 설정 추가
- [x] 2-3. `application-infrastructure-kafka.yml` - topic 추가
- [x] 2-4. `EventProviderService.java` - switch case 추가
- [x] 2-5. `CampaignPromotionVoucherMessagePayload.java` - 메시지 Payload DTO 생성
- [x] 2-6. `CampaignPromotionPointMessagePayload.java` - 메시지 Payload DTO 생성

### Phase 2 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 2: Kafka 인프라 확장

- PocketEventType에 캠페인 프로모션 이벤트 타입 추가
- EventProperty에 campaign topic 설정 추가
- CampaignVoucherMessagePayload, CampaignPointMessagePayload DTO 생성
```

---

## Phase 3: DTO + RowMapper (batch 모듈)

### 구현 항목
- [x] 3-1. `CampaignPromotionDto.java` - 프로모션 DTO
- [x] 3-2. `CampaignPromotionRowMapper.java` - 프로모션 RowMapper
- [x] 3-3. `CampaignVoucherTargetDto.java` - 바우처 대상 DTO (updatePublishStatus 메서드 포함)
- [x] 3-4. `CampaignVoucherTargetRowMapper.java` - 바우처 RowMapper
- [x] 3-5. `CampaignPointTargetDto.java` - 포인트 대상 DTO (updatePublishStatus 메서드 포함)
- [x] 3-6. `CampaignPointTargetRowMapper.java` - 포인트 RowMapper

### Phase 3 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 3: DTO + RowMapper

- CampaignPromotionDto, CampaignPromotionRowMapper
- CampaignVoucherTargetDto, CampaignVoucherTargetRowMapper
- CampaignPointTargetDto, CampaignPointTargetRowMapper
```

---

## Phase 4: Publisher Batch Job

### 구현 항목

#### Tasklet 클래스 (Plain class)
- [x] 4-1. `CampaignPromotionInitTasklet.java` - Init Step Tasklet (`job/campaign/tasklet/`)
- [x] 4-2. `CampaignPromotionFinalizeTasklet.java` - Finalize Step Tasklet (`job/campaign/tasklet/`)

#### Decider 클래스 (Plain class)
- [x] 4-3. `PromotionTypeDecider.java` - JobExecutionDecider 구현 (`decider/`)

#### Partitioner 클래스 (@JobScope @Component)
- [x] 4-4. `CampaignPromotionPartitioner.java` - 공통 Partitioner 구현 (`job/campaign/partitioner/`)

#### Reader/Processor/Writer 클래스 (Plain class)
- [x] 4-5. `VoucherWorkerReader.java` - Voucher Reader 구현 (`job/campaign/reader/`)
- [x] 4-6. `PointWorkerReader.java` - Point Reader 구현 (`job/campaign/reader/`)
- [x] 4-7. `VoucherWorkerProcessor.java` - Voucher Processor 구현 (`job/campaign/processor/`)
- [x] 4-8. `PointWorkerProcessor.java` - Point Processor 구현 (`job/campaign/processor/`)
- [x] 4-9. `VoucherWorkerWriter.java` - Voucher Writer 구현 (`job/campaign/writer/`)
- [x] 4-10. `PointWorkerWriter.java` - Point Writer 구현 (`job/campaign/writer/`)

#### Step 클래스 (@Configuration)
- [x] 4-11. `VoucherWorkerStep.java` - Voucher Worker Step 정의 (`job/campaign/step/`)
- [x] 4-12. `PointWorkerStep.java` - Point Worker Step 정의 (`job/campaign/step/`)

#### Job 클래스 (@Configuration)
- [x] 4-13. `CampaignPromotionPublisherBatch.java` - 메인 Job Flow 정의 (`job/campaign/`)

### 구현 의존성 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Phase 4 구현 순서 (의존성 기준)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ [독립적 구현 가능 - Plain class]                                       │    │
│  │                                                                     │    │
│  │  4-1 InitTasklet    4-2 FinalizeTasklet    4-3 Decider             │    │
│  │  4-5~6 Reader       4-7~8 Processor         4-9~10 Writer           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ [독립적 구현 가능 - @JobScope @Component]                               │    │
│  │                                                                     │    │
│  │  4-4 Partitioner                                                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│                          ↓ Reader/Processor/Writer 완료 후                   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ [Step 클래스 - @Configuration]                                       │    │
│  │                                                                     │    │
│  │  4-11 VoucherWorkerStep (Reader/Processor/Writer 조합)              │    │
│  │  4-12 PointWorkerStep (Reader/Processor/Writer 조합)                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│                          ↓ 모든 컴포넌트 완료 후                               │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ 4-13 CampaignPromotionPublisherBatch.java                          │    │
│  │      - Job Flow 정의 (루프 구조)                                      │    │
│  │      - Step Bean 주입 (@Qualifier)                                  │    │
│  │      - TaskExecutorPartitionHandler 설정                            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 구현 시 주의사항

| 순서      | 주의사항                                                                  |
|---------|-----------------------------------------------------------------------|
| 4-1~2   | **Plain class** Tasklet, 생성자로 DataSource 주입                           |
| 4-3     | **Plain class** JobExecutionDecider 구현, Job에서 Bean으로 등록               |
| 4-4     | `@JobScope @Component`, Partitioner 구현, null 방어 로직 포함                 |
| 4-5~6   | **Plain class**, `create()` 메서드로 JdbcPagingItemReader 생성              |
| 4-7~8   | **Plain class**, 생성자로 EventProviderService 주입                         |
| 4-9~10  | **Plain class**, 생성자로 DataSource 주입                                   |
| 4-11~12 | `@Configuration`, `@StepScope @Bean` Step 메서드, private helper methods |
| 4-13    | Step Bean 주입 (@Qualifier), 루프 Flow 구조, TaskExecutorPartitionHandler   |

### Phase 4 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 4: Publisher Batch Job

- Tasklet: CampaignPromotionInitTasklet, CampaignPromotionFinalizeTasklet
- Decider: PromotionTypeDecider (VOUCHER/POINT/NONE 분기)
- Partitioner: CampaignPromotionPartitioner (@JobScope @Component)
- Reader: VoucherWorkerReader, PointWorkerReader (Plain class + create())
- Processor: VoucherWorkerProcessor, PointWorkerProcessor (Plain class)
- Writer: VoucherWorkerWriter, PointWorkerWriter (Plain class)
- Step: VoucherWorkerStep, PointWorkerStep (@Configuration)
- Job: CampaignPromotionPublisherBatch (루프 구조)
```

---

## Phase 5: 의존성 설정

### 구현 항목
- [x] 5-1. `build.gradle.kts` - `projects.persistenceRdsPrepayAdmin` 의존성 추가

### Phase 5 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 5: 의존성 설정

- application/batch 모듈에 persistenceRdsPrepayAdmin 의존성 추가
```

---

## Phase 6: 테스트 코드

### 구현 항목

#### Tasklet 테스트
- [x] 6-1. `CampaignPromotionInitTaskletTest.java` - Init Tasklet 단위 테스트
- [x] 6-2. `CampaignPromotionFinalizeTaskletTest.java` - Finalize Tasklet 단위 테스트

#### Decider 테스트
- [x] 6-3. `PromotionTypeDeciderTest.java` - Decider 단위 테스트

#### Partitioner 테스트
- [x] 6-4. `CampaignPromotionPartitionerTest.java` - Partitioner 단위 테스트

#### Reader 테스트
- [x] 6-5. `VoucherWorkerReaderTest.java` - Voucher Reader 단위 테스트
- [x] 6-6. `PointWorkerReaderTest.java` - Point Reader 단위 테스트

#### Processor 테스트
- [x] 6-7. `VoucherWorkerProcessorTest.java` - Voucher Processor 단위 테스트
- [x] 6-8. `PointWorkerProcessorTest.java` - Point Processor 단위 테스트

#### Writer 테스트
- [x] 6-9. `VoucherWorkerWriterTest.java` - Voucher Writer 단위 테스트
- [x] 6-10. `PointWorkerWriterTest.java` - Point Writer 단위 테스트

#### RowMapper 테스트
- [x] 6-11. `CampaignVoucherTargetRowMapperTest.java` - Voucher RowMapper 단위 테스트
- [x] 6-12. `CampaignPointTargetRowMapperTest.java` - Point RowMapper 단위 테스트
- [x] 6-13. `CampaignPromotionRowMapperTest.java` - Promotion RowMapper 단위 테스트

### Phase 6 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew build`)
- [x] 단위 테스트 통과 (`./gradlew test`)
- [x] Git 커밋 완료
- [x] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[feat] PREPAY-952 Phase 6: 테스트 코드

- Tasklet: CampaignPromotionInitTaskletTest, CampaignPromotionFinalizeTaskletTest
- Decider: PromotionTypeDeciderTest
- Partitioner: CampaignPromotionPartitionerTest
- Reader: VoucherWorkerReaderTest, PointWorkerReaderTest
- Processor: VoucherWorkerProcessorTest, PointWorkerProcessorTest
- Writer: VoucherWorkerWriterTest, PointWorkerWriterTest
- RowMapper: CampaignVoucherTargetRowMapperTest, CampaignPointTargetRowMapperTest, CampaignPromotionRowMapperTest
```

---

## Phase 7: Kafka 메시지 구조 개선

### 구현 항목

#### Kafka 메시지 Payload 수정 (kafka 모듈)
- [x] 7-1. `CampaignPromotionVoucherMessagePayload.java` - 필드명 변경 및 신규 필드 추가
  - `eventId` → `promotionId`, `voucherEventTargetId` → `voucherTargetId`, `reason` → `description`
  - 신규: `promotionSummaryId`, `campaignCode`
- [x] 7-2. `CampaignPromotionPointMessagePayload.java` - 필드명 변경 및 신규 필드 추가
  - `eventId` → `promotionId`, `pointEventTargetId` → `pointTargetId`, `expiryAt` → `expiredAt`
  - 신규: `promotionSummaryId`, `merchantCode`, `campaignCode`

#### DTO 수정 (batch 모듈)
- [x] 7-3. `CampaignVoucherTargetDto.java` - `promotionSummaryId`, `campaignCode` 필드 추가
- [x] 7-4. `CampaignPointTargetDto.java` - `promotionSummaryId`, `merchantCode`, `campaignCode` 필드 추가

#### RowMapper 수정 (batch 모듈)
- [x] 7-5. `CampaignVoucherTargetRowMapper.java` - 신규 필드 매핑 추가
- [x] 7-6. `CampaignPointTargetRowMapper.java` - 신규 필드 매핑 추가

#### Reader 수정 (batch 모듈)
- [x] 7-7. `VoucherWorkerReader.java` - JOIN 쿼리 추가 (campaign_promotion_summary, campaign_promotions)
- [x] 7-8. `PointWorkerReader.java` - JOIN 쿼리 추가 (campaign_promotion_summary, campaign_promotions)

#### Processor 수정 (batch 모듈)
- [x] 7-9. `VoucherWorkerProcessor.java` - 새 필드명으로 Payload 빌드 수정
- [x] 7-10. `PointWorkerProcessor.java` - 새 필드명으로 Payload 빌드 수정

#### 테스트 코드 수정
- [x] 7-11. `CampaignPromotionVoucherMessagePayloadTest.java` - 필드명 변경 반영
- [x] 7-12. `CampaignPromotionPointMessagePayloadTest.java` - 필드명 변경 반영
- [x] 7-13. `CampaignVoucherTargetRowMapperTest.java` - 신규 필드 테스트 추가
- [x] 7-14. `CampaignPointTargetRowMapperTest.java` - 신규 필드 테스트 추가
- [x] 7-15. `VoucherWorkerReaderTest.java` - JOIN 테스트 반영
- [x] 7-16. `PointWorkerReaderTest.java` - JOIN 테스트 반영
- [x] 7-17. `VoucherWorkerProcessorTest.java` - 새 필드명 반영
- [x] 7-18. `PointWorkerProcessorTest.java` - 새 필드명 반영
- [x] 7-19. `EventProviderServiceTest.java` - 새 필드명 반영

#### H2 테스트 스키마 수정
- [x] 7-20. `schema-h2.sql` - `campaign_promotion_summary` 테이블 추가

### Phase 7 완료 체크
- [x] 코드 리뷰 완료
- [x] 빌드 성공 확인 (`./gradlew :batch:compileJava :kafka:compileJava`)
- [x] 단위 테스트 통과 (`./gradlew :batch:test :kafka:test`)
- [ ] Git 커밋 완료
- [ ] feature/PREPAY-952 브랜치 머지 완료

### 커밋 메시지 예시
```
[refactor] PREPAY-952: Kafka 메시지 구조 변경

- Voucher/Point MessagePayload 필드명 변경 및 신규 필드 추가
- DTO, RowMapper, Reader, Processor 수정
- 테스트 코드 업데이트
```

---

## 최종 완료 체크리스트

### 전체 Phase 완료 확인
- [x] Phase 1: Enum 클래스 완료
- [x] Phase 2: Kafka 인프라 확장 완료
- [x] Phase 3: DTO + RowMapper 완료
- [x] Phase 4: Publisher Batch Job 완료
- [x] Phase 5: 의존성 설정 완료
- [x] Phase 6: 테스트 코드 완료
- [x] Phase 7: Kafka 메시지 구조 개선 완료

### 최종 MR 준비
- [ ] feature/PREPAY-952 → staging MR 생성
- [x] 전체 빌드 성공 확인
- [x] 전체 테스트 통과 확인
- [ ] 코드 리뷰 완료
- [ ] MR 승인 및 머지
