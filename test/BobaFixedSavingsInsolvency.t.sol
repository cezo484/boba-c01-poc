// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

interface IBobaFixedSavings {
    function stakeDataMap(uint256 stakeId)
        external
        view
        returns (uint256 id, address account, uint256 depositAmount, uint256 depositTimestamp, bool isActive);
    function unstake(uint256 stakeId) external;
    function stakingCloseTimestamp() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @notice Proves BobaFixedSavings is insolvent on Boba mainnet (chain 288).
 *
 * The contract holds less BOBA than the principal + accrued rewards it owes to
 * still-active stakes. unstake() pays principal and reward atomically in one
 * transaction, so once the balance runs out, a legitimate unstake reverts in
 * full: the user cannot recover even their own principal. There is no
 * principal-only withdrawal path.
 *
 * Test plan (mainnet fork, no privileged accounts):
 *  1. Read the contract's live BOBA balance.
 *  2. Unstake a list of real, active stakes (largest first), warping into each
 *     stake's unstake window and calling as the real owner. Each succeeds
 *     while the balance covers it.
 *  3. Take one more real, active stake whose owner holds enough xBOBA, warp
 *     into its window, and show its unstake REVERTS even though the stake is
 *     active, in-window, and the owner holds the required xBOBA.
 *  4. Assert the victim stake is still active afterwards and the contract
 *     balance is below what it owes that stake: the principal is locked.
 *
 * Stake ids, owners and amounts below come from a full on-chain read of all
 * 6721 stakeDataMap entries (see notes.md). They are real mainnet stakes.
 */
contract BobaFixedSavingsInsolvencyTest is Test {
    address constant SAVINGS = 0x9Fb3051148ff6EFCD0B5bA0Afa22EB0B9fC67A69;
    address constant L2BOBA = 0xa18bF3994C0Cc6E3b63ac420308E5383f53120D7;
    address constant XBOBA = 0x5747a93C87943A9567c6db00b38F1E78bF14b7C0;

    uint256 constant LOCK_TIME = 2 weeks;
    uint256 constant UNSTAKE_TIME = 2 days;
    uint256 constant PERIOD = LOCK_TIME + UNSTAKE_TIME;
    uint256 constant FLAT_INTEREST_PER_PERIOD = 22;

    // Active stakes to drain with, largest first. Filled in after the scan.
    uint256[] internal drainStakes;
    // The victim stake: active, in-window at test time, owner holds xBOBA.
    uint256 internal victimStake;

    function setUp() public {
        // Fork block 41949235 (Boba mainnet, 17 Nov 2026). See README.
        // Drain list + victim come from a full on-chain read of all 6721
        // stakes (see notes.md): largest active stakes first, each owner
        // verified to hold enough xBOBA. Draining these 23 leaves 50,856
        // BOBA in the contract, below what victim stake 251 is owed.
        drainStakes = new uint256[](23);
        drainStakes[0] = 6714;
        drainStakes[1] = 6720;
        drainStakes[2] = 6695;
        drainStakes[3] = 6721;
        drainStakes[4] = 6692;
        drainStakes[5] = 6708;
        drainStakes[6] = 6711;
        drainStakes[7] = 6710;
        drainStakes[8] = 6700;
        drainStakes[9] = 1466;
        drainStakes[10] = 6718;
        drainStakes[11] = 6713;
        drainStakes[12] = 266;
        drainStakes[13] = 1687;
        drainStakes[14] = 1720;
        drainStakes[15] = 6705;
        drainStakes[16] = 473;
        drainStakes[17] = 6306;
        drainStakes[18] = 6668;
        drainStakes[19] = 1712;
        drainStakes[20] = 159;
        drainStakes[21] = 1252;
        drainStakes[22] = 2329;
        victimStake = 251;
    }

    /// @notice Next timestamp at/after `from` that falls inside the stake's unstake window.
    function _nextWindow(uint256 depositTs, uint256 from) internal pure returns (uint256) {
        uint256 elapsed = from - depositTs;
        uint256 phase = elapsed % PERIOD;
        if (phase > LOCK_TIME) return from + 1; // already in a window
        return from + (LOCK_TIME - phase) + 1; // jump just past the lock
    }

    function _owed(uint256 deposit, uint256 depositTs, uint256 atTs) internal view returns (uint256) {
        uint256 finalTs = atTs;
        uint256 closeTs = IBobaFixedSavings(SAVINGS).stakingCloseTimestamp();
        if (closeTs != 0 && closeTs < finalTs) finalTs = closeTs;
        uint256 periods = ((finalTs - depositTs) / PERIOD) + 1;
        uint256 reward = (deposit * FLAT_INTEREST_PER_PERIOD * periods) / 10000;
        return deposit + reward;
    }

    function test_insolvency_locks_principal() public {
        require(drainStakes.length > 0, "fill in drainStakes first");
        require(victimStake != 0, "fill in victimStake first");

        uint256 startBalance = IERC20(L2BOBA).balanceOf(SAVINGS);

        // Drain: unstake real stakes until the balance can no longer cover the victim.
        for (uint256 i = 0; i < drainStakes.length; i++) {
            (, address owner, uint256 deposit, uint256 depositTs, bool active) =
                IBobaFixedSavings(SAVINGS).stakeDataMap(drainStakes[i]);
            require(active, "drain stake not active");
            require(IERC20(XBOBA).balanceOf(owner) >= deposit, "drain owner lacks xBOBA");
            uint256 loopTs = vm.getBlockTimestamp();
            vm.warp(_nextWindow(depositTs, loopTs));
            vm.deal(owner, 1 ether);
            vm.prank(owner);
            IBobaFixedSavings(SAVINGS).unstake(drainStakes[i]);
        }

        // Victim: a real active stake, owner holds the xBOBA, warp into window.
        (, address vOwner, uint256 vDeposit, uint256 vDepositTs, bool vActive) =
            IBobaFixedSavings(SAVINGS).stakeDataMap(victimStake);
        assertTrue(vActive, "victim stake must be active");
        assertGe(IERC20(XBOBA).balanceOf(vOwner), vDeposit, "victim owner must hold xBOBA");
        uint256 nowTs = vm.getBlockTimestamp();
        vm.warp(_nextWindow(vDepositTs, nowTs));
        uint256 owedToVictim = _owed(vDeposit, vDepositTs, vm.getBlockTimestamp());
        uint256 balanceNow = IERC20(L2BOBA).balanceOf(SAVINGS);

        // The core assertion: the contract cannot pay what it owes this user.
        assertLt(balanceNow, owedToVictim, "contract should be unable to pay the victim");

        // And the user's unstake reverts, leaving the principal locked.
        uint256 ownerBobaBefore = IERC20(L2BOBA).balanceOf(vOwner);
        vm.deal(vOwner, 1 ether);
        vm.prank(vOwner);
        vm.expectRevert();
        IBobaFixedSavings(SAVINGS).unstake(victimStake);

        // Stake is still active, owner received nothing.
        (, , , , bool stillActive) = IBobaFixedSavings(SAVINGS).stakeDataMap(victimStake);
        assertTrue(stillActive, "victim stake still active after failed unstake");
        assertEq(IERC20(L2BOBA).balanceOf(vOwner), ownerBobaBefore, "victim received no BOBA");

        emit log_named_uint("contract balance at fork", startBalance);
        emit log_named_uint("contract balance before victim unstake", balanceNow);
        emit log_named_uint("owed to victim (principal + reward)", owedToVictim);
        emit log_named_uint("shortfall for victim", owedToVictim - balanceNow);
    }
}
