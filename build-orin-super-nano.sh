#!/bin/bash

set -x

rm -rf oe4t*
chmod 755 *.sh 
TARGET_PLATFORM=orin-super-nano ./build_oe4t_jetson_multi_platform.sh