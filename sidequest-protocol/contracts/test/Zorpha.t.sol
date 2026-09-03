// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Zorpha} from "../src/Zorpha.sol";
import {ZorphaVesting} from "../src/ZorphaVesting.sol";
import {ZorphaBuyback} from "../src/ZorphaBuyback.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Swap venue that actually moves both legs, so a buyback test proves a
///      real purchase happened rather than just an event firing.
contract MockSwapRouter {
    IERC20 public immutable usdc;
    Zorpha public immutable zor;
    uint256 public rate; // ZOR (18dp) per 1 USDC (6dp)

    constructor(IERC20 usdc_, Zorpha zor_, uint256 rate_) {
        usdc = usdc_;
        zor = zor_;
        rate = rate_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256)
        external
        returns (uint256)
    {
        require(tokenIn == address(usdc) && tokenOut == address(zor), "pair");
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e6;
        zor.transfer(msg.sender, out);
        return out;
    }
}

/// @dev A router that takes the USDC and delivers nothing. Guards the exact
///      failure mode the original buyback shipped with.
contract StealingRouter {
    IERC20 public immutable usdc;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function swap(address, address, uint256 amountIn, uint256) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        return amountIn; // lies about the fill
    }
}

contract ZorphaTokenTest is Test {
    Zorpha token;
    address holder = makeAddr("holder");

    function setUp() public {
        token = new Zorpha(holder);
    }

    function test_FixedSupplyMintedToInitialHolder() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.MAX_SUPPLY(), 1_000_000_000e18);
        assertEq(token.balanceOf(holder), 1_000_000_000e18);
    }

    function test_BrandIsZorpha() public view {
        assertEq(token.name(), "Zorpha");
        assertEq(token.symbol(), "ZOR");
        assertEq(token.decimals(), 18);
    }

    function test_ConstructorRejectsZeroHolder() public {
        vm.expectRevert("Zorpha: zero initial holder");
        new Zorpha(address(0));
    }

    /// FINDING C-02 regression. The old token carried `mintForTestnet`, which
    /// could never succeed (constructor already minted the whole cap, so
    /// ERC20Votes reverted with ERC20ExceededSafeSupply) yet the test suite
    /// asserted it worked. There must now be no mint entrypoint at all.
    function test_NoMintEntrypointExists() public {
        (bool ok,) = address(token).call(
            abi.encodeWithSignature("mintForTestnet(address,uint256)", holder, 1)
        );
        assertFalse(ok, "mintForTestnet must not exist");

        (bool ok2,) = address(token).call(
            abi.encodeWithSignature("mint(address,uint256)", holder, 1)
        );
        assertFalse(ok2, "mint must not exist");
    }

    function test_BurnReducesTotalSupply() public {
        vm.prank(holder);
        token.burn(1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1_000e18);
    }

    function test_BurnFromRespectsAllowance() public {
        address spender = makeAddr("spender");

        vm.prank(holder);
        token.approve(spender, 500e18);

        vm.prank(spender);
        token.burnFrom(holder, 500e18);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 500e18);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1
            )
        );
        token.burnFrom(holder, 1);
    }

    /// Supply can only ever fall, so burning then re-minting the difference is
    /// impossible. Guards against a mint being reintroduced later.
    function test_SupplyIsMonotonicallyDecreasing() public {
        vm.prank(holder);
        token.burn(10_000e18);
        uint256 afterBurn = token.totalSupply();
        assertLt(afterBurn, 1_000_000_000e18);

        vm.prank(holder);
        token.transfer(makeAddr("x"), 1e18);
        assertEq(token.totalSupply(), afterBurn, "transfers must not change supply");
    }

    /// FINDING M-05 regression: voting must be timestamp-keyed (ERC-6372), not
    /// block-number-keyed, because L2 block cadence is not a stable clock.
    function test_VotingClockIsTimestampBased() public view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
        assertEq(token.clock(), uint48(block.timestamp));
    }

    /// The token really does carry voting weight. This is the capability the
    /// old docs and marketing copy denied having.
    ///
    /// NOTE: timepoints here are literals, not reads of `block.timestamp`.
    /// foundry.toml sets `via_ir = true`, and the IR optimizer rematerialises
    /// the TIMESTAMP opcode at each use rather than caching it in a stack slot.
    /// A local `uint256 t0 = block.timestamp` therefore silently picks up the
    /// post-`vm.warp` value, which makes any past-lookup assertion bogus.
    function test_VotingWeightIsRealAfterDelegation() public {
        uint256 t0 = 1_700_000_000;
        vm.warp(t0);

        assertEq(token.getVotes(holder), 0, "undelegated holders have no weight");

        vm.prank(holder);
        token.delegate(holder);
        assertEq(token.getVotes(holder), 1_000_000_000e18);

        vm.warp(t0 + 3600);
        vm.prank(holder);
        token.transfer(makeAddr("other"), 400_000_000e18);

        assertEq(token.getVotes(holder), 600_000_000e18);
        assertEq(token.getPastVotes(holder, t0), 1_000_000_000e18, "checkpoint must be queryable");
    }

    function test_PermitNoncesResolve() public view {
        assertEq(token.nonces(holder), 0);
    }
}

