
## HTTP 요청 건수 카운트 모니터링 Script

- 리눅스 `Rocky Linux` 환경에서 로그 파일에서의 문자열 카운팅을 통한 `HTTP` 요청 건수 모니터링
- 애플리케이션 로그 파일에서 `-REQ` 문자열을 포함한 로그의 건수를 카운트하여 실시간 로그 출력

#### 로그 출력 예시  

```bash
2025-07-10 11:35:57.863.XNIO-1 task-1> INFO  T[250710113557-1afe5a8] U[] M[] - [CLIENT-REQ] POST /cdis/admin/inquiry/user

2025-07-10 11:35:57.876.XNIO-1 task-1> INFO  T[250710113557-1afe5a8] U[] M[] - [CLIENT-RES] POST /cdis/admin/inquiry/user 200 13ms
```

#### 분당/초당 카운트 모니터링 결과 출력 예시

```bash
# 분당 카운트 모니터링 결과 출력 예시
18:43 1234

# 초당 카운트 모니터링 결과 출력 예시
18:43:00 4
18:43:01 30
18:43:02 200
18:43:03 1000
```

---
### Request/Minutes Count Script
##### `min-monitor.sh`
```bash
#!/bin/bash

LOG_FILE=~/log/cdisa.log

tail -Fn0 "$LOG_FILE" | \
awk '
  function print_count(min, overwrite) {
    if (overwrite)
      printf "\r%s %d", min, count[min];
    else
      printf "\n%s %d", min, 1;
    fflush();
  }
  /-REQ/ {
    split($2, t, ":");
    min = t[1] ":" t[2];
    if (last_min != min) {
      print_count(min, 0); # 새 분 시작: 줄바꿈
      last_min = min;
    } else {
      print_count(min, 1); # 같은 분: 덮어쓰기
    }
    count[min]++;
  }
  END { print "" }
'
```

### Request/Seconds Count Script
##### `sec-monitor.sh`
```bash
#!/bin/bash

LOG_FILE=~/log/cdisa.log

tail -Fn0 "$LOG_FILE" | \
awk '
  function print_count(sec, overwrite) {
    if (overwrite)
      printf "\r%s %d", sec, count[sec];
    else
      printf "\n%s %d", sec, 1;
    fflush();
  }
  /-REQ/ {
    split($2, t, ".");
    split(t[1], s, ":");
    sec = s[1] ":" s[2] ":" s[3];
    if (last_sec != sec) {
      print_count(sec, 0); # 새 초 시작: 줄바꿈
      last_sec = sec;
    } else {
      print_count(sec, 1); # 같은 초: 덮어쓰기
    }
    count[sec]++;
  }
  END { print "" }
'
```

---
### Request/Minutes Stats Command

##### `min-stats.sh`
```bash
#!/bin/bash

if [ -n "$1" ]; then
  FILES=(~/log/*"$1"*)
  if [ -e "${FILES[0]}" ]; then
    LOG_FILE_LIST="${FILES[@]}"
  else
    LOG_FILE_LIST=~/log/cdisa.log
  fi
else
  LOG_FILE_LIST=~/log/cdisa.log
fi

grep "\-RES" $LOG_FILE_LIST | awk -F' ' '{print $1, substr($2, 1, 5)}' | sort | uniq -c | awk '{count[$3]+=$1} END {for (key in count) print key "\t" count[key]}' | sort
```

### Request/Seconds Stats Command

##### `sec-stats.sh`
```bash
#!/bin/bash

if [ -n "$1" ]; then
  FILES=(~/log/*"$1"*)
  if [ -e "${FILES[0]}" ]; then
    LOG_FILE_LIST="${FILES[@]}"
  else
    LOG_FILE_LIST=~/log/cdisa.log
  fi
else
  LOG_FILE_LIST=~/log/cdisa.log
fi

grep "\-RES" $LOG_FILE_LIST | awk '{print $1, substr($2, 1, 8)}' | sort | uniq -c | awk '{count[$3]+=$1} END {for (key in count) print key "\t" count[key]}' | sort
```
