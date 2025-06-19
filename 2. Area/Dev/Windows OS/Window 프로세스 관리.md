
## 프로세스 확인

```shell
# Port 기반 프로세스 확인
$ netstat -ano | findstr 6379

  TCP    127.0.0.1:6379         0.0.0.0:0              LISTENING       18176

# 프로세스 강제 Kill
$ taskkill /F /PID <PID>
```