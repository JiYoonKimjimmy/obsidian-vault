### Lock 처리에 대해서

- DB Lock vs. Distributed Lock
- 분산락이 정확히 필요한 이유
	- 단일 인스턴스가 아닌 멀티 인스턴스 환경에서 동일한 자원에 대한 **경쟁 조건(race condition)** 방지 가능
	- 동시에 DB Insert 가 필요한 비즈니스 로직에 대한 중복 거래 방지 가능
	- 여러 개의 트랜잭션을 하나의 트랜잭션으로 처리 가능
	- 작업이 여러 노드에 동시에 수행 필요한가?
	- 자원이 공유되고 경쟁 조건이 있는가?
	- 적합성이 반드시 보장되어야 하는가?
	- 종류 : Redis Lock(Redlock), Etcd(k8s 친화적), Zookepper(설정 복잡, 지연 발생 가능)
		- 단일 인스턴스인 경우, Local Cache 활용한 분산락 가능?
- DB 락의 한계점
	- DB 자체 트랜잭션으로 강력한 데이터 정합성을 보장하지만,
	- 단일 DB 인스턴스에 락이 걸리기 때문에 **부하 집중, 확장성 제한으로 Scale-out 취약**
	- 여러 자원에 동시 락 걸릴 경우 **Dead-Lock 교착 상태 가능**
	- 여러 요청으로 자원에 대한 락 경합 심할 경우, 처리량 감소로 인한 **성능 저하 발생**

----

### VAM to CS 트랜잭션 관리

#### CS 지연 발생 대한 Retry 재시도 로직

- 기존 : CS 지연 발생에도 입금 거래 응답 성공 처리 후 동일 `충전거래ID` 로 충전 거래 재요청
- 개선 : 동일 `충전거래ID` 로 요청하는 경우, 충전 거래 중복 처리 우려
	- CS 지연 충전 거래 건은 별도 비동기 처리(Message Publishing)으로 충전 거래 재시도 처리
	- CS 지연 장기화되는 경우, 알림 발송을 통해 회원에게 서비스 상황 안내

#### 충전거래ID 생성 로직

- 기존 : **`입금거래전문번호 + 오라클DB시퀀스`** 채번 로직을 분산락으로 동시성 제어
- 개선 : `입금거래전문번호` 만으로 거래 유일성 보장 가능하기 때문에 `오라클DB 시퀀스` 채번 로직 제거