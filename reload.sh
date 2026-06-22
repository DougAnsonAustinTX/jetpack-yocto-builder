#!/bin/sh

set -x
rm -rf *super
chmod 755 *.sh 
# TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform.sh
# TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform.sh
# TARGET_PLATFORM=1 ./build_oe4t_jetson_multi_platform.sh
./build_oe4t_jetson_multi_platform.sh
