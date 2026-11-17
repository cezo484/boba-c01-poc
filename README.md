# Boba c-01 PoC — BobaFixedSavings is insolvent, active stakers cannot withdraw principal

BobaFixedSavings on Boba mainnet (chain 288, proxy
`0x9Fb3051148ff6EFCD0B5bA0Afa22EB0B9fC67A69`) holds less BOBA than the
principal plus accrued rewards it owes to still-active stakes.
`unstake()` pays principal and reward atomically in a single transaction,
so once the contract balance runs out, a legitimate unstake reverts in
full and the user cannot recover even their own principal. There is no
principal-only withdrawal path, and the shortfall grows by itself because
rewards accrue at 0.22% per 16-day period with no yield source behind them.

Fresh numbers, re-verified 17 Nov 2026 ~11:55 +03 (Boba block 41950419):

- Active stakes: 5,360, active principal: 7,261,921.59 BOBA
- Accrued rewards owed: 385,704.43 BOBA
- Total owed: 7,647,626.02 BOBA, contract balance: 6,377,306.01 BOBA
- Shortfall: 1,270,320.01 BOBA (about $17,800 at $0.014/BOBA)
- Shortfall in principal alone: 884,615.58 BOBA, so even with zero rewards
  the last stakers to exit could not get their deposits back.

The pool is still open for new stakes (`stakingCloseTimestamp` is 0, not
paused). The newest stake (id 6721, 509,619 BOBA) was created on 14 Nov
2026. No stakes or unstakes have happened since the morning audit.

## What the test proves

The test unstakes 23 real, active stakes (largest first), each as its real
owner, warping into each stake's unstake window. All succeed. It then
unstakes one more real, active stake (id 251, 45,031 BOBA principal, owner
holds the required xBOBA) in its window. That unstake REVERTS: the contract
holds 50,856 BOBA but owes this user 56,820 BOBA (principal + reward).
Because `unstake()` pays principal and reward atomically, the user cannot
recover even the 45,031 BOBA principal. The stake stays active and the owner
receives nothing. The test asserts the revert, the shortfall, and the locked
state.

The stake ids, owners and amounts come from a full on-chain read of all
6,721 `stakeDataMap` entries on Boba mainnet.

## Run

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
forge install foundry-rs/forge-std

forge test --fork-url https://mainnet.boba.network \
  --fork-block-number 41949235 -vvv
```

- Fork block: 41949235 (Boba mainnet, 17 Nov 2026). The test also passes
  at the fresh verification block 41950419.
- No privileged accounts are used. Owners are impersonated with `vm.prank`
  (standard fork simulation) and given 1 ETH for gas with `vm.deal`.
- The public Boba RPC is slow; the first run can take a while because
  Foundry fetches fork state on demand. Later runs use the local fork cache.

## Notes

- `unstake()` requires the caller to hold xBOBA at least equal to the
  deposit. Every drain stake owner and the victim owner were verified
  on-chain to hold exactly the required xBOBA amount, so the victim's
  revert comes from the contract's empty balance, not from a missing
  xBOBA check.
- The victim assertion is `balanceNow < owedToVictim` before the revert
  attempt, so the test fails loudly if the contract is ever topped up.

## Files

- `test/BobaFixedSavingsInsolvency.t.sol`: the insolvency proof, 1 test.
- `foundry.toml`: solc 0.8.28, cancun.
