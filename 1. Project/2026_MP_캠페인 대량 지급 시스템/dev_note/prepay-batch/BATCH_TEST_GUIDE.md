# Spring Batch 통합 테스트 가이드

이 문서는 Spring Batch Job 신규 생성 시 참고할 통합 테스트 코드 작성 가이드입니다.

---

## 1. 개요

### 테스트 인프라 구조

```
application/batch/src/test/
├── java/.../support/
│   ├── H2DataSourceConfig.java      # H2 DataSource 생성 유틸리티
│   ├── H2Functions.java             # MySQL 함수 호환성 (DATE_FORMAT 등)
│   ├── AbstractH2IntegrationTest.java  # Reader/Writer/Tasklet 단위 테스트 베이스
│   └── BatchIntegrationTestConfig.java # Job 통합 테스트 설정
└── resources/
    └── schema-h2.sql                # H2용 테스트 스키마
```

### 지원하는 테스트 유형

| 테스트 유형      | 베이스 클래스                      | 용도                            |
|-------------|------------------------------|-------------------------------|
| Reader 테스트  | `AbstractH2IntegrationTest`  | `JdbcPagingItemReader` 단위 테스트 |
| Writer 테스트  | `AbstractH2IntegrationTest`  | `JdbcBatchItemWriter` 단위 테스트  |
| Tasklet 테스트 | `AbstractH2IntegrationTest`  | Tasklet 로직 단위 테스트             |
| Job 통합 테스트  | `BatchIntegrationTestConfig` | 전체 Job 흐름 검증                  |

---

## 2. 테스트 설정 클래스 설명

### H2DataSourceConfig

H2 인메모리 데이터베이스 DataSource를 생성하는 유틸리티 클래스입니다.

```java
public final class H2DataSourceConfig {

    public static DriverManagerDataSource createDataSource() {
        DriverManagerDataSource ds = new DriverManagerDataSource();
        ds.setDriverClassName("org.h2.Driver");
        ds.setUrl("jdbc:h2:mem:testdb;MODE=MySQL;DB_CLOSE_DELAY=-1");
        ds.setUsername("sa");
        ds.setPassword("");
        return ds;
    }

    public static void initializeSchema(DataSource dataSource, String... scripts) throws SQLException {
        try (Connection conn = dataSource.getConnection()) {
            for (String script : scripts) {
                ScriptUtils.executeSqlScript(conn, new ClassPathResource(script));
            }
        }
    }
}
```

**주요 특징:**
- MySQL 호환 모드(`MODE=MySQL`)로 H2 데이터베이스 생성
- `DB_CLOSE_DELAY=-1`로 테스트 간 연결 유지
- `initializeSchema()`를 통해 여러 SQL 스크립트 순차 실행 가능

### H2Functions

MySQL 함수 호환성을 위한 유틸리티 클래스입니다. H2의 `CREATE ALIAS`를 통해 사용됩니다.

```java
public final class H2Functions {

    /**
     * MySQL DATE_FORMAT 함수 호환 구현.
     * 지원하는 포맷: %Y, %m, %d, %H, %i, %s
     */
    public static String dateFormat(Timestamp timestamp, String format) {
        if (timestamp == null) {
            return null;
        }
        LocalDateTime dateTime = timestamp.toLocalDateTime();
        String javaFormat = format
            .replace("%Y", "yyyy")
            .replace("%m", "MM")
            .replace("%d", "dd")
            .replace("%H", "HH")
            .replace("%i", "mm")
            .replace("%s", "ss");
        return dateTime.format(DateTimeFormatter.ofPattern(javaFormat));
    }
}
```

### AbstractH2IntegrationTest

Reader/Writer/Tasklet 단위 테스트를 위한 추상 베이스 클래스입니다.

```java
public abstract class AbstractH2IntegrationTest {

    protected static DriverManagerDataSource dataSource;
    protected static JdbcTemplate jdbcTemplate;

    @BeforeAll
    static void setUpH2Database() throws SQLException {
        if (dataSource == null) {
            dataSource = H2DataSourceConfig.createDataSource();
            jdbcTemplate = new JdbcTemplate(dataSource);
            H2DataSourceConfig.initializeSchema(dataSource, "schema-h2.sql");
        }
    }
}
```

**특징:**
- Spring Context 없이 순수 H2 기반 테스트
- `@BeforeAll`에서 한 번만 DataSource 초기화 (싱글톤 패턴)
- 하위 테스트에서 `dataSource`와 `jdbcTemplate` 바로 사용 가능

### BatchIntegrationTestConfig

Spring Batch Job 통합 테스트를 위한 설정 클래스입니다.

