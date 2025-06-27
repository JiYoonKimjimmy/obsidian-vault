
- Reconciliation : 내부 시스템 <> 외부 시스템 연동 트랜잭션에 대한 정확성 보장을 위한 거래 대사 과정
- Batch 시스템 거래 대사 처리
- Webhooks + 대사용 이벤트 저장 (event log-based)
	- 단, 웹훅은 네트워크/보안 오류로 인해 누락 가능하므로 **"요청-응답 로그 + 이벤트 수신 로그" 비교 필수**
- API 기반 실시간 상태 조회 + 대사 (fallback check)
- 3-way 대사 (internal-external-thirdparty)