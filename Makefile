-include .env

# deps
build  :; forge build
update:; forge update
size  :; forge build --sizes

# storage inspection
inspect :; forge inspect ${contract} storage-layout --pretty

# specify which fork to use. set this in our .env
# if we want to test multiple forks in one go, remove this as an argument below
FORK_URL := ${ETH_RPC_URL} # BASE_RPC_URL, ETH_RPC_URL, ARBITRUM_RPC_URL

# if we want to run only matching tests, set that here
test := test_

# local tests without fork
test  :; forge test -vv --fork-url ${FORK_URL}
trace  :; forge test -vvvv --fork-url ${FORK_URL}
gas  :; forge test --fork-url ${FORK_URL} --gas-report --isolate
test-contract  :; forge test -vv --match-contract $(contract) --fork-url ${FORK_URL}
test-contract-gas  :; forge test --gas-report --match-contract ${contract} --fork-url ${FORK_URL}
trace-contract  :; forge test -vvvv --match-contract $(contract) --fork-url ${FORK_URL}
test-test  :; forge test -vv --match-test $(test) --fork-url ${FORK_URL}
test-test-trace  :; forge test -vvv --match-test $(test) --fork-url ${FORK_URL}
trace-test  :; forge test -vvvv --fail-fast --match-test $(test) --fork-url ${FORK_URL}
test-path  :; forge test -vv --match-path $(path) --fork-url ${FORK_URL}
test-path-test  :; forge test -vv --match-path $(path) --match-test $(test) --fork-url ${FORK_URL}
test-path-gas  :; forge test --gas-report --match-path ${path} --fork-url ${FORK_URL}
trace-path  :; forge test -vvvv --match-path $(path) --fork-url ${FORK_URL}
trace-path-test  :; forge test -vvvv --match-path $(path) --match-test $(test) --fork-url ${FORK_URL}
snapshot :; forge snapshot -vv --isolate --fork-url ${FORK_URL}
snapshot-diff :; forge snapshot --diff -vv --isolate --fork-url ${FORK_URL}
trace-setup  :; forge test -vvvv --fork-url ${FORK_URL}
trace-max  :; forge test -vvvvv --fork-url ${FORK_URL}
coverage :; forge coverage --fork-url ${FORK_URL}
coverage-report :; forge coverage --report lcov --fork-url ${FORK_URL}
coverage-debug :; forge coverage --report debug --fork-url ${FORK_URL}


clean  :; forge clean
