# Kobolt contracts

Smart contracts behind [Kobolt](https://koboltlaunch.com), a no-code token creator on Base. Anyone can create an ERC-20 token from their own wallet, then add vesting, staking, airdrops and liquidity locks, without writing code.

## Deployed on Base mainnet

| Contract | Address |
|---|---|
| `KoboltFactory` | [`0xb940565698abbA5caB093dA6185f477bb711d9EF`](https://basescan.org/address/0xb940565698abbA5caB093dA6185f477bb711d9EF#code) |
| `KoboltModules` | [`0x8aeD3ebE83Edf1ff190ed0935C89897e5d3033EE`](https://basescan.org/address/0x8aeD3ebE83Edf1ff190ed0935C89897e5d3033EE#code) |

Both are verified on BaseScan. Every token, vesting vault and staking pool is created by one of these two contracts. Read the live fees with `prices()` on either contract.

## What the contracts do

| Contract | What it does |
|---|---|
| `KoboltFactory` | Creates tokens for a fee in ETH and counts every token it creates (`totalDeployed()`). The fee is a base price plus an add-on for each chosen feature (mintable, burnable, pausable); `feeFor(config)` returns the exact amount. It goes straight to the treasury. Each price is capped at 0.02 ETH. |
| `KoboltToken` | The ERC-20 each creator gets. Name, symbol, decimals, supply, max supply and the mintable/burnable/pausable switches are fixed at creation. The creator is the owner (two-step transfer; can't renounce while paused); Kobolt has no powers over it. `maxSupply` caps every token ever minted, and equals the initial supply for fixed tokens. Not upgradeable, no transfer taxes or blacklists. |
| `KoboltModules` | Add-on modules for any ERC-20, each for a fee in ETH (capped at 0.02 ETH): creates vesting vaults and staking pools owned by the caller, sends airdrops to up to 500 wallets in one transaction, and locks LP tokens or LP position NFTs until a set time. The owner can only change prices and the treasury; it has no power over vaults, pools or locked assets. |
| `KoboltVesting` | One vault per token. The owner adds schedules (start, cliff, linear duration) that can never be revoked; only the beneficiary can claim, and nobody can take locked tokens out. |
| `KoboltStakingPool` | Stake a token, earn the same token. The owner funds rewards spread over a set duration, optionally capped at a maximum APR; stakers can leave at any time. |

## What a Kobolt token can never do

- Charge a tax or fee on transfers, buys or sells.
- Block a wallet (no blacklist).
- Be upgraded or have its code swapped.
- Change its name, symbol, cap or feature switches after creation.
- Be controlled by Kobolt: only the creator (or whoever they hand ownership to) is the owner.

## Develop

Requires [Foundry](https://book.getfoundry.sh).

```sh
git clone --recurse-submodules https://github.com/Youngmoody1/kobolt
cd kobolt
forge test -vv
```

`artifacts/` holds the ABI and creation bytecode used by the Kobolt app. Regenerate them after any contract change:

```sh
forge build
jq -c '{abi: .abi, bytecode: .bytecode.object}' out/KoboltFactory.sol/KoboltFactory.json > artifacts/KoboltFactory.json
jq -c '{abi: .abi, bytecode: .bytecode.object}' out/KoboltModules.sol/KoboltModules.json > artifacts/KoboltModules.json
```

## Security

- 80 Foundry tests, including fuzzing, run on every push. The factory and every module were tested end to end on a local chain and on Base Sepolia before the mainnet deployment.
- An internal security review (three independent reviewers with proof-of-concept tests) found no critical or high issues. Every medium and low finding is fixed and covered by `test/Security.t.sol`.
- This is not a professional third-party audit. Get one before large amounts depend on these contracts.

Found a security problem? Please don't open a public issue. Email security@koboltlaunch.com instead.

## Learn more

- [Create a token on Base](https://koboltlaunch.com/create-token-on-base)
- [How to launch a token on Base](https://koboltlaunch.com/guides/launch-a-token-on-base)
- [ERC-20 owner powers: mint, burn and pause](https://koboltlaunch.com/guides/erc20-owner-powers)
- [What a launch costs](https://koboltlaunch.com/token-launch-cost)

## License

MIT. See [LICENSE](LICENSE).
