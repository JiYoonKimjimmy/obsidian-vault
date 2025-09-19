## 에러 상황
- 서비스 운영 중인 Spring Boot 기반 애플리케이션에서 **Spring Actuator** 라이브러리의 `Shutdown` 처리 중 클래스 로더 시, **메타스페이스 메모리 부족으로 인한 클래스 로더 실패 에러 발생**

```log
2025-09-19 10:36:10.108.XNIO-1 task-2> INFO  T[250919103610-8f18241] U[] M[] - [CLIENT-REQ] POST /cdis/monitoring/shutdown
2025-09-19 10:36:10.113.XNIO-1 task-2> WARN  T[250919103610-8f18241] U[] M[] - 00_0400_000 Handler dispatch failed; nested exception is java.lang.NoClassDefFoundError: org/springframework/data/web/ProjectedPayload
2025-09-19 10:36:10.114.XNIO-1 task-2> ERROR T[250919103610-8f18241] U[] M[] - org.springframework.web.util.NestedServletException: Handler dispatch failed; nested exception is java.lang.NoClassDefFoundError: org/springframework/data/web/ProjectedPayload
        at org.springframework.web.servlet.DispatcherServlet.doDispatch(DispatcherServlet.java:1082)
		....
Caused by: java.lang.NoClassDefFoundError: org/springframework/data/web/ProjectedPayload
        at org.springframework.data.web.ProjectingJackson2HttpMessageConverter.canRead(ProjectingJackson2HttpMessageConverter.java:131)
        at org.springframework.web.servlet.mvc.method.annotation.AbstractMessageConverterMethodArgumentResolver.readWithMessageConverters(AbstractMessageConverterMethodArgumentResolver.java:180)
        at org.springframework.web.servlet.mvc.method.annotation.RequestResponseBodyMethodProcessor.readWithMessageConverters(RequestResponseBodyMethodProcessor.java:160)
        at org.springframework.web.servlet.mvc.method.annotation.RequestResponseBodyMethodProcessor.resolveArgument(RequestResponseBodyMethodProcessor.java:133)
        at org.springframework.web.method.support.HandlerMethodArgumentResolverComposite.resolveArgument(HandlerMethodArgumentResolverComposite.java:122)
        at org.springframework.web.method.support.InvocableHandlerMethod.getMethodArgumentValues(InvocableHandlerMethod.java:179)
        at org.springframework.web.method.support.InvocableHandlerMethod.invokeForRequest(InvocableHandlerMethod.java:146)
        at org.springframework.web.servlet.mvc.method.annotation.ServletInvocableHandlerMethod.invokeAndHandle(ServletInvocableHandlerMethod.java:117)
        at org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerAdapter.invokeHandlerMethod(RequestMappingHandlerAdapter.java:895)
        at org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerAdapter.handleInternal(RequestMappingHandlerAdapter.java:808)
        at org.springframework.web.servlet.mvc.method.AbstractHandlerMethodAdapter.handle(AbstractHandlerMethodAdapter.java:87)
        at org.springframework.web.servlet.DispatcherServlet.doDispatch(DispatcherServlet.java:1067)
        ... 69 more
Caused by: java.lang.ClassNotFoundException: org.springframework.data.web.ProjectedPayload
        at java.net.URLClassLoader.findClass(URLClassLoader.java:381)
        at java.lang.ClassLoader.loadClass(ClassLoader.java:424)
        at org.springframework.boot.loader.LaunchedURLClassLoader.loadClass(LaunchedURLClassLoader.java:151)
        at java.lang.ClassLoader.loadClass(ClassLoader.java:357)
        ... 81 more
```

---

## 분석

### 에러 발생 가능 시나리오
- JVM 프로세스 내 메타스페이스 부족으로 클래스 로딩 실패
- JVM 힙 메모리 부족으로 클래스로더 객체 GC 발생
- OutOfMemoryError 이후 클래스로더 상태 불안정
- Java `static` 초기화 실패로 인한 클래스 로딩 실패
	- `static` 클래스 중 한번 실패하면 이후, 모든 인스턴스 시도 실패

### 🎯 메타스페이스 부족 발생 원인
##### Spring Boot 환경의 클래스 폭증
```java
// 런타임에 계속 생성되는 클래스들
- Spring Data JPA 프록시: User$HibernateProxy$xxx
- Spring AOP 프록시: UserService$$EnhancerBySpringCGLIB$$xxx  
- RabbitMQ 리스너 프록시: MessageListener$$FastClass$$xxx
- Jackson 직렬화 클래스: JsonSerializer$xxx
- Validation 프록시: MethodValidationPostProcessor$xxx
```