```java
@EnableBatchProcessing
@TestConfiguration
public class BatchIntegrationTestConfig {

    @Bean(name = {"prepayAdminDataSource", "dataSource"})
    @Primary
    public DataSource prepayAdminDataSource() throws SQLException {
        DataSource dataSource = H2DataSourceConfig.createDataSource();
        H2DataSourceConfig.initializeSchema(dataSource,
            "org/springframework/batch/core/schema-h2.sql",  // Spring Batch 메타 테이블
            "schema-h2.sql"                                   // 비즈니스 테이블
        );
        return dataSource;
    }

    @Bean
    public JdbcTemplate jdbcTemplate(DataSource prepayAdminDataSource) {
        return new JdbcTemplate(prepayAdminDataSource);
    }

    @Bean
    @Primary
    public PlatformTransactionManager transactionManager(DataSource prepayAdminDataSource) {
        return new DataSourceTransactionManager(prepayAdminDataSource);
    }

    @Bean
    public BatchJobListener batchJobListener() {
        return new BatchJobListener();
    }
}
```

**특징:**
- `@EnableBatchProcessing`으로 Spring Batch 인프라 자동 구성
- Spring Batch 메타 테이블 스키마(`schema-h2.sql`) 자동 초기화
- `prepayAdminDataSource` 빈 이름으로 실제 DataSource 대체

---

## 3. 테스트 유형별 작성 가이드

### 3.1 Reader 테스트

`JdbcPagingItemReader`를 테스트하려면 `AbstractH2IntegrationTest`를 상속합니다.

**패턴:**

```java
class VoucherWorkerReaderTest extends AbstractH2IntegrationTest {

    private VoucherWorkerReader reader;
    private JdbcPagingItemReader<CampaignVoucherTargetDto> itemReader;

    @BeforeEach
    void setUp() {
        // 1. 데이터 정리
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_voucher_targets");

        // 2. Reader 인스턴스 생성
        reader = new VoucherWorkerReader(dataSource);
    }

    @AfterEach
    void tearDown() {
        // 3. ItemReader 리소스 해제
        if (itemReader != null) {
            itemReader.close();
        }
    }

    @Test
    @DisplayName("PENDING 상태의 데이터만 조회한다")
    void shouldReadOnlyPendingStatusData() throws Exception {
        // given
        insertVoucherTarget(1L, PublishStatus.PENDING.name());
        insertVoucherTarget(2L, PublishStatus.PUBLISHED.name());

        // 4. ItemReader 초기화
        itemReader = reader.create(promotionId, partitionKey);
        itemReader.afterPropertiesSet();
        itemReader.open(new ExecutionContext());

        // when & then
        CampaignVoucherTargetDto item1 = itemReader.read();
        assertThat(item1).isNotNull();
        assertThat(item1.getVoucherTargetId()).isEqualTo(1L);

        CampaignVoucherTargetDto item2 = itemReader.read();
        assertThat(item2).isNull();  // 더 이상 읽을 데이터 없음
    }

    private void insertVoucherTarget(Long id, String publishStatus) {
        jdbcTemplate.update("""
            INSERT INTO prepay_admin.campaign_promotion_voucher_targets
            (voucher_target_id, promotion_id, ..., publish_status, ...)
            VALUES (?, ?, ..., ?, ...)
            """,
            id, promotionId, ..., publishStatus, ...
        );
    }
}
```

**핵심 포인트:**
- `itemReader.afterPropertiesSet()` 호출 필수
- `itemReader.open(new ExecutionContext())` 호출 필수
- `@AfterEach`에서 `itemReader.close()` 호출
- `read()`가 `null`을 반환하면 더 이상 데이터 없음

### 3.2 Writer 테스트

`JdbcBatchItemWriter`를 테스트하려면 `AbstractH2IntegrationTest`를 상속합니다.

**패턴:**

