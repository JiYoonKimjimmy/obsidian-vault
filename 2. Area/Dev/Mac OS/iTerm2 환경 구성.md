## 목차

- [1. 사전 준비](#1-사전-준비)
- [2. Shell 프레임워크 및 테마](#2-shell-프레임워크-및-테마)
- [3. Zsh 플러그인](#3-zsh-플러그인)
- [4. CLI 유틸리티](#4-cli-유틸리티)
- [5. iTerm2 컬러 테마](#5-iterm2-컬러-테마)
- [6. iTerm2 Shell Integration](#6-iterm2-shell-integration)
- [7. 설정 파일 경로 요약](#7-설정-파일-경로-요약)
- [8. 주요 명령어 치트시트](#8-주요-명령어-치트시트)

---

## 1. 사전 준비

### Homebrew 설치

macOS 패키지 관리자. 이후 모든 도구 설치의 기반이 된다.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

설치 후 셸에서 인식할 수 있도록 PATH를 등록한다.

```bash
# Apple Silicon (M1/M2/M3/M4)
eval "$(/opt/homebrew/bin/brew shellenv)"

# Intel Mac
eval "$(/usr/local/bin/brew shellenv)"
```

> `~/.zshrc`에 위 줄을 추가해야 새 셸에서도 `brew` 명령이 동작한다.

---

## 2. Shell 프레임워크 및 테마

### 2.1 Oh My Zsh

Zsh 설정 프레임워크. 플러그인과 테마를 편리하게 관리할 수 있다.

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

설치 후 `~/.zshrc`가 자동 생성된다. 기존 `.zshrc`는 `.zshrc.pre-oh-my-zsh`로 백업된다.

### 2.2 Nerd Font (MesloLGS NF)

Powerlevel10k에서 아이콘을 표시하기 위한 전용 폰트.

```bash
brew install --cask font-meslo-lg-nerd-font
```

설치 후 iTerm2에서 폰트를 변경해야 한다.

> **iTerm2** > **Settings** > **Profiles** > **Text** > **Font** > `MesloLGS Nerd Font` 선택

### 2.3 Powerlevel10k

Git 상태, 디렉토리, 실행 시간 등을 프롬프트에 시각적으로 표시하는 Zsh 테마.

```bash
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k
```

`~/.zshrc`에서 테마를 변경한다.

```bash
ZSH_THEME="powerlevel10k/powerlevel10k"
```

새 터미널을 열면 `p10k configure` 마법사가 자동 실행된다. 이후 재설정이 필요하면 아래 명령을 사용한다.

```bash
p10k configure
```

---

## 3. Zsh 플러그인

### 3.1 zsh-autosuggestions

이전 명령어 히스토리 기반으로 자동완성을 제안한다. 회색 텍스트로 표시되며 `→` 키로 수락.

```bash
git clone https://github.com/zsh-users/zsh-autosuggestions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

### 3.2 zsh-syntax-highlighting

명령어 입력 시 실시간 구문 강조. 유효한 명령은 초록색, 잘못된 명령은 빨간색으로 표시.

```bash
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
```

### 3.3 zsh-completions

추가 Tab 자동완성 정의 모음.

```bash
git clone https://github.com/zsh-users/zsh-completions \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-completions
```

### 플러그인 활성화

`~/.zshrc`의 `plugins` 항목을 아래와 같이 수정한다.

```bash
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
)
```

---

## 4. CLI 유틸리티

4개의 도구를 한번에 설치한다.

```bash
brew install fzf zoxide eza bat
```

| 도구 | 설명 | 대체 대상 |
|------|------|-----------|
| **fzf** | 퍼지 파인더 - 파일, 히스토리, 프로세스를 빠르게 검색 | `Ctrl+R` 강화 |
| **zoxide** | 자주 가는 디렉토리를 학습해서 `z` 명령으로 빠르게 이동 | `cd` |
| **eza** | 아이콘, 색상, Git 상태를 포함한 파일 목록 표시 | `ls` |
| **bat** | 구문 강조가 적용된 파일 출력 | `cat` |

### .zshrc에 추가할 설정

```bash
# ── fzf shell integration ──
source <(fzf --zsh)

# ── zoxide (smarter cd) ──
eval "$(zoxide init zsh)"

# ── Aliases ──
alias ls="eza --icons --group-directories-first"
alias ll="eza --icons --group-directories-first -la"
alias lt="eza --icons --group-directories-first --tree --level=2"
alias cat="bat --paging=never"
```

---

## 5. iTerm2 컬러 테마

### Catppuccin Mocha

눈 피로를 줄이고 가독성을 높이는 인기 컬러 스킴.

```bash
curl -fsSL -o /tmp/catppuccin_mocha.itermcolors \
  https://raw.githubusercontent.com/catppuccin/iterm/main/colors/catppuccin-mocha.itermcolors

open /tmp/catppuccin_mocha.itermcolors
```

`open` 명령을 실행하면 iTerm2에 컬러 프리셋이 자동으로 임포트된다. 이후 수동으로 적용해야 한다.

> **iTerm2** > **Settings** > **Profiles** > **Colors** > **Color Presets** > `catppuccin-mocha` 선택

---

## 6. iTerm2 Shell Integration

iTerm2 전용 기능(파일 다운로드, 명령어 네비게이션 등)을 활성화한다.

### 설치

```bash
curl -fsSL https://iterm2.com/shell_integration/install_shell_integration.sh | bash
```

설치 후 `~/.zshrc`에 아래 줄이 자동 추가된다.

```bash
test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh" || true
```

### Shell Integration으로 사용 가능한 기능

- 이전 명령어의 시작 위치로 점프 (`Cmd+Shift+Up/Down`)
- 명령어 실행 결과만 선택 복사
- 파일 드래그 앤 드롭으로 원격 서버에 업로드
- `imgcat` 명령으로 터미널에서 이미지 표시

---

## 7. 설정 파일 경로 요약

| 파일 | 경로 | 설명 |
|------|------|------|
| Zsh 설정 | `~/.zshrc` | 셸 설정, 플러그인, Alias 등 |
| Zsh 설정 백업 | `~/.zshrc.pre-oh-my-zsh` | Oh My Zsh 설치 전 원본 .zshrc |
| Oh My Zsh | `~/.oh-my-zsh/` | Oh My Zsh 프레임워크 |
| Powerlevel10k 테마 | `~/.oh-my-zsh/custom/themes/powerlevel10k/` | Zsh 테마 |
| Powerlevel10k 설정 | `~/.p10k.zsh` | p10k configure 결과 저장 |
| Zsh 커스텀 플러그인 | `~/.oh-my-zsh/custom/plugins/` | 수동 설치된 플러그인 |
| Shell Integration | `~/.iterm2_shell_integration.zsh` | iTerm2 셸 통합 스크립트 |

---

## 8. 주요 명령어 치트시트

### 파일 탐색

```bash
ls                # 아이콘 포함 파일 목록
ll                # 상세 파일 목록 (퍼미션, 사이즈 등)
lt                # 2단계 트리 구조로 표시
cat 파일명         # 구문 강조된 파일 출력
```

### 디렉토리 이동

```bash
z 프로젝트명       # 자주 가는 폴더로 즉시 이동 (zoxide)
```

### 검색

```bash
Ctrl+R            # fzf 기반 명령어 히스토리 검색
Ctrl+T            # fzf 기반 파일 검색
Alt+C             # fzf 기반 디렉토리 이동
```