##### 장시간 서비스 운영 중 누적
- HTTP 요청: 매 요청마다 새로운 프록시 클래스 생성 가능
- 데이터베이스 조회: 엔티티별 지연 로딩 프록시 생성
- 메시지 큐 처리: `RabbitMQ` 메시지 타입별 프록시 생성
- 스케줄링: `@Scheduled` 메서드의 프록시 클래스들
##### 메타스페이스 GC 한계
```shell
# 메타스페이스는 다음 조건에서만 GC됨
1. 해당 클래스로더가 GC됨
2. 클래스가 더 이상 참조되지 않음
3. Full GC 발생 시

# 하지만 Spring Boot에서는:
- 대부분 클래스가 ApplicationClassLoader에 의해 로드
- 애플리케이션 종료 전까지 클래스로더 GC 안됨
- 결과: 메타스페이스 계속 증가만 함
```

### 🎯 Static 초기화 실패 매커니즘

##### 1. XNIO Configurable 클래스의 초기화 문제
```log
java.lang.NoClassDefFoundError: Could not initialize class org.xnio.channels.Configurable
```

```java
// org.xnio.channels.Configurable 추정 코드
public interface Configurable<T> {
    static {
        // 여기서 다른 XNIO 클래스들을 초기화
        ChannelFactory.initialize();     // <- 메타스페이스 부족시 실패
        BufferAllocator.initialize();    // <- 연쇄 실패
        SelectorProvider.initialize();   // <- 연쇄 실패
    }
}
```

##### 2. 실패 시나리오
```text
1. Shutdown 요청 → Undertow 서버 종료 시도
2. XNIO 관련 클래스 로딩 필요 → Configurable 클래스 로드 시도  
3. 메타스페이스 가득참 → OutOfMemoryError: Metaspace
4. Static 초기화 실패 → 클래스 "초기화 실패" 상태로 마킹
5. **이후 접근 시마다 → NoClassDefFoundError 발생**
```

##### 3. JVM 내부 동작
```java
// JVM 내부적으로 이렇게 처리됨
class ClassState {
    LOADED,           // 클래스 로드됨
    INITIALIZING,     // Static 블록 실행 중
    INITIALIZED,      // 초기화 완료
    INITIALIZATION_ERROR  // 초기화 실패 (복구 불가)
}
```

### 📊 간헐적 발생 이유
#### 1. 임계점 타이밍
```shell
# 메타스페이스 사용량이 95% 이상일 때만 발생
Normal: 메타스페이스 80% → Shutdown 성공
Error:  메타스페이스 98% → Shutdown 실패
```

#### 2. 메모리 할당 경합
```java
// 동시에 여러 스레드가 클래스 로딩 시도
Thread-1: Jackson 직렬화 클래스 로딩 (메타스페이스 99%)
Thread-2: XNIO Configurable 로딩 시도 → OutOfMemoryError
```
#### 3. GC 타이밍
```shell
# 메타스페이스 GC 직전에 shutdown 요청
Before GC: 메타스페이스 95% → Shutdown 실패  
After GC:  메타스페이스 60% → Shutdown 성공
```

### 🛠️ 근본 해결책

#### 1. 메타스페이스 크기 증가
```shell
# 현재 기본값 (보통 20-21MB)
-XX:MetaspaceSize=128m      # 초기 크기
-XX:MaxMetaspaceSize=256m   # 최대 크기
```

#### 2. 클래스 로딩 최적화
```properties
# Spring Boot 설정
spring.jpa.open-in-view=false          # 불필요한 프록시 생성 방지
spring.aop.proxy-target-class=false    # JDK 프록시 사용 (CGLIB 대신)
```

#### 3. 모니터링 강화
```shell
# JVM 플래그 추가
-XX:+PrintGCDetails
-XX:+PrintMetaspaceGC  
-XX:MetaspaceSize=128m
-XX:MaxMetaspaceSize=256m
```

---

## 정리
- `Spring Boot + JPA + RabbitMQ` 환경에서 동적 프록시 클래스들이 **메타스페이스를 점진적으로 메모리 누적**
- 임계점에서 shutdown 시 필요한 **XNIO 클래스 로딩이 실패**하는 것이 근본 원인