// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The two contracts that hold money and had no tests at all.
///
///         Both are deployed by DeployZorphaToken and both custody value:
///         ProtocolTreasury receives every vault's performance fee, and
///         InsuranceFund holds 4% of total supply plus any slashed leader bond.
///         Between them they are the destination of essentially all protocol
///         revenue, and nothing exercised either one.
///
///         The interesting finding is not a bug in the code below. It is that
///         `ProtocolTreasury` is Ownable2Step and the deploy only asserts the
///         handover was STARTED -- see `test_TheHandoverWindowLeavesTheDeployer
///         InControl`. The deploy's headline claim is that the deployer ends
///         with nothing, and that claim covers AccessControl roles and token
///         balances. Ownable ownership is neither.
contract ProtocolTreasuryTest is Test {
    ProtocolTreasury treasury;
    MockERC20 usdg;

    address buyback = makeAddr("buyback");
    address operations = makeAddr("operations");
    address deployer = address(this);
    address timelock = makeAddr("timelock");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        // Constructed by the deployer, exactly as DeployZorphaToken does it.
        treasury = new ProtocolTreasury(buyback, operations);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert("ProtocolTreasury: zero buyback");
        new ProtocolTreasury(address(0), operations);

        vm.expectRevert("ProtocolTreasury: zero operations");
        new ProtocolTreasury(buyback, address(0));
    }

    function test_SweepSplitsFiftyFifty() public {
        usdg.mint(address(treasury), 1_000 * 1e6);
        treasury.sweep(address(usdg));

        assertEq(usdg.balanceOf(buyback), 500 * 1e6, "buyback share wrong");
        assertEq(usdg.balanceOf(operations), 500 * 1e6, "operations share wrong");
        assertEq(usdg.balanceOf(address(treasury)), 0, "treasury not emptied");
    }

    /// An odd balance must not strand a wei. `opsAmount` is the remainder
    /// rather than a second percentage, so the two legs always re-sum to the
    /// whole -- the arithmetic that a second `(balance * 5000) / 10000` would
    /// quietly get wrong.
    function testFuzz_SweepConservesEveryUnit(uint96 raw) public {
        uint256 amount = uint256(raw);
        vm.assume(amount > 0);
        usdg.mint(address(treasury), amount);

        treasury.sweep(address(usdg));

        assertEq(
            usdg.balanceOf(buyback) + usdg.balanceOf(operations),
            amount,
            "a unit went missing in the split"
        );
        assertEq(usdg.balanceOf(address(treasury)), 0, "dust left behind");
    }

    /// Sweeping nothing is a no-op, not a revert. A keeper calling this on a
    /// schedule must not need to know whether fees have landed yet.
    function test_SweepOnEmptyIsANoOp() public {
        treasury.sweep(address(usdg));
        assertEq(usdg.balanceOf(buyback), 0);
    }

    /// Deliberately permissionless, and safe because it is: both destinations
    /// are immutable, set in the constructor. There is no argument a caller can
    /// supply that redirects the money, so anyone paying the gas to route fees
    /// to their fixed homes is doing the protocol a favour.
    function test_SweepIsPermissionlessAndStillCannotRedirect() public {
        usdg.mint(address(treasury), 100 * 1e6);

        vm.prank(stranger);
        treasury.sweep(address(usdg));

        assertEq(usdg.balanceOf(buyback), 50 * 1e6, "stranger's sweep still paid buyback");
        assertEq(usdg.balanceOf(stranger), 0, "caller took a cut");
    }

    function test_RescueIsOwnerOnly() public {
        usdg.mint(address(treasury), 100 * 1e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.rescue(address(usdg), stranger, 100 * 1e6);
    }

    function test_RescueRejectsZeroRecipient() public {
        usdg.mint(address(treasury), 100 * 1e6);
        vm.expectRevert("ProtocolTreasury: zero recipient");
        treasury.rescue(address(usdg), address(0), 100 * 1e6);
    }

    /// @notice The window this test exists for.
    ///
    ///         `rescue` is documented as an "escape hatch for tokens misrouted
    ///         to this contract", but it is not restricted to misrouted tokens:
    ///         it moves any balance, including the accumulated fee revenue this
    ///         contract exists to hold.
    ///
    ///         That is defensible when the owner is the Timelock. It is not the
    ///         state the contract is in after deployment. Ownable2Step means
    ///         `transferOwnership` only sets `pendingOwner`, so between the
    ///         deploy and the Timelock executing `acceptOwnership()` the
    ///         deploying EOA can still drain it -- and the deploy asserts only
    ///         that the handover was STARTED:
    ///
    ///             require(d.treasury.pendingOwner() == address(d.timelock),
    ///                     "treasury handover missing");
    ///
    ///         Nothing closes the window, and nothing measures how long it
    ///         stays open. On testnet with a burner key that is uninteresting.
    ///         On mainnet it is a single EOA standing between an attacker and
    ///         every fee collected before governance gets round to step 1 of
    ///         the post-deploy checklist.
    function test_TheHandoverWindowLeavesTheDeployerInControl() public {
        treasury.transferOwnership(timelock);

        assertEq(treasury.owner(), deployer, "ownership moved early");
        assertEq(treasury.pendingOwner(), timelock, "handover not started");

        usdg.mint(address(treasury), 1_000 * 1e6);

        // The deployer can still take all of it.
        treasury.rescue(address(usdg), deployer, 1_000 * 1e6);
        assertEq(usdg.balanceOf(deployer), 1_000 * 1e6, "the window is not real");

        // And the Timelock, the intended owner, cannot act yet.
        usdg.mint(address(treasury), 500 * 1e6);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, timelock));
        treasury.rescue(address(usdg), timelock, 500 * 1e6);
    }

    /// And once accepted, the window is shut in both directions.
    function test_AcceptingOwnershipClosesTheWindow() public {
        treasury.transferOwnership(timelock);
        vm.prank(timelock);
        treasury.acceptOwnership();

        assertEq(treasury.owner(), timelock, "handover did not complete");

        usdg.mint(address(treasury), 100 * 1e6);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        treasury.rescue(address(usdg), deployer, 100 * 1e6);

        vm.prank(timelock);
        treasury.rescue(address(usdg), timelock, 100 * 1e6);
        assertEq(usdg.balanceOf(timelock), 100 * 1e6, "timelock cannot spend what it owns");
    }
}

