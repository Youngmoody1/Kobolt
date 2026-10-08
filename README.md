# Kobolt contracts

Smart contracts for [Kobolt](https://kobolt.xyz), the AI token factory on Base.

| Contract | What it does |
|---|---|
| `KoboltFactory` | Creates tokens for a fixed fee in ETH, sends the fee straight to the treasury, and counts every token it creates (`totalDeployed()`). The fee can never exceed 0.05 ETH. |
| `KoboltToken` | The ERC-20 each creator gets. Name, symbol, decimals, supply, max supply and the mintable/burnable/pausable switches are fixed at creation. The creator is the owner; Kobolt has no powers over it. Not upgradeable, no transfer taxes or blacklists. |

## Develop

```sh
git clone --recurse-submodules https://github.com/Youngmoody1/kobolt
forge test -vv
```

`artifacts/` holds the ABI and creation bytecode used by the Kobolt app. Regenerate them after any contract change:

```sh
forge build
jq -c '{abi: .abi, bytecode: .bytecode.object}' out/KoboltFactory.sol/KoboltFactory.json > artifacts/KoboltFactory.json
```

## Status

- 25 Foundry tests (including fuzzing) pass; deploy and token creation tested end to end on a local chain.
- Not audited yet. Get an independent review before handling real money on mainnet.