contract ZorphaVestingTest is Test {
    Zorpha token;
    ZorphaVesting vesting;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint64 start;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new Zorpha(admin);
        vesting = new ZorphaVesting(address(token), admin);
        start = uint64(block.timestamp);
    }

    function _fundOne(address who, uint256 amount, uint64 cliff, uint64 vest, bool revocable)
        internal
    {
        address[] memory bens = new address[](1);
        bens[0] = who;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint64[] memory cliffs = new uint64[](1);
        cliffs[0] = cliff;
        uint64[] memory vests = new uint64[](1);
        vests[0] = vest;
        bool[] memory revs = new bool[](1);
        revs[0] = revocable;

        vm.startPrank(admin);
        token.approve(address(vesting), amount);
        vesting.fund(bens, amounts, cliffs, vests, revs, start);
        vm.stopPrank();
    }

    /// FINDING H-03 regression. The old contract vested linearly over
    /// (cliff + vestDuration), so a "12 month cliff, 48 month vest" actually
    /// ran 60 months and released 20% at the cliff instead of 25%. Both the
    /// end date and the cliff release fraction were wrong.
    function test_CliffIsNotAdditiveWithVestDuration() public {
        uint64 cliff = 365 days;
        uint64 vest = 4 * 365 days;
        _fundOne(alice, 400_000e18, cliff, vest, false);

        // One second before the cliff: nothing.
        vm.warp(start + cliff - 1);
        assertEq(vesting.claimable(alice), 0);

        // At the cliff: exactly 25% of a 48-month schedule.
        vm.warp(start + cliff);
        assertEq(vesting.claimable(alice), 100_000e18, "cliff must release 25%, not 20%");

        // Halfway: 50%.
        vm.warp(start + vest / 2);
        assertEq(vesting.claimable(alice), 200_000e18);

        // End of vestDuration measured from start, NOT start + cliff + vest.
        vm.warp(start + vest);
        assertEq(vesting.claimable(alice), 400_000e18, "must be fully vested at start+vest");
    }

    function test_ClaimTransfersAndIsNotReplayable() public {
        _fundOne(alice, 400_000e18, 365 days, 4 * 365 days, false);
        vm.warp(start + 365 days);

        vm.prank(alice);
        uint256 got = vesting.claim();
        assertEq(got, 100_000e18);
        assertEq(token.balanceOf(alice), 100_000e18);

        vm.prank(alice);
        vm.expectRevert(ZorphaVesting.NothingToClaim.selector);
        vesting.claim();
    }

    function test_ClaimNeverExceedsTotalAcrossManyClaims() public {
        uint64 vest = 4 * 365 days;
        _fundOne(alice, 400_000e18, 365 days, vest, false);

        for (uint256 i = 1; i <= 16; i++) {
            vm.warp(start + (vest * i) / 16);
            uint256 c = vesting.claimable(alice);
            if (c > 0) {
                vm.prank(alice);
                vesting.claim();
            }
        }
        vm.warp(start + vest + 999 days);
        assertEq(token.balanceOf(alice), 400_000e18);
        assertEq(vesting.claimable(alice), 0);
    }

    /// FINDING M-06 regression: duplicates inside a single batch must revert.
    function test_DuplicateBeneficiaryInBatchReverts() public {
        address[] memory bens = new address[](2);
        bens[0] = alice;
        bens[1] = alice;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        uint64[] memory cliffs = new uint64[](2);
        uint64[] memory vests = new uint64[](2);
        vests[0] = 365 days;
        vests[1] = 365 days;
        bool[] memory revs = new bool[](2);

        vm.startPrank(admin);
        token.approve(address(vesting), 2e18);
        vm.expectRevert(abi.encodeWithSelector(ZorphaVesting.ScheduleExists.selector, alice));
        vesting.fund(bens, amounts, cliffs, vests, revs, start);
        vm.stopPrank();
    }

    /// FINDING M-07 regression: a schedule cannot be created already vested.
    function test_ExcessivelyBackdatedStartReverts() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        uint64[] memory cliffs = new uint64[](1);
        uint64[] memory vests = new uint64[](1);
        vests[0] = 365 days;
        bool[] memory revs = new bool[](1);

        vm.startPrank(admin);
        token.approve(address(vesting), 1e18);
        vm.expectRevert(ZorphaVesting.StartTimeTooEarly.selector);
        vesting.fund(bens, amounts, cliffs, vests, revs, uint64(block.timestamp - 200 days));
        vm.stopPrank();
    }

    function test_CliffLongerThanVestReverts() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        uint64[] memory cliffs = new uint64[](1);
        cliffs[0] = 800 days;
        uint64[] memory vests = new uint64[](1);
        vests[0] = 365 days;
        bool[] memory revs = new bool[](1);

        vm.startPrank(admin);
        token.approve(address(vesting), 1e18);
        vm.expectRevert(ZorphaVesting.CliffExceedsVest.selector);
        vesting.fund(bens, amounts, cliffs, vests, revs, start);
        vm.stopPrank();
    }

    /// FINDING L-02 regression: revocation must be observable by indexers.
    function test_RevokeEmitsEventAndReturnsOnlyUnvested() public {
        uint64 vest = 4 * 365 days;
        _fundOne(bob, 400_000e18, 365 days, vest, true);

        vm.warp(start + vest / 2); // 50% vested
        uint256 adminBefore = token.balanceOf(admin);

        vm.expectEmit(true, false, false, true, address(vesting));
        emit ZorphaVesting.Revoked(bob, 200_000e18, 200_000e18);
        vm.prank(admin);
        vesting.revoke(bob);

        assertEq(token.balanceOf(admin) - adminBefore, 200_000e18, "only unvested returns");
        assertEq(vesting.claimable(bob), 200_000e18, "vested portion survives revocation");

        // And the frozen amount does not keep growing after revocation.
        vm.warp(start + vest + 500 days);
        assertEq(vesting.claimable(bob), 200_000e18);

        vm.prank(bob);
        vesting.claim();
        assertEq(token.balanceOf(bob), 200_000e18);
    }

    function test_RevokeNonRevocableReverts() public {
        _fundOne(alice, 1e18, 0, 365 days, false);
        vm.prank(admin);
        vm.expectRevert(ZorphaVesting.NotRevocable.selector);
        vesting.revoke(alice);
    }

    function test_OnlyAdminCanFundOrRevoke() public {
        address[] memory bens = new address[](1);
        bens[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        uint64[] memory cliffs = new uint64[](1);
        uint64[] memory vests = new uint64[](1);
        vests[0] = 365 days;
        bool[] memory revs = new bool[](1);

        vm.prank(alice);
        vm.expectRevert(ZorphaVesting.NotAdmin.selector);
        vesting.fund(bens, amounts, cliffs, vests, revs, start);

        vm.prank(alice);
        vm.expectRevert(ZorphaVesting.NotAdmin.selector);
        vesting.revoke(bob);
    }

    /// Locked contributor tokens must carry zero governance weight. This is a
    /// trust property of the design, so it is pinned by a test.
    function test_LockedTokensHaveNoVotingWeight() public {
        _fundOne(alice, 400_000e18, 365 days, 4 * 365 days, false);
        assertEq(token.getVotes(address(vesting)), 0);
        assertEq(token.delegates(address(vesting)), address(0));
    }

    function testFuzz_ClaimableNeverExceedsTotal(uint64 skip, uint128 amount) public {
        amount = uint128(bound(uint256(amount), 1e18, 100_000_000e18));
        skip = uint64(bound(uint256(skip), 0, 20 * 365 days));
        _fundOne(alice, amount, 365 days, 4 * 365 days, false);

        vm.warp(start + skip);
        assertLe(vesting.claimable(alice), amount);
    }
}