```java
class VoucherWorkerWriterTest extends AbstractH2IntegrationTest {

    private JdbcBatchItemWriter<CampaignVoucherTargetDto> writer;

    @BeforeEach
    void setUp() {
        // 1. 데이터 정리
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_voucher_targets");

        // 2. Writer 인스턴스 생성 및 초기화
        writer = new VoucherWorkerWriter(dataSource).create();
        writer.afterPropertiesSet();
    }

    @Test
    @DisplayName("chunk의 각 항목에 대해 DB의 publish_status를 업데이트한다")
    void shouldUpdatePublishStatusInDatabase() throws Exception {
        // given
        insertVoucherTarget(1L, PublishStatus.PENDING.name());
        insertVoucherTarget(2L, PublishStatus.PENDING.name());

        CampaignVoucherTargetDto item1 = createVoucherTargetDto(1L, PublishStatus.PUBLISHED.name());
        CampaignVoucherTargetDto item2 = createVoucherTargetDto(2L, PublishStatus.FAILED.name());

        // 3. Chunk 생성
        Chunk<CampaignVoucherTargetDto> chunk = new Chunk<>(List.of(item1, item2));

        // when
        writer.write(chunk);

        // then
        assertThat(getPublishStatus(1L)).isEqualTo(PublishStatus.PUBLISHED.name());
        assertThat(getPublishStatus(2L)).isEqualTo(PublishStatus.FAILED.name());
    }

    private String getPublishStatus(Long id) {
        return jdbcTemplate.queryForObject(
            "SELECT publish_status FROM ... WHERE voucher_target_id = ?",
            String.class, id
        );
    }
}
```

**핵심 포인트:**
- `writer.afterPropertiesSet()` 호출 필수
- `Chunk<T>` 객체를 직접 생성하여 테스트
- DB 조회로 실제 변경 결과 검증

### 3.3 Tasklet 테스트

Tasklet을 테스트하려면 `AbstractH2IntegrationTest`를 상속하고, `ChunkContext`와 `StepExecution`을 Mock으로 설정합니다.

**패턴:**

```java
@DisplayName("CampaignPromotionInitTasklet 통합 테스트")
class CampaignPromotionInitTaskletTest extends AbstractH2IntegrationTest {

    private CampaignPromotionInitTasklet tasklet;

    private StepContribution contribution;
    private ChunkContext chunkContext;
    private ExecutionContext jobContext;

    @BeforeEach
    void setUp() {
        // 1. Tasklet 생성
        tasklet = new CampaignPromotionInitTasklet(dataSource);

        // 2. Mock 설정 (핵심!)
        contribution = mock(StepContribution.class);
        chunkContext = mock(ChunkContext.class);
        StepContext stepContext = mock(StepContext.class);
        StepExecution stepExecution = mock(StepExecution.class);
        JobExecution jobExecution = mock(JobExecution.class);
        JobParameters jobParameters = mock(JobParameters.class);
        jobContext = new ExecutionContext();  // 실제 객체 사용

        // 3. Mock 체이닝 설정
        when(chunkContext.getStepContext()).thenReturn(stepContext);
        when(stepContext.getStepExecution()).thenReturn(stepExecution);
        when(stepExecution.getJobExecution()).thenReturn(jobExecution);
        when(jobExecution.getExecutionContext()).thenReturn(jobContext);
        when(jobExecution.getJobParameters()).thenReturn(jobParameters);
        when(jobParameters.getString("executionTime")).thenReturn(null);
    }

    @AfterEach
    void tearDown() {
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotions");
    }

    @Test
    @DisplayName("READY 상태 프로모션이 있으면 상태를 IN_PROGRESS로 변경한다")
    void shouldUpdateStatusWhenReadyPromotionExists() {
        // given
        insertPromotion(100L, PromotionStatus.READY.name(), 5);

        // when
        RepeatStatus result = tasklet.execute(contribution, chunkContext);

        // then
        assertThat(result).isEqualTo(RepeatStatus.FINISHED);
        assertThat(jobContext.getLong("promotionId")).isEqualTo(100L);
        assertThat(jobContext.getInt("partitionCount")).isEqualTo(5);

        // DB 상태 검증
        String status = jdbcTemplate.queryForObject(
            "SELECT promotion_status FROM ... WHERE promotion_id = ?",
            String.class, 100L
        );
        assertThat(status).isEqualTo(PromotionStatus.IN_PROGRESS.name());
    }
}
```

**핵심 포인트:**
- `ExecutionContext`는 실제 객체를 사용하여 값 저장/검증
- Mock 체이닝으로 `chunkContext → stepContext → stepExecution → jobExecution` 연결
- Tasklet의 반환값 `RepeatStatus` 검증
- `ExecutionContext`에 저장된 값과 DB 상태 모두 검증

### 3.4 Job 통합 테스트

전체 Job 흐름을 테스트하려면 `@SpringBatchTest`와 `@SpringBootTest`를 조합합니다.

**패턴:**

