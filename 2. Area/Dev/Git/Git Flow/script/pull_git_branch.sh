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