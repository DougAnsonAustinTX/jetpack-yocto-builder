#!/bin/bash

set -x

chmod 755 *.sh
./build-orin-super-nano.sh
./build-thor.sh
./build-orinnx.sh