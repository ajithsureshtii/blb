This is the official implementation of the paper "Breaking the Layer Barrier: Remodeling Private Transformer Inference with Hybrid CKKS and MPC".

## Setup
```
./setup_env_and_build.sh
clone phantom from https://github.com/encryptorion-lab/phantom-fhe.git
apply 0001-.patch for phantom
build phantom in SCI/extern/phantom
```

## Build
```
cd SCI/tests
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=./install .. -DNO_REVEAL_OUTPUT=ON
cmake --build . --target install --parallel
```
## Run
```
./bin/ckks_bert_large_main r=1 p=1234 && ./bin/ckks_bert_large_main ip=127.0.0.1 r=2 p=1234
```
## Test data
Important test data in BLB paper is in `/SCI/output/`

