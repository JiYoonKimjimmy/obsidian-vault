## 목차

- [1. SSH Key 생성](#1-ssh-key-생성)
- [2. SSH Config 설정](#2-ssh-config-설정)
- [3. tmux 설치 및 설정](#3-tmux-설치-및-설정)
- [4. iTerm2 SSH 프로필 자동 전환](#4-iterm2-ssh-프로필-자동-전환)
- [5. 원격 서버 Shell Integration](#5-원격-서버-shell-integration)
- [6. .zshrc SSH 관련 설정](#6-zshrc-ssh-관련-설정)
- [7. 설정 파일 경로 요약](#7-설정-파일-경로-요약)
- [8. SSH 명령어 치트시트](#8-ssh-명령어-치트시트)

---

## 1. SSH Key 생성

비밀번호 입력 없이 키 기반으로 서버에 로그인할 수 있다. ed25519 알고리즘은 RSA보다 짧고 안전하다.

### 키 생성

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "your-email@example.com" -f ~/.ssh/id_ed25519 -N ""
```

| 옵션 | 설명 |
|------|------|
| `-t ed25519` | 알고리즘 (RSA보다 짧고 안전) |
| `-C` | 키에 붙는 코멘트 (식별용) |
| `-f` | 저장 경로 |
| `-N ""` | 패스프레이즈 없이 생성 (필요 시 설정 가능) |

### 서버에 공개키 등록

```bash
ssh-copy-id user@서버주소
```

또는 수동으로 등록:

```bash
cat ~/.ssh/id_ed25519.pub | ssh user@서버주소 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

---

## 2. SSH Config 설정

`~/.ssh/config` 파일을 설정하면 매번 긴 옵션을 입력하지 않아도 된다.

### 전역 기본 설정

```
Host *
    # macOS Keychain에 키 자동 등록
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile ~/.ssh/id_ed25519

    # 연결 유지 (60초마다 ping, 3회 실패 시 끊김)
    ServerAliveInterval 60
    ServerAliveCountMax 3

    # 멀티플렉싱 — 같은 호스트에 재접속 시 즉시 연결
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
```

멀티플렉싱용 소켓 디렉토리를 생성하고 권한을 설정한다.

```bash
mkdir -p ~/.ssh/sockets
chmod 600 ~/.ssh/config
```

### 서버별 별칭 등록

`~/.ssh/config`에 서버를 등록하면 `ssh prod`처럼 짧은 별칭으로 접속할 수 있다.

```
Host prod
    HostName 10.0.1.100
    User deploy
    Port 22

Host staging
    HostName 10.0.2.100
    User deploy

Host dev
    HostName 192.168.1.50
    User jiyoon
```

### 주요 옵션 설명

| 옵션 | 설명 |
|------|------|
| `Host` | 별칭 이름 (`ssh 별칭`으로 접속) |
| `HostName` | 실제 서버 IP 또는 도메인 |
| `User` | 접속 사용자명 |
| `Port` | SSH 포트 (기본값: 22) |
| `IdentityFile` | 사용할 개인키 경로 |
| `AddKeysToAgent yes` | SSH 키를 ssh-agent에 자동 등록 |
| `UseKeychain yes` | macOS 키체인에 패스프레이즈 저장 |
| `ServerAliveInterval 60` | 60초마다 keep-alive 패킷 전송 (연결 끊김 방지) |
| `ServerAliveCountMax 3` | 3회 응답 없으면 연결 종료 |
| `ControlMaster auto` | SSH 멀티플렉싱 활성화 |
| `ControlPath` | 멀티플렉싱 소켓 파일 경로 |
| `ControlPersist 600` | 접속 종료 후 600초간 소켓 유지 (재접속 시 즉시 연결) |

### 멀티플렉싱이란?

처음 SSH 접속 시 소켓 파일이 생성되고, 이후 같은 호스트에 접속하면 기존 소켓을 재사용한다. TCP 핸드셰이크와 인증 과정이 생략되어 즉시 연결된다.

```bash
# 첫 번째 접속 — 일반 속도
ssh prod

# 두 번째 접속 (다른 탭) — 즉시 연결
ssh prod

# 소켓 상태 확인
ssh -O check prod

# 소켓 강제 종료
ssh -O exit prod
```

---

## 3. tmux 설치 및 설정

SSH 세션에서 tmux를 사용하면 연결이 끊겨도 작업이 유지된다.

### 설치

```bash
brew install tmux
```

### 설정 파일 (`~/.tmux.conf`)

```bash
# ── Prefix 키 변경 (Ctrl+a 가 더 편함) ──
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# ── 마우스 지원 ──
set -g mouse on

# ── 256 컬러 + True Color ──
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# ── 패널 분할을 직관적 키로 ──
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# ── 패널 이동 (vim 스타일) ──
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# ── 새 윈도우/패널은 현재 경로 유지 ──
bind c new-window -c "#{pane_current_path}"

# ── 인덱스 1부터 시작 ──
set -g base-index 1
setw -g pane-base-index 1

# ── 상태바 스타일 (Catppuccin 색상) ──
set -g status-style "bg=#1e1e2e,fg=#cdd6f4"
set -g status-left "#[fg=#89b4fa,bold] #S "
set -g status-right "#[fg=#a6adc8] %H:%M  %m/%d "

# ── ESC 지연 제거 (vim 사용자용) ──
set -sg escape-time 0

# ── 히스토리 버퍼 크기 ──
set -g history-limit 50000
```

### tmux 주요 단축키 (Prefix: `Ctrl+A`)

| 키 | 동작 |
|----|------|
| `Ctrl+A` `\|` | 세로 분할 |
| `Ctrl+A` `-` | 가로 분할 |
| `Ctrl+A` `h/j/k/l` | 패널 이동 (vim 스타일) |
| `Ctrl+A` `c` | 새 윈도우 |
| `Ctrl+A` `n` / `p` | 다음 / 이전 윈도우 |
| `Ctrl+A` `d` | 세션 분리 (detach) |
| `Ctrl+A` `[` | 스크롤 모드 진입 (q로 종료) |

### iTerm2 tmux 통합 모드

iTerm2는 tmux `-CC` 모드를 지원하여 tmux 윈도우를 네이티브 iTerm2 탭으로 사용할 수 있다.

```bash
# 원격 서버에서 tmux 통합 모드 시작
ssh -t myserver "tmux -CC new-session -A -s main"
```

---

## 4. iTerm2 SSH 프로필 자동 전환

SSH 접속 시 호스트명에 따라 iTerm2 배경색과 뱃지가 자동으로 변경된다. Production 서버에서 실수로 위험한 명령을 실행하는 것을 방지할 수 있다.

### Dynamic Profile 설정

`~/Library/Application Support/iTerm2/DynamicProfiles/ssh-profiles.json` 파일을 생성한다.

```json
{
  "Profiles": [
    {
      "Name": "SSH-Production",
      "Guid": "ssh-production-profile-001",
      "Dynamic Profile Parent Name": "Default",
      "Badge Text": "PROD",
      "Background Color": {
        "Red Component": 0.15,
        "Green Component": 0.05,
        "Blue Component": 0.05,
        "Alpha Component": 1
      },
      "Tags": ["SSH", "Production"]
    },
    {
      "Name": "SSH-Staging",
      "Guid": "ssh-staging-profile-001",
      "Dynamic Profile Parent Name": "Default",
      "Badge Text": "STG",
      "Background Color": {
        "Red Component": 0.15,
        "Green Component": 0.12,
        "Blue Component": 0.02,
        "Alpha Component": 1
      },
      "Tags": ["SSH", "Staging"]
    },
    {
      "Name": "SSH-Dev",
      "Guid": "ssh-dev-profile-001",
      "Dynamic Profile Parent Name": "Default",
      "Badge Text": "DEV",
      "Background Color": {
        "Red Component": 0.05,
        "Green Component": 0.10,
        "Blue Component": 0.15,
        "Alpha Component": 1
      },
      "Tags": ["SSH", "Dev"]
    }
  ]
}
```

### 자동 전환 함수 (.zshrc)

`~/.zshrc`에 아래 함수를 추가한다. 호스트명 패턴에 따라 프로필이 자동 전환되고, 접속 종료 후 기본 프로필로 복귀한다.

```bash
ssh() {
  local profile="Default"
  case "$*" in
    *prod*|*production*) profile="SSH-Production" ;;
    *stg*|*staging*)     profile="SSH-Staging" ;;
    *dev*)               profile="SSH-Dev" ;;
  esac

  if [[ "$profile" != "Default" ]]; then
    echo -e "\033]1337;SetProfile=$profile\a"
  fi
  command ssh "$@"
  echo -e "\033]1337;SetProfile=Default\a"
}
```

### 프로필별 시각적 구분

| 호스트 패턴 | 프로필 | 배경색 | 뱃지 |
|-------------|--------|--------|------|
| `*prod*`, `*production*` | SSH-Production | 어두운 빨강 | PROD |
| `*stg*`, `*staging*` | SSH-Staging | 어두운 노랑 | STG |
| `*dev*` | SSH-Dev | 어두운 파랑 | DEV |

> 새로운 환경을 추가하려면 JSON 파일에 프로필을 추가하고, `ssh()` 함수의 `case` 패턴에 매칭 규칙을 추가한다.

---

## 5. 원격 서버 Shell Integration

원격 서버에도 iTerm2 Shell Integration을 설치하면 파일 업로드/다운로드 등 iTerm2 고유 기능을 사용할 수 있다.

### 원격 서버에서 설치

```bash
curl -fsSL https://iterm2.com/shell_integration/install_shell_integration.sh | bash
```

### 사용 가능한 기능

- 이전 명령어의 시작 위치로 점프 (`Cmd+Shift+Up/Down`)
- 명령어 실행 결과만 선택 복사
- 파일 드래그 앤 드롭으로 원격 서버에 업로드
- `imgcat` 명령으로 터미널에서 이미지 표시

---

## 6. .zshrc SSH 관련 설정

`~/.zshrc`에 추가할 SSH 관련 설정 전체.

```bash
# ── SSH + iTerm2 프로필 자동 전환 ──
ssh() {
  local profile="Default"
  case "$*" in
    *prod*|*production*) profile="SSH-Production" ;;
    *stg*|*staging*)     profile="SSH-Staging" ;;
    *dev*)               profile="SSH-Dev" ;;
  esac

  if [[ "$profile" != "Default" ]]; then
    echo -e "\033]1337;SetProfile=$profile\a"
  fi
  command ssh "$@"
  echo -e "\033]1337;SetProfile=Default\a"
}

# ── SSH + tmux 자동 접속 함수 ──
# 사용법: ssht myserver (원격 서버에서 tmux 세션 자동 생성/재접속)
ssht() {
  command ssh -t "$@" "tmux new-session -A -s main"
}
```

---

## 7. 설정 파일 경로 요약

| 파일 | 경로 | 설명 |
|------|------|------|
| SSH 설정 | `~/.ssh/config` | SSH 별칭, 멀티플렉싱, Keep-Alive |
| SSH 개인키 | `~/.ssh/id_ed25519` | ed25519 개인키 |
| SSH 공개키 | `~/.ssh/id_ed25519.pub` | 서버에 등록할 공개키 |
| SSH 소켓 | `~/.ssh/sockets/` | 멀티플렉싱 소켓 파일 |
| tmux 설정 | `~/.tmux.conf` | tmux 단축키, 스타일 등 |
| iTerm2 프로필 | `~/Library/Application Support/iTerm2/DynamicProfiles/ssh-profiles.json` | SSH 자동 전환 프로필 |

---

## 8. SSH 명령어 치트시트

### 기본 접속

```bash
ssh myserver              # SSH Config 별칭으로 접속
ssht myserver             # SSH + tmux 자동 세션 (끊겨도 작업 유지)
ssh-copy-id user@서버      # 서버에 공개키 등록
```

### 멀티플렉싱 관리

```bash
ssh -O check myserver     # 소켓 상태 확인
ssh -O exit myserver      # 소켓 강제 종료
```

### tmux (Prefix: Ctrl+A)

```bash
tmux                      # 새 세션 시작
tmux ls                   # 세션 목록
tmux attach -t main       # 세션 재접속
tmux kill-session -t main # 세션 삭제
```

| 키 | 동작 |
|----|------|
| `Ctrl+A` `\|` | 세로 분할 |
| `Ctrl+A` `-` | 가로 분할 |
| `Ctrl+A` `h/j/k/l` | 패널 이동 |
| `Ctrl+A` `c` | 새 윈도우 |
| `Ctrl+A` `n` / `p` | 다음 / 이전 윈도우 |
| `Ctrl+A` `d` | 세션 분리 (detach) |
| `Ctrl+A` `[` | 스크롤 모드 |

### 파일 전송

```bash
# 로컬 → 원격
scp 파일명 myserver:/path/to/dest

# 원격 → 로컬
scp myserver:/path/to/file ./

# 디렉토리 전송
scp -r 디렉토리명 myserver:/path/to/dest
```
