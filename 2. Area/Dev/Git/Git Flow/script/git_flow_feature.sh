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