/// @notice InsuranceFund holds 4% of supply and any slashed bond.
///
///         Unlike the treasury it takes its owner in the CONSTRUCTOR rather
///         than transferring afterwards, so it is governance-owned from its
///         first block and has no handover window at all. That difference is
///         worth pinning: the two contracts deploy side by side and only one
///         of them is safe on arrival.
contract InsuranceFundTest is Test {
    InsuranceFund fund;
    MockERC20 zor;

    address governance = makeAddr("governance");
    address stranger = makeAddr("stranger");
    address claimant = makeAddr("claimant");

    function setUp() public {
        zor = new MockERC20("Zorpha", "ZOR", 18);
        fund = new InsuranceFund(governance);
        zor.mint(address(fund), 40_000_000e18);
    }

    function test_GovernanceOwnsItFromTheFirstBlock() public view {
        assertEq(fund.owner(), governance, "not owned by governance on arrival");
        assertEq(fund.pendingOwner(), address(0), "an unexpected handover is pending");
    }

    function test_ReserveOfReportsTheBalance() public view {
        assertEq(fund.reserveOf(address(zor)), 40_000_000e18);
    }

    function test_PayoutIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.payout(address(zor), stranger, 1e18, "theft");
    }

    function test_PayoutPaysAndRecordsTheReason() public {
        vm.expectEmit(true, true, false, true, address(fund));
        emit InsuranceFund.PaidOut(address(zor), claimant, 1_000e18, "oracle failure 2026-09");

        vm.prank(governance);
        fund.payout(address(zor), claimant, 1_000e18, "oracle failure 2026-09");

        assertEq(zor.balanceOf(claimant), 1_000e18, "claimant not paid");
        assertEq(fund.reserveOf(address(zor)), 40_000_000e18 - 1_000e18, "reserve not reduced");
    }

    function test_PayoutRejectsZeroRecipientAndZeroAmount() public {
        vm.startPrank(governance);

        vm.expectRevert("InsuranceFund: zero recipient");
        fund.payout(address(zor), address(0), 1e18, "x");

        vm.expectRevert("InsuranceFund: zero amount");
        fund.payout(address(zor), claimant, 0, "x");

        vm.stopPrank();
    }

    /// A payout larger than the reserve must fail on the transfer rather than
    /// silently paying out less -- an underpaid claim looks settled.
    function test_PayoutBeyondTheReserveReverts() public {
        vm.prank(governance);
        vm.expectRevert();
        fund.payout(address(zor), claimant, 40_000_001e18, "too much");
    }
}
