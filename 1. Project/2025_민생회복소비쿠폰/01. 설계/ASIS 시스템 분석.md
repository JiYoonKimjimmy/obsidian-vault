
## 주요 도메인 분석

### `HouseHolder` 세대주 도메인

- 지원금 대상자(`HouseHolder`) 별 포인트 지급/사용 거래 관리 도메인
- `socialNumber` 주민등록번호 `PK` 선정하여 지원금 대상자 식별
- 기본 회원 식별 정보 관리
	- `name`, 
	- `mobileNumber`, 
	- `CI`
- 지역 및 기관 관련 정보 관리
	- `areaCode` : 지역코드 (5자리)
	- `areaCodeByPortal` : 포털에서 입력된 지역코드
	- `agencyCode` : 기관코드 (카드사, 은행, 지자체 등)
	- `agencyName` : 기관명
- 포인트 거래 관련 정보 관리
	- `amountIncome` : 소득(지급)금액
		- 정부에서 지급된 지원금 금액
	- `amountRecharged` : 충전 포인트
		- 질문: `amountRecharged` 는 언제 업데이트 되는가?
	- `amountRemain` : 잔여 포인트
	- `amountRetrieved`:  회수 포인트
- 상태 관리: [재난 지원금 상태 관리](https://konawiki.konai.com/pages/viewpage.action?pageId=195217721)
	- `status` : 상태 정보
		- `NONE` : 아무 상태 아님
		- `INQUIRY` : 조회
		- `INQUIRY_NONE_TARGET` : 확정 요청 불가 대상 (기신청 혹은 미대상)
		- `REQUESTED` : 확정 요청 성공
		- `CONFIRMED` : 배치로 최종 확정
		- `FAILED` : 실패
		- `COMPLETED` : 코나 지급 완료
		- `SUSPENDED` : 행안부가 사용 중지 요청
		- `RETRIEVAL` : 행안부가 포인트 회수 요청 완료
		- `REPAYMENT` : 재지급
		- `AREA_CHANGED` : 지역 변경
	- `statusDetail` : 상세 상태 정보
	- `statusHistory` : 상태 변경 이력
- 상태 변경 확장 함수 제공
	- `PostOnlineInquiryReqDto.updateDao()` : 온라인 조회 요청 데이터 매핑
		- `name`, `ci`, `aspId`, `mobileNumber` 업데이트 처리
	- `PostOfflineInquiryReqDto.updateDao()` : 오프라인 조회 요청 데이터 매핑
		- `name`, `aspId` 업데이트 처리
	- `PostIncomeRequestRespDto.updateDao()` : 소득 조회 응답 데이터 매핑
		- `trNo`, `requestTrNo`, `areaCode`, `amountIncome`, `agencyCode`, `memberCount` 업데이트 처리
		- `resCode` 전문 응답 코드에 따라 성공 처리 or 실패 예외 처리
	- `PointHistory.updateDao()` : 포인트 이력 데이터 매핑
	- ... 그 외 너무 많음 ...
- 상태 흐름
	1. `INQUIRY` → 조회 단계
		- 최초 `HouseHolder` 엔티티 생성시, `INQUIRY` 상태 저장
	2. `REQUESTED` → 신청 단계
	3. `CONFIRMED` → 확정 단계
	4. `COMPLETED` → 지급 완료
	5. `SUSPENDED` → 사용 중지
	6. `RETRIEVAL` → 포인트 회수
	7. `REPAYMENT` → 재지급
	- 상태 변경 요청 함수
		- `PostIncomeInquiryTargetRespDto.updateDao()`
		- `PostIncomeRequestRespDto.updateDao()`
		- `PostIncomeRequestRespDto.updateDaoAdmin()`

## 포인트 사용 Event 처리 프로세스 분석

- `KPS` 포인트 거래 Event Messgae 수신하여 지원금 거래인 경우, 거래 내역 저장
	-  [KPS-11.Point Transaction Fanout Exchange](https://konawiki.konai.com/display/KonaCardDevelopment/KPS-11.Point+Transaction+Fanout+Exchange)
	- `km.kps.fanout.transaction.cdis.queue` consume 하여 메시지 처리

```text
[PointHistory 입력]
        |
        v
[필터링: `trPar and par` 모두 없거나, `policySubType != "19"`이거나, `tranType == "68"/"05"`이면]
- `policySubType == 19 : 상생지원금` type
- `tranType == 68 : 캐시모으기 차감` 거래
- `tranType == 05 : 포인트 이관에 의한 소멸` 거래
        |
   (조건 만족 시)
        |--------------------> [return (아무 처리 안함)]
        |
   (조건 불만족 시)
        v
[특정 트랜잭션(`tranType == "65" & transactionId == "CDIS"`, `tranType == "64"`)면 1초 대기]
- `tranType == 65 : 어드민 벌크 적립` 거래
- `tranType == 64 : 경기도재난지원금 공무원 회수` 거래
        |
        v
[카드 거래 주체 par 결정]
- `trPar` : 카드교체 및 캐시이관시 지급 주체카드의 PAR
- `trPar ?: par ?: "000000000000000000000000000"`
        |
        v
[`par` 기준 `houseHolder 정보 조회]
        |
        v
[HouseHolder 존재?] --No--> [종료]
        |
       Yes
        v
[pointHistory.socialNumber = HouseHolder.socialNumber]
- `pointHistory` 에 `socialNumber` 정보 저장
        |
        v
[pointHistory.updateDao(HouseHolder)]
- `pointHistory` 정보 기준 `houseHolder` 정보 업데이트
        |
        v
[pointHistoryRepository.save(pointHistory)]
        |
        v
[trPar != par && trPar != null]
- 카드 교체 발급 거래인 경우, 카드 포인트 이동 관련 `actionHistory` 저장
- 카드 교체 주체 회원은 카드 N 개 보유 가능
        |                |
      No|                |Yes
        |                v
        |      [cardService.movePoint(...)]
        |                |
        +----------------+
        |
        v
[HouseHolderRepository.save(HouseHolder)]
        |
        v
[종료]
```