```java
@SpringBatchTest
@SpringBootTest(classes = {
    BatchIntegrationTestConfig.class,  // 필수: 테스트 설정
    CampaignPromotionPublisherBatch.class,  // Job 정의 클래스
    VoucherWorkerStep.class,  // Step 정의 클래스
    PointWorkerStep.class
})
@DisplayName("CampaignPromotionPublisherJob 통합 테스트")
class CampaignPromotionPublisherJobIntegrationTest {

    @Autowired
    private JobLauncherTestUtils jobLauncherTestUtils;

    @Autowired
    @Qualifier(CampaignPromotionPublisherBatch.JOB_NAME)
    private Job campaignPromotionPublisherJob;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @MockBean
    private EventProviderService eventProviderService;  // 외부 의존성 Mock

    @BeforeEach
    void setUp() {
        // 1. 테스트할 Job 설정
        jobLauncherTestUtils.setJob(campaignPromotionPublisherJob);

        // 2. Mock 동작 설정
        doNothing().when(eventProviderService).send(any(), any(), any());
    }

    @AfterEach
    void tearDown() {
        // 3. 테스트 데이터 정리
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_voucher_targets");
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_summary");
        jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotions");
    }

    @Test
    @DisplayName("VOUCHER 타입 프로모션의 전체 처리 흐름을 검증한다")
    void shouldProcessVoucherPromotion() throws Exception {
        // given
        Long promotionId = 100L;
        insertPromotion(promotionId, PromotionType.VOUCHER, PromotionStatus.READY, 2);
        insertPromotionSummary(promotionId);
        insertVoucherTarget(promotionId, 0, 1000L);
        insertVoucherTarget(promotionId, 0, 1001L);

        // when
        JobExecution jobExecution = jobLauncherTestUtils.launchJob(createJobParameters());

        // then
        assertThat(jobExecution.getStatus()).isEqualTo(BatchStatus.COMPLETED);

        // DB 상태 검증
        String promotionStatus = jdbcTemplate.queryForObject(
            "SELECT promotion_status FROM ... WHERE promotion_id = ?",
            String.class, promotionId
        );
        assertThat(promotionStatus).isEqualTo(PromotionStatus.IN_PROGRESS.name());

        // Mock 호출 검증
        verify(eventProviderService, times(2))
            .send(eq(PocketEventType.CAMPAIGN_PROMOTION_VOUCHER_PUBLISH), any(), any());
    }

    private JobParameters createJobParameters() {
        return new JobParametersBuilder()
            .addLong("run.id", System.currentTimeMillis())  // 중복 실행 방지
            .toJobParameters();
    }
}
```

**핵심 포인트:**
- `@SpringBootTest(classes = {...})`에 필요한 클래스만 명시적으로 나열
- `BatchIntegrationTestConfig.class` 필수 포함
- `jobLauncherTestUtils.setJob()`으로 테스트할 Job 설정
- `JobParametersBuilder`로 고유한 JobParameters 생성 (매 실행마다 다른 `run.id`)
- `@MockBean`으로 외부 의존성(Kafka, API 등) Mock 처리

---

## 4. 테스트 데이터 관리

### schema-h2.sql 스키마 파일 관리

`src/test/resources/schema-h2.sql` 파일에 테스트용 테이블 스키마를 정의합니다.

```sql
-- H2 테스트용 스키마 생성 (MySQL 호환 모드)

-- prepay_admin 스키마 생성
CREATE SCHEMA IF NOT EXISTS prepay_admin;

-- MySQL DATE_FORMAT 함수 호환을 위한 alias 생성
CREATE ALIAS IF NOT EXISTS DATE_FORMAT FOR "com.musinsapayments.prepay.application.batch.support.H2Functions.dateFormat";

-- campaign_promotions 테이블 생성
CREATE TABLE IF NOT EXISTS prepay_admin.campaign_promotions (
    promotion_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    campaign_code VARCHAR(100),
    promotion_type VARCHAR(50),
    promotion_status VARCHAR(50),
    -- ... 기타 컬럼
);
```

**주의사항:**
- 실제 운영 DDL과 동기화 유지 필요
- `IF NOT EXISTS` 사용으로 중복 생성 방지
- MySQL 함수 사용 시 `CREATE ALIAS` 정의 필요

### 테스트 데이터 삽입 헬퍼 메서드 패턴

각 테스트 클래스에 `private` 헬퍼 메서드를 정의합니다.

```java
private void insertPromotion(Long promotionId, PromotionType type, PromotionStatus status, Integer partitionCount) {
    String sql = """
        INSERT INTO prepay_admin.campaign_promotions
        (promotion_id, campaign_code, promotion_type, promotion_status, partition_count, ...)
        VALUES (?, ?, ?, ?, ?, ...)
        """;

    LocalDateTime now = LocalDateTime.now();
    jdbcTemplate.update(sql,
        promotionId,
        "CAMPAIGN-" + promotionId,
        type.name(),
        status.name(),
        partitionCount,
        // ...
    );
}
```

