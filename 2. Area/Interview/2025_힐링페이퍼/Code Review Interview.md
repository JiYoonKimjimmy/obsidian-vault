#### 테스트 코드 작성 방식

- 단일 테스트 코드에서만 성공인 Assertion 방식
	- 문제 사항
		- 만약 DB 에 테스트 코드에서 저장한 데이터 외 데이터가 있는 경우 실패할 수 있음
		- 테스트 코드 간에 영향을 받지 않고, 외부 상황에서 영향을 받지 않도록 테스트 코드 작성 필요
	- 개선 사항
		- 각 테스트 코드 실행 전 `BeforeTest` 통해서 DB Cleansing 할 수 있는 코드 추가
		- 단일 테스트 코드에서만 확인할 수 있는 Assertion 방식으로 변경
			- `reservationRepository.findAll()` 전체 조회가 아닌 `reservationRepository.findBySlotId(slot.getId())` 변경하면, 해당 테스트 코드에서 생성된 `slotId` 데이터로 조회하여 검증 가능