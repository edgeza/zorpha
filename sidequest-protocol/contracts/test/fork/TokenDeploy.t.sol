// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployZorphaToken} from "../../script/DeployZorphaToken.s.sol";

/// @notice The token launch, rehearsed on mainnet before it happens on mainnet.
///
///         This is the one deploy in the repo with no second attempt. Almost
///         everything it creates is fixed forever:
///
///             Zorpha              the ADDRESS every pool and listing points at
///             MerkleDistributor   merkleRoot and claimDeadline are immutable
///             ProtocolTreasury    both destinations are immutable
///             ZorphaVesting       admin is immutable
///
///         Vaults, the launcher and the factory can all be replaced later
///         without disturbing anything else. The token cannot: replacing it
///         means a new address, and every holder, pool, listing and integration
///         follows it or does not.
///
///         So this runs the real script against a live 4663 fork and checks the
///         state it lands in, for free, as many times as it takes.
///
///         NEEDS A RAISED GAS LIMIT, like the other deploy rehearsal:
///           RH_MAINNET_RPC_URL=... forge test \
///             --match-path test/fork/TokenDeploy.t.sol --gas-limit 200000000
contract TokenDeployForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address gov = address(0x6011);
    address deployer = address(0xD3910);
    bytes32 root = keccak256("airdrop-root");

    DeployZorphaToken script;
    DeployZorphaToken.Deployed d;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
        script = new DeployZorphaToken();
    }

    modifier onlyForked() {
        if (!forked) { vm.skip(true); }
        _;
    }

    function _config(address liquidityRecipient)
        internal
        view
        returns (DeployZorphaToken.Config memory)
    {
        return DeployZorphaToken.Config({
            deployer: address(script),
            gov: gov,
            usdg: USDG,
            liquidityRecipient: liquidityRecipient,
            airdropRoot: root,
            claimDeadline: block.timestamp + 90 days,
            timelockDelay: 48 hours,
            buybackThreshold: 1_000 * 1e6
        });
    }

    /// A contract stands in for the liquidity locker, because on 4663 an EOA is
    /// refused -- see below.
    function _locker() internal returns (address) {
        return address(new DeployZorphaToken());
    }

    function test_TheWholeTokenLayerDeploysOnMainnet() public onlyForked {
        d = script.deploy(_config(_locker()));

        assertTrue(address(d.zor) != address(0), "no token");
        assertTrue(address(d.timelock) != address(0), "no timelock");
        assertTrue(address(d.distributor) != address(0), "no distributor");
        assertTrue(address(d.vesting) != address(0), "no vesting");

        console2.log("ZOR        ", address(d.zor));
        console2.log("Timelock   ", address(d.timelock));
        console2.log("Distributor", address(d.distributor));
    }

    /// The whole supply leaves the deployer in the same transaction that mints
    /// it. A deploy that stranded any of it would be discovered here rather
    /// than by someone reading the token contract afterwards.
    function test_TheDeployerEndsHoldingNothing() public onlyForked {
        d = script.deploy(_config(_locker()));
        assertEq(d.zor.balanceOf(address(script)), 0, "the deployer kept supply");
        assertEq(d.zor.totalSupply(), d.zor.MAX_SUPPLY(), "supply drifted");
    }

    /// The immutables, read back off chain rather than assumed from the script.
    function test_TheThingsThatCanNeverBeChangedAreRight() public onlyForked {
        d = script.deploy(_config(_locker()));

        assertEq(d.distributor.merkleRoot(), root, "airdrop root is not what was passed");
        assertGt(d.distributor.claimDeadline(), block.timestamp, "claim window already shut");
        assertEq(d.vesting.admin(), gov, "vesting admin is not governance");
        assertEq(d.treasury.buyback(), address(d.buyback), "treasury buyback leg wrong");
        assertEq(d.treasury.operations(), gov, "treasury operations leg wrong");
    }

    /// Ownership lands on the timelock, and the treasury handover is STARTED
    /// but not finished -- Ownable2Step, so acceptOwnership is still owed. That
    /// window is real and this pins that the deploy leaves it open.
    function test_OwnershipLandsOnTheTimelockAndTheTreasuryWindowIsOpen() public onlyForked {
        d = script.deploy(_config(_locker()));

        assertEq(d.buyback.owner(), address(d.timelock), "buyback not timelocked");
        assertEq(d.insurance.owner(), address(d.timelock), "insurance not timelocked");
        assertEq(d.treasury.pendingOwner(), address(d.timelock), "treasury handover not started");
        assertEq(d.treasury.owner(), address(script), "treasury already handed over");
    }

    /// The mainnet guard that only exists on 4663, exercised ON 4663.
    ///
    /// MainnetSafety refuses a launch that hands the liquidity tranche to a
    /// bare EOA, because locked liquidity is one of three published curation
    /// criteria on this chain and curation is the discovery path. On testnet
    /// the check returns early and this can never fire, which is exactly the
    /// kind of guard that is written once and never observed working.
    function test_ABareEoaCannotReceiveTheLiquidityTranche() public onlyForked {
        assertEq(block.chainid, 4663, "not actually on mainnet");

        DeployZorphaToken.Config memory c = _config(address(0xBEEF));
        vm.expectRevert();
        script.deploy(c);
    }

    /// And the deployer cannot quietly be the recipient either.
    function test_TheDeployerCannotReceiveTheLiquidityTranche() public onlyForked {
        DeployZorphaToken.Config memory c = _config(address(script));
        vm.expectRevert();
        script.deploy(c);
    }

    /// An airdrop window already closed would mint the tranche into a contract
    /// nobody can ever claim from. Cheap to check, permanent if missed.
    function test_AClaimDeadlineInThePastIsRefused() public onlyForked {
        DeployZorphaToken.Config memory c = _config(_locker());
        c.claimDeadline = block.timestamp - 1;

        // The distributor itself refuses it; run() checks this too, but run()
        // cannot execute here, so the constructor is the backstop that matters.
        vm.expectRevert();
        script.deploy(c);
    }
}
