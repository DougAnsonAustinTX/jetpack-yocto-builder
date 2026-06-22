#!/bin/bash

set -x

rm -rf *super
chmod 755 *.sh 
TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform.sh