contract ZorphaBuybackTest is Test {
    Zorpha token;
    MockERC20 usdc;
    ZorphaBuyback buyback;
    MockSwapRouter router;

    address timelock = makeAddr("timelock");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");

    function setUp() public {
        token = new Zorpha(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        buyback = new ZorphaBuyback(address(token), address(usdc), 1_000e6, timelock);

        router = new MockSwapRouter(IERC20(address(usdc)), token, 10e18); // 10 ZOR per USDC
        token.transfer(address(router), 50_000_000e18); // router inventory

        vm.prank(timelock);
        buyback.setRouter(address(router));
    }

    /// FINDING C-01 regression, part 1. The shipped contract emitted
    /// BuybackExecuted(usdgSpent = full balance) while performing no swap at
    /// all: USDC was never spent and no ZOR was ever bought. A buyback must
    /// actually reduce total supply.
    function test_ExecuteActuallyBuysAndBurns() public {
        usdc.mint(address(buyback), 5_000e6);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(keeper);
        (uint256 spent, uint256 burned) = buyback.execute(50_000e18);

        assertEq(spent, 5_000e6, "must spend the USDC");
        assertEq(burned, 50_000e18, "must buy 10 ZOR per USDC");
        assertEq(usdc.balanceOf(address(buyback)), 0, "USDC must leave the contract");
        assertEq(token.totalSupply(), supplyBefore - 50_000e18, "supply must actually fall");
        assertEq(token.balanceOf(address(buyback)), 0, "nothing left unburned");
        assertEq(buyback.totalUsdgSpent(), 5_000e6);
        assertEq(buyback.totalZorBurned(), 50_000e18);
    }

    /// FINDING C-01 regression, part 2. The reported numbers must match the
    /// real balance deltas, so dashboards cannot show phantom buyback volume.
    function test_EventReportsTrueAmounts() public {
        usdc.mint(address(buyback), 2_000e6);

        vm.expectEmit(true, false, false, true, address(buyback));
        emit ZorphaBuyback.BuybackExecuted(keeper, 2_000e6, 20_000e18);
        vm.prank(keeper);
        buyback.execute(20_000e18);
    }

    /// A router that pockets the USDC and delivers no ZOR must revert the whole
    /// buyback, not silently book a burn of zero.
    function test_LyingRouterCannotFakeABurn() public {
        StealingRouter thief = new StealingRouter(IERC20(address(usdc)));
        vm.prank(timelock);
        buyback.setRouter(address(thief));

        usdc.mint(address(buyback), 2_000e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ZorphaBuyback.InsufficientOutput.selector, 0, 20_000e18)
        );
        buyback.execute(20_000e18);
    }

    function test_SlippageBoundIsEnforced() public {
        usdc.mint(address(buyback), 2_000e6);
        router.setRate(1e18); // price moved against us: 1 ZOR per USDC

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ZorphaBuyback.InsufficientOutput.selector, 2_000e18, 20_000e18)
        );
        buyback.execute(20_000e18);
    }

    function test_BelowThresholdReverts() public {
        usdc.mint(address(buyback), 999e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(ZorphaBuyback.BelowThreshold.selector, 999e6, 1_000e6)
        );
        buyback.execute(0);
    }

    function test_ExecuteWithoutRouterReverts() public {
        ZorphaBuyback fresh = new ZorphaBuyback(address(token), address(usdc), 0, timelock);
        usdc.mint(address(fresh), 5_000e6);
        vm.expectRevert(ZorphaBuyback.RouterNotSet.selector);
        fresh.execute(0);
    }

    /// FINDING C-01 regression, part 3. The old contract blocked USDC from
    /// `rescueToken` and had no other exit, so every dollar of fee revenue that
    /// arrived before a ZOR market existed was permanently stranded.
    function test_UsdgCanAlwaysBeRecovered() public {
        usdc.mint(address(buyback), 7_500e6);

        vm.prank(timelock);
        buyback.withdrawUsdg(treasury, 7_500e6);
        assertEq(usdc.balanceOf(treasury), 7_500e6, "fee revenue must never be strandable");
    }

    /// @dev All three are Ownable2Step, and the deploy hands ownership to the
    ///      Timelock -- so "timelock only" is true in production but the check
    ///      being exercised here is the OWNER check. Naming the error makes
    ///      that explicit; a bare revert would also have accepted a
    ///      ReentrancyGuard trip or a zero-address require.
    function test_PrivilegedSettersAreTimelockOnly() public {
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper)
        );
        buyback.setRouter(address(router));

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper)
        );
        buyback.withdrawUsdg(keeper, 1);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper)
        );
        buyback.setThreshold(0);
    }

    function test_ExecuteIsPermissionlessOnceFunded() public {
        usdc.mint(address(buyback), 1_000e6);
        vm.prank(makeAddr("random"));
        buyback.execute(10_000e18);
        assertEq(buyback.totalZorBurned(), 10_000e18);
    }
}

