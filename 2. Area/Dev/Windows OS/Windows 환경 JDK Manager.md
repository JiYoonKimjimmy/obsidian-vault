# Scoop을 활용한 Windows JDK 버전 관리 가이드

## 📌 Scoop이란?

Windows용 커맨드라인 패키지 매니저로, Linux의 `apt`, `brew`와 유사한 도구입니다.
- JDK를 포함한 다양한 개발 도구를 간편하게 설치/관리
- 여러 버전의 JDK를 동시에 설치하고 동적으로 전환 가능
- 사용자 디렉토리에 설치되어 관리자 권한 불필요

## 🚀 Scoop 설치

### 설치 확인
```bash
scoop --version
```

### 처음 설치하는 경우
```powershell
# PowerShell에서 실행
irm get.scoop.sh | iex
```

## ☕ JDK 설치 및 관리

### 1. Java 버킷 추가
```bash
scoop bucket add java
```

### 2. 사용 가능한 JDK 검색
```bash
# 모든 JDK 검색
scoop search jdk

# 특정 버전 검색
scoop search openjdk
scoop search temurin
scoop search corretto
```

### 3. JDK 설치
```bash
# OpenJDK 설치
scoop install openjdk17
scoop install openjdk21
scoop install openjdk11

# Amazon Corretto
scoop install corretto17
scoop install corretto21

# Eclipse Temurin
scoop install temurin17-jdk
scoop install temurin21-jdk

# Oracle JDK
scoop install oraclejdk
```

### 4. JDK 버전 전환
```bash
# 특정 버전으로 전환 (JAVA_HOME과 PATH 자동 업데이트)
scoop reset openjdk17
scoop reset openjdk21

# 현재 활성화된 버전 확인
java -version
echo $JAVA_HOME
```

### 5. 설치된 JDK 목록 확인
```bash
# 전체 설치된 패키지 확인
scoop list

# JDK만 확인
scoop list | grep -i jdk
```

### 6. JDK 업데이트
```bash
# 특정 JDK 업데이트
scoop update openjdk21

# 모든 패키지 업데이트
scoop update *
```

### 7. JDK 삭제
```bash
# 특정 버전 삭제
scoop uninstall openjdk17

# 완전히 제거 (캐시 포함)
scoop uninstall openjdk17 -p
```

## 📁 Scoop JDK 설치 경로

```
C:\Users\{사용자명}\scoop\apps\openjdk17\current\
C:\Users\{사용자명}\scoop\apps\openjdk21\current\
C:\Users\{사용자명}\scoop\apps\temurin17-jdk\current\
```

### 현재 시스템 경로
```
C:\Users\kimjy\scoop\apps\openjdk{버전}\current\
```

## 🔧 IntelliJ IDEA에서 Scoop JDK 사용하기

### 방법 1: SDK 수동 추가
1. `File` → `Project Structure` (Ctrl+Alt+Shift+S)
2. `Platform Settings` → `SDKs`
3. `+` 버튼 → `Add JDK`
4. 경로 선택: `C:\Users\kimjy\scoop\apps\openjdk17\current`
5. 확인 후 프로젝트에 적용

### 방법 2: 프로젝트별 JDK 설정
1. `File` → `Project Structure`
2. `Project Settings` → `Project`
3. `SDK` 드롭다운에서 추가한 Scoop JDK 선택

### 장점
- ✅ IntelliJ의 `.jdks` 디렉토리와 독립적으로 관리
- ✅ 명령줄과 IDE에서 동일한 JDK 사용 가능
- ✅ 프로젝트별로 다른 버전 지정 가능

## 💡 유용한 명령어

### 정보 확인
```bash
# 패키지 정보 확인
scoop info openjdk21

# 설치 경로 확인
scoop prefix openjdk21

# 도움말
scoop help
```

### 캐시 관리
```bash
# 캐시 확인
scoop cache show

# 캐시 삭제
scoop cache rm *
```

### 버킷 관리
```bash
# 추가된 버킷 확인
scoop bucket list

# 유용한 버킷들
scoop bucket add extras
scoop bucket add versions
scoop bucket add nerd-fonts
```

## 🎯 실전 사용 예시

### 시나리오 1: 프로젝트별 다른 JDK 사용
```bash
# 프로젝트 A (Java 17 필요)
cd projectA
scoop reset openjdk17
./gradlew build

# 프로젝트 B (Java 21 필요)
cd ../projectB
scoop reset openjdk21
./gradlew build
```

### 시나리오 2: 여러 JDK 테스트
```bash
# JDK 17로 테스트
scoop reset openjdk17
mvn clean test

# JDK 21로 테스트
scoop reset openjdk21
mvn clean test
```

## 🔍 기존 JDK와의 관계

### 현재 시스템 상태
- **기존 JDK**: `C:\java\jdk-21` (수동 설치)
- **IntelliJ JDK**: `C:\Users\kimjy\.jdks\`
- **Scoop JDK**: `C:\Users\kimjy\scoop\apps\`

### 충돌 방지
- Scoop JDK는 독립적인 경로에 설치됨
- `scoop reset` 명령으로 활성 JDK 전환 시 PATH 우선순위 자동 조정
- 기존 JDK는 영향받지 않고 그대로 유지됨

### 권장 사항
1. **Scoop으로 통합 관리**: 새로운 JDK는 Scoop으로 설치
2. **기존 JDK 유지**: 백업용으로 보관 (삭제하지 않아도 됨)
3. **IntelliJ 설정**: Scoop JDK 경로를 추가하여 사용

## ⚠️ 주의사항

1. **PATH 우선순위**
   - `scoop reset`을 하면 해당 JDK가 PATH 최상위로 이동
   - 기존 JDK보다 우선 실행됨

2. **JAVA_HOME 자동 설정**
   - Scoop이 자동으로 JAVA_HOME 업데이트
   - 수동으로 설정한 JAVA_HOME은 덮어씌워질 수 있음

3. **IDE 재시작**
   - JDK 전환 후 IDE에서 인식 안 될 경우 재시작 필요

## 🛠️ 트러블슈팅

### JDK가 인식되지 않을 때
```bash
# PATH 확인
echo $PATH

# Scoop 재설정
scoop reset openjdk21

# 터미널 재시작
```

### 버전 전환이 안 될 때
```bash
# 현재 활성 버전 확인
scoop list

# 강제 재설정
scoop uninstall openjdk21
scoop install openjdk21
scoop reset openjdk21
```

### IntelliJ에서 JDK를 찾을 수 없을 때
1. 경로 확인: `scoop prefix openjdk21`
2. IntelliJ에서 정확한 `current` 경로 지정
3. IDE 재시작

## 📚 추가 리소스

- [Scoop 공식 문서](https://scoop.sh)
- [Scoop GitHub](https://github.com/ScoopInstaller/Scoop)
- [Java 버킷](https://github.com/ScoopInstaller/Java)

## 📝 체크리스트

- [ ] Scoop 설치 완료
- [ ] Java 버킷 추가
- [ ] 필요한 JDK 버전 설치
- [ ] IntelliJ에 Scoop JDK 경로 추가
- [ ] 버전 전환 테스트

---

**마지막 업데이트**: 2025-11-19
**환경**: Windows 10/11, MINGW64
