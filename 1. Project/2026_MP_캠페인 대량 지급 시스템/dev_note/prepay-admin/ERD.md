# Campaign Promotion ERD

## 개요

캠페인 프로모션 시스템의 데이터베이스 스키마입니다. 바우처(Voucher)와 포인트(Point) 두 가지 프로모션 타입을 지원합니다.

## ERD (Entity Relationship Diagram)

```mermaid
erDiagram
    campaign_promotions {
        BIGINT promotion_id PK "프로모션 ID"
        VARCHAR campaign_code UK "캠페인 코드"
        VARCHAR external_id UK "프로모션 UUID"
        VARCHAR promotion_type "프로모션 구분 (VOUCHER/POINT)"
        VARCHAR promotion_status "프로모션 상태"
        INT total_count "전체 대상 건수"
        DECIMAL total_amount "전체 금액"
        INT partition_count "파티션 수"
        DATETIME reservation_at "예약 일시"
        INT reservation_priority "예약 우선순위"
        VARCHAR default_reason "공통 지급 사유"
        DECIMAL default_amount "공통 지급 금액"
        DATETIME default_expiry_at "공통 지급 만료 일시"
        VARCHAR created_by "생성자"
        DATETIME created_at "생성 일시"
        VARCHAR updated_by "수정자"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_summary {
        BIGINT promotion_summary_id PK "프로모션 통계 ID"
        BIGINT promotion_id FK "프로모션 ID"
        INT published_count "발행 건수"
        INT success_count "성공 건수"
        INT fail_count "실패 건수"
        INT retry_success_count "재시도 성공 건수"
        DATETIME started_at "시작 일시"
        DATETIME completed_at "완료 일시"
        DATETIME stopped_at "중지 일시"
        VARCHAR stopped_memo "중지 사유 메모"
        VARCHAR created_by "생성자"
        DATETIME created_at "생성 일시"
        VARCHAR updated_by "수정자"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_voucher_targets {
        BIGINT voucher_target_id PK "바우처 대상 ID"
        BIGINT promotion_id FK "프로모션 ID"
        BIGINT customer_uid "고객 ID"
        VARCHAR voucher_number "상품권 번호"
        VARCHAR merchant_code "상점 코드"
        VARCHAR merchant_brand_code "상점 브랜드 코드"
        DECIMAL amount "지급 금액"
        VARCHAR expired_at "지급 유효 일자(yyyy-MM-dd)"
        VARCHAR reason "지급 사유"
        TINYINT is_withdrawal "인출 가능 여부"
        INT partition_key "파티션 KEY"
        VARCHAR publish_status "발행 상태"
        DATETIME created_at "생성 일시"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_voucher_results {
        BIGINT voucher_target_id PK "바우처 대상 ID (FK)"
        BIGINT promotion_id FK "프로모션 ID"
        VARCHAR process_status "처리 상태"
        VARCHAR transaction_key "거래 트랜잭션 KEY"
        VARCHAR error_message "실패 사유"
        DATETIME created_at "생성 일시"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_point_targets {
        BIGINT point_target_id PK "포인트 대상 ID"
        BIGINT promotion_id FK "프로모션 ID"
        BIGINT customer_uid "고객 ID"
        VARCHAR merchant_code "상점 코드"
        VARCHAR merchant_brand_code "상점 브랜드 코드"
        DECIMAL amount "지급 금액"
        VARCHAR expired_at "지급 유효 일자(yyyy-MM-dd)"
        VARCHAR reason "지급 사유"
        INT partition_key "파티션 KEY"
        VARCHAR publish_status "발행 상태"
        DATETIME created_at "생성 일시"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_point_results {
        BIGINT point_target_id PK "포인트 대상 ID (FK)"
        BIGINT promotion_id FK "프로모션 ID"
        VARCHAR process_status "처리 상태"
        VARCHAR transaction_key "거래 트랜잭션 KEY"
        VARCHAR error_message "실패 사유"
        DATETIME created_at "생성 일시"
        DATETIME updated_at "수정 일시"
    }

    campaign_promotion_summary_cache["campaign_promotion_summary_cache (Redis Hash)"] {
        STRING key PK "campaign_promotion_summary:{promotion_summary_id}"
        INT total_count "전체 대상 건수"
        INT published_count "발행 건수"
        INT success_count "성공 건수"
        INT fail_count "실패 건수"
        INT retry_success_count "재시도 성공 건수"
        STRING last_completed_at "마지막 완료 일시"
    }

    campaign_promotions ||--o| campaign_promotion_summary : "has"
    campaign_promotions ||--o{ campaign_promotion_voucher_targets : "has"
    campaign_promotions ||--o{ campaign_promotion_point_targets : "has"
    campaign_promotion_voucher_targets ||--o| campaign_promotion_voucher_results : "has"
    campaign_promotion_point_targets ||--o| campaign_promotion_point_results : "has"
    campaign_promotions ||--o{ campaign_promotion_voucher_results : "has"
    campaign_promotions ||--o{ campaign_promotion_point_results : "has"
    campaign_promotion_summary ||--o| campaign_promotion_summary_cache : "cached by"
```

