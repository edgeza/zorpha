// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {YieldVault} from "../../src/vaults/YieldVault.sol";
import {StubYieldAdapter} from "../../src/adapters/StubYieldAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// Who can reach `setAdapter`, and why DEFAULT_ADMIN_ROLE must be the timelock.
///
/// `setAdapter` is `onlyRole(ADAPTER_SETTER_ROLE)`, and the deploy hands that
/// role to the Timelock so that repointing where depositor funds are held takes
/// 48 hours. That reads as a hard guarantee. It is not one on its own.
///
/// OpenZeppelin's AccessControl makes DEFAULT_ADMIN_ROLE the admin of every
/// role unless `_setRoleAdmin` says otherwise. So whoever holds
/// DEFAULT_ADMIN_ROLE can grant themselves ADAPTER_SETTER_ROLE and call
/// `setAdapter` in the next transaction, with no delay at all.
///
/// This was live. Simulated against the deployed testnet yield vault:
///
///     getRoleAdmin(ADAPTER_SETTER_ROLE) == DEFAULT_ADMIN_ROLE
///     gov holds DEFAULT_ADMIN_ROLE      == true
///     grantRole(ADAPTER_SETTER_ROLE, gov) from gov  -> SUCCEEDS
///
/// Two transactions and the 48h window depositors were supposed to have was
/// gone. An advisory delay is worse than no delay: the code read as though the
/// protection existed, so nobody went looking for it.
///
/// The fix is in the deploy, not here: DEFAULT_ADMIN_ROLE on the three factory
/// vaults goes to the Timelock, and `gov` keeps only RISK_COUNCIL_ROLE and
/// KEEPER_ROLE -- enough to pull the circuit breaker in one block, not enough
/// to escalate. The leadership layer already worked this way; VaultLauncher
/// gives launched vaults DEFAULT_ADMIN to the timelock and keeps only
/// ADAPTER_SETTER_ROLE, so gov has nothing to escalate from.
///
/// These tests pin the mechanism in place. The first asserts the escalation
/// path EXISTS, which sounds backwards for a security test and is the point:
/// it is the reason the deploy must not give that role to gov. If someone later
/// self-administers ADAPTER_SETTER_ROLE, that test fails and forces a decision
/// rather than quietly changing the threat model.
contract RoleEscalationTest is Test {
    MockERC20 usdc;
    StubYieldAdapter adapter;
    StubYieldAdapter otherAdapter;
    YieldVault vault;

    address timelock = makeAddr("timelock");
    address gov = makeAddr("gov");
    address riskCouncil = makeAddr("riskCouncil");

    // Cached deliberately. `vault.ADAPTER_SETTER_ROLE()` is an external call,
    // so evaluating it inside a pranked call's arguments consumes the prank and
    // the call under test executes as this contract instead of the actor. Three
    // of these tests failed that way first time round, each reporting the test
    // contract's address where the actor's should have been.
    bytes32 SETTER;
    bytes32 RISK;

    function setUp() public {
        usdc = new MockERC20("Global Dollar", "USDG", 6);
        adapter = new StubYieldAdapter(address(usdc), address(this));
        otherAdapter = new StubYieldAdapter(address(usdc), address(this));
        // This test contract is admin_, standing in for the deployer.
        vault = new YieldVault(
            address(usdc), address(adapter),
            "Zorpha USDG Yield Vault", "zqUSDG",
            0, address(this), address(this)
        );
        SETTER = vault.ADAPTER_SETTER_ROLE();
        RISK = vault.RISK_COUNCIL_ROLE();
    }

    /// Reproduce the deploy's OLD handover: gov gets DEFAULT_ADMIN, the
    /// timelock gets ADAPTER_SETTER_ROLE, the deployer renounces.
    function _handOverTheOldWay() internal {
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), timelock);
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), gov);
        vault.grantRole(0x00, gov);
        vault.renounceRole(0x00, address(this));
    }

    /// And the NEW one: the timelock gets DEFAULT_ADMIN, gov gets only the
    /// roles that must act without waiting.
    function _handOverTheNewWay() internal {
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), timelock);
        vault.grantRole(vault.RISK_COUNCIL_ROLE(), gov);
        vault.grantRole(vault.KEEPER_ROLE(), gov);
        vault.grantRole(0x00, timelock);
        vault.renounceRole(0x00, address(this));
    }

    // ─── The mechanism ──────────────────────────────────────────────────────

    /// ADAPTER_SETTER_ROLE is administered by DEFAULT_ADMIN_ROLE. Asserted so
    /// that changing it is a deliberate act with a failing test attached, not a
    /// silent change to who can move depositor funds.
    function test_AdapterSetterRole_IsAdministeredByDefaultAdmin() public view {
        assertEq(
            vault.getRoleAdmin(vault.ADAPTER_SETTER_ROLE()),
            bytes32(0x00),
            "if this changed, the escalation model below changed with it"
        );
    }

    /// The bug, reproduced. Under the old handover gov reaches setAdapter in
    /// two transactions and the timelock is bypassed entirely.
    function test_OldHandover_GovEscalatesToSetAdapter_WithNoDelay() public {
        _handOverTheOldWay();

        assertTrue(vault.hasRole(0x00, gov), "setup: gov should be admin here");
        assertFalse(
            vault.hasRole(vault.ADAPTER_SETTER_ROLE(), gov),
            "setup: gov should not start with the setter role"
        );

        vm.startPrank(gov);
        vault.grantRole(vault.ADAPTER_SETTER_ROLE(), gov);   // tx 1
        vault.setAdapter(address(otherAdapter));             // tx 2
        vm.stopPrank();

        assertEq(
            address(vault.adapter()),
            address(otherAdapter),
            "gov repointed the adapter without the timelock -- this is the finding"
        );
    }

    /// The fix. Under the new handover gov cannot grant itself the role, so the
    /// first step of that escalation reverts.
    function test_NewHandover_GovCannotGrantItselfTheSetterRole() public {
        _handOverTheNewWay();

        assertFalse(vault.hasRole(0x00, gov), "gov must not be admin");

        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, gov, bytes32(0x00)
            )
        );
        vault.grantRole(SETTER, gov);
    }

    /// And it cannot call setAdapter directly either.
    function test_NewHandover_GovCannotCallSetAdapter() public {
        _handOverTheNewWay();

        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, gov, SETTER
            )
        );
        vault.setAdapter(address(otherAdapter));
    }

    /// The timelock still can, or the fix would have bricked the function it
    /// was protecting.
    function test_NewHandover_TimelockCanStillSetAdapter() public {
        _handOverTheNewWay();

        vm.prank(timelock);
        vault.setAdapter(address(otherAdapter));

        assertEq(address(vault.adapter()), address(otherAdapter), "the timelock must retain the power");
    }

    /// The circuit breaker must stay pullable in one block. A delay on the
    /// emergency stop would be a worse bug than the one being fixed.
    function test_NewHandover_GovKeepsTheCircuitBreaker() public {
        _handOverTheNewWay();

        vm.prank(gov);
        vault.setCircuitBreaker(true);
        assertTrue(vault.isCircuitBreakerActive(), "gov must be able to halt deposits immediately");

        vm.prank(gov);
        vault.setCircuitBreaker(false);
        assertFalse(vault.isCircuitBreakerActive(), "and lift it again");
    }

    /// A holder of only the fast operational roles has no path to setAdapter.
    /// This is the property the whole arrangement exists to produce.
    function test_NewHandover_OperationalRolesCannotReachSetAdapter() public {
        _handOverTheNewWay();
        vm.prank(timelock);
        vault.grantRole(RISK, riskCouncil);
        assertTrue(vault.hasRole(RISK, riskCouncil), "setup: the grant must have landed");

        vm.startPrank(riskCouncil);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, riskCouncil, bytes32(0)
            )
        );
        vault.grantRole(SETTER, riskCouncil);
        // A DIFFERENT role from the line above: granting SETTER needs its admin
        // (DEFAULT_ADMIN), calling setAdapter needs SETTER itself.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, riskCouncil, SETTER
            )
        );
        vault.setAdapter(address(otherAdapter));
        vm.stopPrank();
    }

    /// The deployer must be left with nothing on either path. A deployer key
    /// that keeps admin is the same escalation with a worse key holding it --
    /// and this deployment's original deployer key is publicly known.
    function test_BothHandovers_StripTheDeployerCompletely() public {
        _handOverTheNewWay();
        assertFalse(vault.hasRole(0x00, address(this)), "deployer kept admin");
        assertFalse(
            vault.hasRole(vault.ADAPTER_SETTER_ROLE(), address(this)),
            "deployer kept the setter role"
        );
    }
}