### @BeforeEach/@AfterEach 데이터 정리

```java
@BeforeEach
void setUp() {
    // 테스트 전 데이터 정리 (선택적)
    jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_voucher_targets");
}

@AfterEach
void tearDown() {
    // 테스트 후 데이터 정리 (필수)
    jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_voucher_targets");
    jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotion_summary");
    jdbcTemplate.execute("DELETE FROM prepay_admin.campaign_promotions");
}
```

**권장사항:**
- 외래키 제약이 있는 경우 자식 테이블부터 삭제
- `@AfterEach`에서 정리하여 다음 테스트에 영향 방지

---

## 5. MySQL 함수 호환성

### H2Functions 클래스를 통한 함수 추가 방법

1. `H2Functions` 클래스에 static 메서드 추가:

```java
public static String dateFormat(Timestamp timestamp, String format) {
    // MySQL 포맷 → Java DateTimeFormatter 포맷 변환
    String javaFormat = format
        .replace("%Y", "yyyy")
        .replace("%m", "MM")
        .replace("%d", "dd")
        .replace("%H", "HH")
        .replace("%i", "mm")
        .replace("%s", "ss");
    return dateTime.format(DateTimeFormatter.ofPattern(javaFormat));
}
```

2. `schema-h2.sql`에 `CREATE ALIAS` 추가:

```sql
CREATE ALIAS IF NOT EXISTS DATE_FORMAT FOR "com.musinsapayments.prepay.application.batch.support.H2Functions.dateFormat";
```

3. SQL에서 MySQL과 동일하게 사용:

```sql
SELECT DATE_FORMAT(created_at, '%Y-%m-%d %H:%i') FROM ...
```

### 새로운 MySQL 함수 추가 예제

`IFNULL` 함수를 추가하는 경우:

```java
// H2Functions.java
public static Object ifNull(Object value, Object defaultValue) {
    return value != null ? value : defaultValue;
}
```

```sql
-- schema-h2.sql
CREATE ALIAS IF NOT EXISTS IFNULL FOR "com.musinsapayments.prepay.application.batch.support.H2Functions.ifNull";
```

---

## 6. 체크리스트

새 배치 Job 테스트 작성 시 점검 항목:

### Reader 테스트
- [ ] `AbstractH2IntegrationTest` 상속
- [ ] `@BeforeEach`에서 데이터 정리 및 Reader 인스턴스 생성
- [ ] `@AfterEach`에서 `itemReader.close()` 호출
- [ ] `afterPropertiesSet()` 및 `open(new ExecutionContext())` 호출
- [ ] 경계 조건 테스트 (데이터 없음, 필터링, 정렬)

### Writer 테스트
- [ ] `AbstractH2IntegrationTest` 상속
- [ ] `@BeforeEach`에서 데이터 정리 및 Writer 인스턴스 생성
- [ ] `afterPropertiesSet()` 호출
- [ ] `Chunk<T>` 객체로 `write()` 호출
- [ ] DB 조회로 실제 변경 결과 검증
- [ ] 빈 Chunk, 존재하지 않는 ID 등 예외 케이스 테스트

### Tasklet 테스트
- [ ] `AbstractH2IntegrationTest` 상속
- [ ] Mock 설정: `ChunkContext → StepContext → StepExecution → JobExecution` 체이닝
- [ ] `ExecutionContext`는 실제 객체 사용
- [ ] `RepeatStatus` 반환값 검증
- [ ] `ExecutionContext`에 저장된 값 검증
- [ ] DB 상태 변경 검증

### Job 통합 테스트
- [ ] `@SpringBatchTest` + `@SpringBootTest(classes = {...})` 어노테이션
- [ ] `BatchIntegrationTestConfig.class` 포함
- [ ] 필요한 Job, Step 클래스 명시적 포함
- [ ] `@MockBean`으로 외부 의존성 Mock 처리
- [ ] `@BeforeEach`에서 `jobLauncherTestUtils.setJob()` 호출
- [ ] `JobParametersBuilder`로 고유한 JobParameters 생성
- [ ] `@AfterEach`에서 테스트 데이터 정리
- [ ] `JobExecution.getStatus()` 검증
- [ ] DB 상태 변경 검증
- [ ] Mock 호출 횟수/인자 검증

### 스키마 관리
- [ ] 새 테이블 사용 시 `schema-h2.sql`에 DDL 추가
- [ ] MySQL 함수 사용 시 `H2Functions`에 구현 및 `CREATE ALIAS` 추가
- [ ] 운영 DDL과 테스트 스키마 동기화 확인