## 테이블 관계 설명

| 관계                                                                          | 설명                      |
|-----------------------------------------------------------------------------|-------------------------|
| `campaign_promotions` → `campaign_promotion_summary`                        | 1:1 관계. 프로모션별 처리 현황 집계  |
| `campaign_promotions` → `campaign_promotion_voucher_targets`                | 1:N 관계. 바우처 프로모션 대상자 목록 |
| `campaign_promotions` → `campaign_promotion_point_targets`                  | 1:N 관계. 포인트 프로모션 대상자 목록 |
| `campaign_promotion_voucher_targets` → `campaign_promotion_voucher_results` | 1:1 관계. 바우처 지급 처리 결과    |
| `campaign_promotion_point_targets` → `campaign_promotion_point_results`     | 1:1 관계. 포인트 지급 처리 결과    |

## 상태 코드 정의

### promotion_status (프로모션 상태)

| 코드            | 설명 |
|---------------|----|
| `READY`       | 대기 |
| `IN_PROGRESS` | 진행 |
| `COMPLETED`   | 완료 |
| `STOPPED`     | 중단 |
| `FAILED`      | 실패 |

### promotion_type (프로모션 구분)

| 코드        | 설명       |
|-----------|----------|
| `VOUCHER` | 바우처 프로모션 |
| `POINT`   | 포인트 프로모션 |

### publish_status (발행 상태)

| 코드          | 설명    |
|-------------|-------|
| `PENDING`   | 대기    |
| `PUBLISHED` | 발행 완료 |
| `FAILED`    | 실패    |

### process_status (처리 상태)

| 코드         | 설명  |
|------------|-----|
| `PENDING`  | 대기  |
| `SUCCESS`  | 성공  |
| `RETRYING` | 재시도 |
| `FAILED`   | 실패  |

### campaign_promotion_summary Cache 구조 (Redis Hash)

- Cache Key: `campaign_promotion_summary:{promotion_summary_id}`
- Type: **Hash**

| Field               | Type    | Description                |
|---------------------|---------|----------------------------|
| total_count         | Integer | 전체 대상 건수                   |
| published_count     | Integer | 발행 건수                      |
| success_count       | Integer | 성공 건수                      |
| fail_count          | Integer | 실패 건수                      |
| retry_success_count | Integer | 재시도 성공 건수                  |
| last_completed_at   | String  | 마지막 완료 일시 (yyyyMMddHHmmss) |

#### 사용 명령어

```bash
# 카운트 증가 (Atomic)
HINCRBY campaign_promotion_summary:{id} published_count 1
HINCRBY campaign_promotion_summary:{id} success_count 1

# 전체 조회
HGETALL campaign_promotion_summary:{id}

# 특정 필드 조회
HGET campaign_promotion_summary:{id} success_count

# TTL 설정
EXPIRE campaign_promotion_summary:{id} {seconds}
```