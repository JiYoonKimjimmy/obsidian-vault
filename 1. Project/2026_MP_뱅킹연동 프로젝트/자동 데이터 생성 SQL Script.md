
```sql
-- ============================================================  
-- DataGrip용 캠페인 프로모션 테스트 데이터 생성 스크립트  
-- ============================================================  
--  
-- [사용법]  
--   1. DataGrip Console 상단에서 Statement separator를 '//' 로 변경  
--   2. 전체 스크립트 실행 또는 필요한 부분만 선택 실행  
--  
-- [테스트 시나리오별 권장 설정]  
--   - 기능 검증:     1,000건,   파티션 4개  
--   - 부하 테스트:   100,000건, 파티션 10개  
--   - 스트레스 테스트: 1,000,000건, 파티션 20개  
--  
-- ============================================================  
  
  
-- ------------------------------------------------------------  
-- 1. 기존 프로시저 삭제  
-- ------------------------------------------------------------  
DROP PROCEDURE IF EXISTS prepay_admin.generate_campaign_test_data;  
  
  
-- ------------------------------------------------------------  
-- 2. 테스트 데이터 생성 프로시저  
-- ------------------------------------------------------------  
CREATE PROCEDURE prepay_admin.generate_campaign_test_data(  
    IN p_promotion_type VARCHAR(20),    -- 'VOUCHER' or 'POINT'  
    IN p_target_count INT,              -- 대상자 수 (예: 100000)  
    IN p_partition_count INT            -- 파티션 수 (예: 10)  
)  
BEGIN  
    DECLARE v_promotion_id BIGINT;  
    DECLARE v_summary_id BIGINT;  
    DECLARE v_target_id BIGINT;  
    DECLARE v_campaign_code VARCHAR(100);  
    DECLARE v_external_id VARCHAR(40);  
    DECLARE v_now DATETIME DEFAULT NOW();  
    DECLARE i INT DEFAULT 0;  
  
    -- --------------------------------------------------------  
    -- 1. ID 채번  
    -- --------------------------------------------------------  
    SET v_campaign_code = CONCAT('TEST-', p_promotion_type, '-', DATE_FORMAT(v_now, '%Y%m%d%H%i%s'));  
    SET v_external_id = UUID();  
  
    SELECT IFNULL(MAX(promotion_id), 0) + 1  
      INTO v_promotion_id  
      FROM prepay_admin.campaign_promotions;  
  
    SELECT IFNULL(MAX(promotion_summary_id), 0) + 1  
      INTO v_summary_id  
      FROM prepay_admin.campaign_promotion_summary;  
  
    IF p_promotion_type = 'VOUCHER' THEN  
        SELECT IFNULL(MAX(voucher_target_id), 0)  
          INTO v_target_id  
          FROM prepay_admin.campaign_promotion_voucher_targets;  
    ELSE  
        SELECT IFNULL(MAX(point_target_id), 0)  
          INTO v_target_id  
          FROM prepay_admin.campaign_promotion_point_targets;  
    END IF;  
  
    -- --------------------------------------------------------  
    -- 2. campaign_promotions 생성  
    -- --------------------------------------------------------  
    INSERT INTO prepay_admin.campaign_promotions (  
        promotion_id,  
        campaign_code,  
        external_id,  
        promotion_type,  
        promotion_status,  
        total_count,  
        total_amount,  
        partition_count,  
        reservation_at,  
        reservation_priority,  
        default_reason,  
        default_amount,  
        default_expiry_at,  
        created_by,  
        created_at,  
        updated_by,  
        updated_at  
    ) VALUES (  
        v_promotion_id,  
        v_campaign_code,  
        v_external_id,  
        p_promotion_type,  
        'READY',  
        p_target_count,  
        p_target_count * 5000,  
        p_partition_count,  
        NULL,  
        NULL,  
        CONCAT('[TEST] ', p_promotion_type, ' 프로모션 - ', p_target_count, '건'),  
        5000.00,  
        DATE_ADD(v_now, INTERVAL 1 YEAR),  
        'test-admin',  
        v_now,  
        NULL,  
        NULL  
    );  
  
    -- --------------------------------------------------------  
    -- 3. campaign_promotion_summary 생성  
    -- --------------------------------------------------------  
    INSERT INTO prepay_admin.campaign_promotion_summary (  
        promotion_summary_id,  
        promotion_id,  
        published_count,  
        success_count,  
        fail_count,  
        retry_success_count,  
        started_at,  
        completed_at,  
        stopped_at,  
        stopped_memo,  
        created_by,  
        created_at,  
        updated_by,  
        updated_at  
    ) VALUES (  
        v_summary_id,  
        v_promotion_id,  
        0,  
        0,  
        0,  
        0,  
        NULL,  
        NULL,  
        NULL,  
        NULL,  
        'test-admin',  
        v_now,  
        NULL,  
        NULL  
    );  
  
    -- --------------------------------------------------------  
    -- 4. 대상자 테이블 대량 INSERT    -- --------------------------------------------------------    IF p_promotion_type = 'VOUCHER' THEN  
        -- 바우처 대상자 생성  
        SET i = 0;  
        WHILE i < p_target_count DO  
            INSERT INTO prepay_admin.campaign_promotion_voucher_targets (  
                voucher_target_id,  
                promotion_id,  
                customer_uid,  
                voucher_number,  
                merchant_code,  
                merchant_brand_code,  
                amount,  
                is_withdrawal,  
                valid_until,  
                reason,  
                partition_key,  
                publish_status,  
                created_at,  
                updated_at  
            ) VALUES (  
                v_target_id + i + 1,  
                v_promotion_id,  
                1000000 + (i MOD 500000),       -- customer_uid (50만명 순환)  
                CONCAT('VN-', v_promotion_id, '-', LPAD(i + 1, 10, '0')),  
                'MUSINSA',  
                'BRAND001',  
                5000.00,  
                0,  
                '2026-12-31',  
                CONCAT('[TEST] 바우처 지급 #', i + 1),  
                i MOD p_partition_count,        -- partition_key 균등 분산  
                'PENDING',  
                v_now,  
                v_now  
            );  
            SET i = i + 1;  
  
            -- 1000건마다 커밋 (메모리 관리)  
            IF i MOD 1000 = 0 THEN  
                COMMIT;  
            END IF;  
        END WHILE;  
  
    ELSE  
        -- 포인트 대상자 생성  
        SET i = 0;  
        WHILE i < p_target_count DO  
            INSERT INTO prepay_admin.campaign_promotion_point_targets (  
                point_target_id,  
                promotion_id,  
                customer_uid,  
                amount,  
                expired_at,  
                reason,  
                partition_key,  
                publish_status,  
                created_at,  
                updated_at  
            ) VALUES (  
                v_target_id + i + 1,  
                v_promotion_id,  
                1000000 + (i MOD 500000),       -- customer_uid (50만명 순환)  
                5000.00,  
                DATE_ADD(v_now, INTERVAL 1 YEAR),  
                CONCAT('[TEST] 포인트 지급 #', i + 1),  
                i MOD p_partition_count,        -- partition_key 균등 분산  
                'PENDING',  
                v_now,  
                v_now  
            );  
            SET i = i + 1;  
  
            -- 1000건마다 커밋 (메모리 관리)  
            IF i MOD 1000 = 0 THEN  
                COMMIT;  
            END IF;  
        END WHILE;  
    END IF;  
  
    COMMIT;  
  
    -- --------------------------------------------------------  
    -- 5. 결과 출력  
    -- --------------------------------------------------------  
    SELECT  
        v_promotion_id AS promotion_id,  
        v_campaign_code AS campaign_code,  
        p_promotion_type AS promotion_type,  
        p_target_count AS target_count,  
        p_partition_count AS partition_count,  
        'SUCCESS' AS result;  
  
END  
;  
  
-- ============================================================  
-- 3. 실행 예시 (필요한 것만 선택하여 실행)  
-- ============================================================  
  
-- [기능 검증] 바우처 1,000건  
CALL prepay_admin.generate_campaign_test_data('VOUCHER', 4, 4);  
  
-- [기능 검증] 포인트 1,000건  
-- CALL prepay_admin.generate_campaign_test_data('POINT', 1000, 4) //  
  
-- [부하 테스트] 바우처 10만건  
-- CALL prepay_admin.generate_campaign_test_data('VOUCHER', 100000, 10) //  
  
-- [부하 테스트] 포인트 10만건  
-- CALL prepay_admin.generate_campaign_test_data('POINT', 100000, 10) //  
  
-- [스트레스 테스트] 바우처 100만건  
-- CALL prepay_admin.generate_campaign_test_data('VOUCHER', 1000000, 20) //  
  
-- [스트레스 테스트] 포인트 100만건  
-- CALL prepay_admin.generate_campaign_test_data('POINT', 1000000, 20) //  
  
  
-- ============================================================  
-- 4. 테스트 데이터 확인 쿼리  
-- ============================================================  
  
-- 프로모션 목록 조회  
-- SELECT * FROM prepay_admin.campaign_promotions WHERE campaign_code LIKE 'TEST-%' ORDER BY created_at DESC //  
  
-- 프로모션별 대상자 수 확인  
-- SELECT  
--     cp.promotion_id,  
--     cp.campaign_code,  
--     cp.promotion_type,  
--     cp.total_count,  
--     cp.partition_count,  
--     CASE cp.promotion_type  
--         WHEN 'VOUCHER' THEN (SELECT COUNT(*) FROM prepay_admin.campaign_promotion_voucher_targets WHERE promotion_id = cp.promotion_id)  
--         WHEN 'POINT' THEN (SELECT COUNT(*) FROM prepay_admin.campaign_promotion_point_targets WHERE promotion_id = cp.promotion_id)  
--     END AS actual_count  
-- FROM prepay_admin.campaign_promotions cp  
-- WHERE cp.campaign_code LIKE 'TEST-%' //  
  
-- 파티션별 분포 확인 (포인트)  
-- SELECT partition_key, COUNT(*) as cnt  
-- FROM prepay_admin.campaign_promotion_point_targets  
-- WHERE promotion_id = ?  
-- GROUP BY partition_key  
-- ORDER BY partition_key //  
  
  
-- ============================================================  
-- 5. 테스트 데이터 삭제 (정리용)  
-- ============================================================  
  
-- 특정 프로모션 삭제 프로시저  
DROP PROCEDURE IF EXISTS prepay_admin.delete_campaign_test_data;  
  
CREATE PROCEDURE prepay_admin.delete_campaign_test_data(  
    IN p_promotion_id BIGINT  
)  
BEGIN  
    -- 결과 테이블 삭제  
    DELETE FROM prepay_admin.campaign_promotion_voucher_results WHERE promotion_id = p_promotion_id;  
    DELETE FROM prepay_admin.campaign_promotion_point_results WHERE promotion_id = p_promotion_id;  
  
    -- 대상자 테이블 삭제  
    DELETE FROM prepay_admin.campaign_promotion_voucher_targets WHERE promotion_id = p_promotion_id;  
    DELETE FROM prepay_admin.campaign_promotion_point_targets WHERE promotion_id = p_promotion_id;  
  
    -- Summary 삭제  
    DELETE FROM prepay_admin.campaign_promotion_summary WHERE promotion_id = p_promotion_id;  
  
    -- 프로모션 삭제  
    DELETE FROM prepay_admin.campaign_promotions WHERE promotion_id = p_promotion_id;  
  
    COMMIT;  
  
    SELECT p_promotion_id AS deleted_promotion_id, 'DELETED' AS result;  
END;  
  
-- 테스트 데이터 전체 삭제 (TEST- 로 시작하는 캠페인)  
DROP PROCEDURE IF EXISTS prepay_admin.delete_all_campaign_test_data //  
  
CREATE PROCEDURE prepay_admin.delete_all_campaign_test_data()  
BEGIN  
    DECLARE done INT DEFAULT FALSE;  
    DECLARE v_promotion_id BIGINT;  
    DECLARE cur CURSOR FOR  
        SELECT promotion_id FROM prepay_admin.campaign_promotions WHERE campaign_code LIKE 'TEST-%';  
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;  
  
    OPEN cur;  
  
    read_loop: LOOP  
        FETCH cur INTO v_promotion_id;  
        IF done THEN  
            LEAVE read_loop;  
        END IF;  
        CALL prepay_admin.delete_campaign_test_data(v_promotion_id);  
    END LOOP;  
  
    CLOSE cur;  
  
    SELECT 'ALL TEST DATA DELETED' AS result;  
END  
;  
  
-- 실행 예시  
CALL prepay_admin.delete_campaign_test_data(1);  
-- CALL prepay_admin.delete_all_campaign_test_data() //
```