contract MerkleDistributorTest is Test {
    Zorpha token;
    MerkleDistributor dist;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 leafAlice;
    bytes32 leafBob;
    bytes32 root;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new Zorpha(address(this));

        // Two-leaf OpenZeppelin standard tree: double-hashed leaves, sorted pair.
        leafAlice = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), alice, uint256(1_000e18)))));
        leafBob = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), bob, uint256(2_000e18)))));
        root = leafAlice < leafBob
            ? keccak256(abi.encodePacked(leafAlice, leafBob))
            : keccak256(abi.encodePacked(leafBob, leafAlice));

        dist = new MerkleDistributor(
            IERC20(address(token)), root, block.timestamp + 30 days, admin
        );
        token.transfer(address(dist), 3_000e18);
    }

    function _proofFor(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function test_ValidClaimPays() public {
        dist.claim(0, alice, 1_000e18, _proofFor(leafBob));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertTrue(dist.isClaimed(0));
    }

    function test_DoubleClaimReverts() public {
        dist.claim(0, alice, 1_000e18, _proofFor(leafBob));
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, 0));
        dist.claim(0, alice, 1_000e18, _proofFor(leafBob));
    }

    /// A claimant cannot inflate their own amount, which is the whole point of
    /// committing (index, account, amount) into the leaf.
    function test_TamperedAmountReverts() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(0, alice, 999_999e18, _proofFor(leafBob));
    }

    function test_TamperedRecipientReverts() public {
        vm.expectRevert(MerkleDistributor.InvalidProof.selector);
        dist.claim(0, bob, 1_000e18, _proofFor(leafBob));
    }

    /// Anyone may submit someone else's proof, but funds always land on the
    /// committed account, so front-running is harmless.
    function test_ThirdPartySubmissionStillPaysTheOwner() public {
        vm.prank(makeAddr("mev"));
        dist.claim(1, bob, 2_000e18, _proofFor(leafAlice));
        assertEq(token.balanceOf(bob), 2_000e18);
    }

    function test_ClaimAfterDeadlineReverts() public {
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(MerkleDistributor.ClaimWindowClosed.selector);
        dist.claim(0, alice, 1_000e18, _proofFor(leafBob));
    }

    function test_SweepBeforeDeadlineReverts() public {
        vm.prank(admin);
        vm.expectRevert(MerkleDistributor.SweepBeforeDeadline.selector);
        dist.sweep(admin);
    }

    function test_SweepAfterDeadlineReturnsRemainder() public {
        dist.claim(0, alice, 1_000e18, _proofFor(leafBob));
        vm.warp(block.timestamp + 31 days);

        vm.prank(admin);
        dist.sweep(admin);
        assertEq(token.balanceOf(admin), 2_000e18);
        assertEq(token.balanceOf(address(dist)), 0);
    }

    function test_SweepIsRoleGated() public {
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                keccak256("SWEEPER_ROLE")
            )
        );
        dist.sweep(alice);
    }

    function test_ConstructorRejectsBadConfig() public {
        vm.expectRevert(MerkleDistributor.InvalidConfig.selector);
        new MerkleDistributor(IERC20(address(token)), bytes32(0), block.timestamp + 1 days, admin);

        vm.expectRevert(MerkleDistributor.InvalidConfig.selector);
        new MerkleDistributor(IERC20(address(token)), root, block.timestamp - 1, admin);

        vm.expectRevert(MerkleDistributor.InvalidConfig.selector);
        new MerkleDistributor(IERC20(address(token)), root, block.timestamp + 1 days, address(0));
    }
}
