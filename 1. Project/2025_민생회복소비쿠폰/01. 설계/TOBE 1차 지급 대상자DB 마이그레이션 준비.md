|       STATUS        |             STATUS_DETAIL             |   COUNT   |                   비고                   |
| :-----------------: | :-----------------------------------: | :-------: | :------------------------------------: |
|       INQUIRY       |                INQUIRY                |  152,831  | 조회 요청만? > 잘못된 주민 번호? or 정말 조회 한번 해본 듯? |
| INQUIRY_NONE_TARGET |       INQUIRY_ALREADY_COMPLETED       |  105,083  |                기신청 대상자                 |
| INQUIRY_NONE_TARGET |      INQUIRY_CUTOFF_IN_PROGRESS       |    12     |                컷오프 대상자                 |
| INQUIRY_NONE_TARGET |         INQUIRY_INACTIVE_USER         |    251    |       INACTIVE 회원 상태 온라인 신청 대상자        |
| INQUIRY_NONE_TARGET |        INQUIRY_NOT_FOUND_USER         |   3,244   |  CI 기준 회원 정보 없는 온라인 신청 대상자(CI 변경 회원)   |
| INQUIRY_NONE_TARGET |         INQUIRY_NOT_RGL_USER          |     7     |         RGL 등급 외 회원 온라인 신청 대상자         |
| INQUIRY_NONE_TARGET |       INQUIRY_TARGET_NOT_FOUND        |  106,897  |           행안부 대상자 없음 응답 대상자            |
|       FAILED        |         FAILED_COMPLETED_ETC          |    16     |            지급 실패<br>(기타 사유)            |
|       FAILED        |    FAILED_COMPLETED_INACTIVE_CARD     |    301    |     지급 실패<br>(대상자 카드 상태 INACTIVE)      |
|       FAILED        |    FAILED_COMPLETED_INACTIVE_USER     |     1     |     지급 실패<br>(대상자 회원 상태 INACTIVE)      |
|       FAILED        |  FAILED_REQUESTED_ALREADY_COMPLETED   |    191    |        지급 실패<br>(이미 지급 완료 대상자)         |
|       FAILED        |  FAILED_REQUESTED_ALREADY_USED_TOKEN  |    429    |      지급 실패<br>(이미 사용 중 카드 신청 대상자)      |
|       FAILED        |    FAILED_REQUESTED_INACTIVE_CARD     |   1,779   |    지급 실패<br>(카드 상태 INACTIVE 신청 대상자)    |
|       FAILED        |    FAILED_REQUESTED_INVALID_TOKEN     |    43     |       지급 실패<br>(카드 검증 실패 신청 대상자)       |
|       FAILED        |  FAILED_REQUESTED_INVALID_TOKEN_CVC   |    29     |      지급 실패<br>(CVC 검증 실패 신청 대상자)       |
|       FAILED        | FAILED_REQUESTED_NOT_MATCH_CARD_AREA  |     5     |         지급 실패<br>(*사유 확인 필요*)          |
|       FAILED        | FAILED_REQUESTED_NOT_MATCH_CARD_OWNER |   1,994   |   지급 실패<br>(카드 명의 회원 정보 불일치 신청 대상자)    |
|      SUSPENDED      |         SUSPENDED_BAD_CREDIT          |    61     |         행안부 사용 중지 요청<br>(신용불량)         |
|      SUSPENDED      |            SUSPENDED_DEAD             |     2     |          행안부 사용 중지 요청<br>(사망)          |
|      CONFIRMED      |           CONFIRMED_UPDATED           |     9     | 대상자 지급 확정<br>(지급 실패 대상자 확정 재시도 완료 상태)  |
|      CONFIRMED      |                HOLDING                |     2     |       대상자 지급 확정<br>(지급 완료 전 상태)        |
|      RETRIEVAL      |               RETRIEVAL               |    35     |               행안부 환수 요청                |
|      REPAYMENT      |               REPAYMENT               |  62,157   |                예외 지급 완료                |
|      REPAYMENT      |           REPAYMENT_INVERSE           |    416    |     예외 지급 완료<br>(예외 지급 지원금 회수 상태)      |
|      COMPLETED      |               COMPLETED               | 4,488,714 |                 지급 완료                  |
|      COMPLETED      |            COMPLETED_RETRY            |   5,228   |   지급 완료<br>(지급 실패 대상자 지급 재시도 완료 상태)    |
|      REQUESTED      |               REQUESTED               |   5,603   |             금일 지원금 신청 대상자              |