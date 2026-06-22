#!/bin/bash

set -x

rm -rf *super
chmod 755 *.sh 
TARGET_PLATFORM=orin-super-nano ./build_oe4t_jetson_multi_platform_v10.sh