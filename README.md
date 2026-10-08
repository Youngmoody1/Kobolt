# Kobolt contracts

Smart contracts for [Kobolt](https://kobolt.xyz), the AI token factory on Base.

| Contract | What it does |
|---|---|
| `KoboltFactory` | Creates tokens for a fee in ETH and counts every token it creates (`totalDeployed()`). The fee is a base price plus a small add-on for each chosen feature (mintable, burnable, pausable); `feeFor(config)` returns the exact amount. It goes straight to the treasury. Each price is capped at 0.02 ETH. |
| `KoboltToken` | The ERC-20 each creator gets. Name, symbol, decimals, supply, max supply and the mintable/burnable/pausable switches are fixed at creation. The creator is the owner; Kobolt has no powers over it. Not upgradeable, no transfer taxes or blacklists. |
| `KoboltModules` | Add-on modules for any ERC-20, each for a fee in ETH (capped at 0.02 ETH): creates vesting vaults and staking pools owned by the caller, sends airdrops to up to 500 wallets in one transaction, and locks LP tokens or LP position NFTs until a set time. The owner can only change prices and the treasury; it has no power over vaults, pools or locked assets. |
| `KoboltVesting` | One vault per token. The owner adds schedules (start, cliff, linear duration) that can never be revoked; only the beneficiary can claim, and nobody can take locked tokens out. |
| `KoboltStakingPool` | Stake a token, earn the same token. The owner funds rewards spread over a set duration, optionally capped at a maximum APR; stakers can leave at any time. |

## Develop

```sh
git clone --recurse-submodules https://github.com/Youngmoody1/kobolt
forge test -vv
```

`artifacts/` holds the ABI and creation bytecode used by the Kobolt app. Regenerate them after any contract change:

```sh
forge build
jq -c '{abi: .abi, bytecode: .bytecode.object}' out/KoboltFactory.sol/KoboltFactory.json > artifacts/KoboltFactory.json
jq -c '{abi: .abi, bytecode: .bytecode.object}' out/KoboltModules.sol/KoboltModules.json > artifacts/KoboltModules.json
```

## Status

- 67 Foundry tests (including fuzzing) pass; the factory and every module were tested end to end on a local chain.
- Not audited yet. Get an independent review before handling real money on mainnet.
