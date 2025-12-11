
## `.bashrc` Alias 명령어 등록

```bash
# ~/.bashrc
alias start_git_feature='D:\\shell\\git_flow_feature.sh start'
alias finish_git_feature='D:\\shell\\git_flow_feature.sh finish'
alias merge_git_branch='D:\\shell\\merge_git_branch.sh'
alias push_git_branch='D:\\shell\\push_git_branch.sh'
alias pull_git_branch='D:\\shell\\pull_git_branch.sh'
```

## `git_flow_feature.sh`

```bash
#!/bin/bash

MODE=$1

if [ $MODE = "start" ]; then
    BRANCH=$2

    if [ -z $BRANCH ]; then
        BRANCH=`date +"%Y%m%d%H%M"`
    fi
    
    git flow feature start $BRANCH
elif [ $MODE = "finish" ]; then
    git flow feature finish --no-ff
fi
```

## `merge_git_branch.sh`

```bash
#!/bin/bash

# 병합 옵션 설정
merge_option=$1
echo

# 현재 체크아웃된 브랜치 이름 가져오기
current_branch=$(git rev-parse --abbrev-ref HEAD)

# 병합하려는 feature branch 명 입력 (기본값: 현재 브랜치)
while true; do
    feature_branch=$(read -p "Enter the feature branch name to merge [default: $current_branch]: " feature_branch)
    feature_branch=${feature_branch:-$current_branch}

    # feature branch 정확히 존재하는지 확인
    if git rev-parse --verify $feature_branch >/dev/null 2>&1; then
        break
    else
        echo "Branch '$feature_branch' does not exist. Please enter a valid branch name."
    fi
done

# 병합 대상이 되는 branch 명을 순서대로 입력
target_branches=()
index=1
while true; do
    read -p "Enter the target branch to merge [$index] (just 'Enter' to finish): " target_branch
    # 'done', 'DONE', 공백, 엔터 입력 시 종료
    if [[ -z "$target_branch" || "$target_branch" == "done" || "$target_branch" == "DONE" ]]; then
        break
    fi
    target_branches+=("$target_branch")
    index=$((index + 1))
done

# 병합하려는 feature branch 를 대상 branch 들에 순서대로 병합 실행
for target_branch in "${target_branches[@]}"
do
    echo
    # 병합 대상 branch 가 존재하는지 확인
    if git branch --list | grep -q "$target_branch"; then
        echo "Merge branch '$feature_branch' into '$target_branch' with option $merge_option"
        git checkout $target_branch
        git fetch origin $target_branch
        git pull origin $target_branch
        git merge $merge_option $feature_branch
    else
        echo "Branch '$target_branch' does not exist. Skipping..."
    fi
done

# feature branch 돌아가기
git checkout $feature_branch > /dev/null 2>&1
```

## `push_git_branch.sh`

```bash
#!/bin/bash

echo

target_branches=()

# 현재 체크아웃된 브랜치 이름 가져오기
current_branch=$(git rev-parse --abbrev-ref HEAD)

# Push 대상 branch 명 입력 (기본값: 현재 브랜치)
read -p "Enter the target branch to push [1] [default: $current_branch]: " target_branch
target_branches+=("${target_branch:-$current_branch}")

index=2
# Push 대상이 되는 branch 명을 순서대로 입력
while true; do
    read -p "Enter the target branch to push [$index] (just 'Enter' to finish): " target_branch
    # 'done', 'DONE', 공백, 엔터 입력 시 종료
    if [[ -z "$target_branch" || "$target_branch" == "done" || "$target_branch" == "DONE" ]]; then
        break
    fi
    target_branches+=("$target_branch")
    index=$((index + 1))
done

echo

git push origin "${target_branches[@]}"
```

## `pull_git_branch.sh`

```bash
#!/bin/bash

echo

target_branches=()

# 현재 체크아웃된 브랜치 이름 가져오기
current_branch=$(git rev-parse --abbrev-ref HEAD)

# Push 대상 branch 명 입력 (기본값: 현재 브랜치)
read -p "Enter the target branch to pull [1] [default: $current_branch]: " target_branch
target_branches+=("${target_branch:-$current_branch}")

index=2
# Push 대상이 되는 branch 명을 순서대로 입력
while true; do
    read -p "Enter the target branch to pull [$index] (just 'Enter' to finish): " target_branch
    # 'done', 'DONE', 공백, 엔터 입력 시 종료
    if [[ -z "$target_branch" || "$target_branch" == "done" || "$target_branch" == "DONE" ]]; then
        break
    fi
    target_branches+=("$target_branch")
    index=$((index + 1))
done

echo

git fetch origin "${target_branches[@]}"
git pull origin "${target_branches[@]}"
```