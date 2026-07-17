// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {Allocator} from "../src/Allocator.sol";
import {Oracle} from "../src/Oracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockERC20, MockYieldVault, MockPriceFeed, MockRedeemer} from "./mocks/Mocks.sol";

/// @notice Liquidity stacking: vaults are ERC4626 over the same base asset, so a vault is a
/// valid allocation target for another vault. The same base liquidity backs redemptions at
/// every level of the graph and earns yield at the leaves.
contract StackingTest is Test {
    uint256 constant WAD = 1e18;
    int256 constant PRICE = 1.05e8;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address holder = makeAddr("holder");

    MockERC20 base;
    MockPriceFeed feed;
    Oracle oracle;

    Vault vaultA;
    Vault vaultB;
    Vault vaultC;
    MockYieldVault morpho;

    MockERC20 rwaA;
    MockERC20 rwaB;
    MockERC20 rwaC;

    function setUp() public {
        base = new MockERC20("Base", "USDX", 6);
        feed = new MockPriceFeed(8, PRICE);
        oracle = new Oracle(owner, address(feed), 1 days);
        morpho = new MockYieldVault(base);

        rwaA = new MockERC20("RWA A", "RWAA", 18);
        rwaB = new MockERC20("RWA B", "RWAB", 18);
        rwaC = new MockERC20("RWA C", "RWAC", 18);

        vaultA = new Vault(owner, base, rwaA, IOracle(address(oracle)), "Plexus A", "pA");
        vaultB = new Vault(owner, base, rwaB, IOracle(address(oracle)), "Plexus B", "pB");
        vaultC = new Vault(owner, base, rwaC, IOracle(address(oracle)), "Plexus C", "pC");

        vm.startPrank(owner);
        // A -> B (50%), C (30%), Morpho (20%)
        vaultA.setCaps(address(vaultB), type(uint256).max, 0.5e18);
        vaultA.setCaps(address(vaultC), type(uint256).max, 0.3e18);
        vaultA.setCaps(address(morpho), type(uint256).max, 0.2e18);

        // B -> C, Morpho
        vaultB.setCaps(address(vaultC), type(uint256).max, WAD);
        vaultB.setCaps(address(morpho), type(uint256).max, WAD);

        // C -> Morpho
        vaultC.setCaps(address(morpho), type(uint256).max, WAD);

        for (uint256 i; i < 3; ++i) {
            Vault v = [vaultA, vaultB, vaultC][i];
            v.setParams(0.01e18, 1_000_000e6);
            v.setRedeemer(address(new MockRedeemer(base, v.rwa())));
        }
        vm.stopPrank();
    }

    function _deposit(Vault v, address who, uint256 assets) internal {
        base.mint(who, assets);
        vm.startPrank(who);
        base.approve(address(v), assets);
        v.deposit(assets, who);
        vm.stopPrank();
    }

    function _redeemRwa(Vault v, MockERC20 token, uint256 amount) internal returns (uint256) {
        token.mint(holder, amount);
        vm.startPrank(holder);
        token.approve(address(v), amount);
        uint256 out = v.redeemRwa(amount, 0);
        vm.stopPrank();
        return out;
    }

    /// @notice A splits 50/30/20 across B, C and Morpho, and each hop re-routes onward.
    function test_stack_liquidityFlowsThroughTheGraph() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultA.allocate(address(vaultC), 300e6);
        vaultA.allocate(address(morpho), 200e6);

        // B re-shares what it received: 300 onward to C, 200 into Morpho.
        vaultB.allocate(address(vaultC), 300e6);
        vaultB.allocate(address(morpho), 200e6);

        // C now holds its own 300 plus B's 300, and parks it all in Morpho.
        vaultC.allocate(address(morpho), 600e6);
        vm.stopPrank();

        assertEq(vaultA.allocation(address(vaultB)), 500e6);
        assertEq(vaultA.allocation(address(vaultC)), 300e6);
        assertEq(vaultA.allocation(address(morpho)), 200e6);
        assertEq(vaultB.allocation(address(vaultC)), 300e6);
        assertEq(vaultC.allocation(address(morpho)), 600e6);

        // The LP's 1000 is intact at the root despite being routed three hops deep.
        assertEq(vaultA.totalAssets(), 1000e6);
        assertEq(vaultA.convertToAssets(vaultA.balanceOf(lp)), 1000e6);

        // Every unit is accounted for exactly once. Only Morpho actually holds base now.
        assertEq(base.balanceOf(address(morpho)), 1000e6);
        assertEq(base.balanceOf(address(vaultA)), 0);
        assertEq(base.balanceOf(address(vaultB)), 0);
        assertEq(base.balanceOf(address(vaultC)), 0);
    }

    /// @notice The same deposited liquidity backs a redemption in a vault three hops away.
    function test_stack_leafRedemptionDrawsOnRootLiquidity() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultA.allocate(address(morpho), 200e6);
        vaultB.setLiquidityTarget(address(morpho));
        vaultB.allocate(address(morpho), 500e6);
        vm.stopPrank();

        assertEq(vaultB.totalAssets(), 500e6, "B is funded entirely by A's deposit");

        // A holder redeems RWA against B. B has no idle base of its own — it pulls back from
        // Morpho, which is holding liquidity that originated as an LP deposit into A.
        uint256 baseOut = _redeemRwa(vaultB, rwaB, 100e18);

        assertEq(baseOut, 103.95e6);
        assertEq(base.balanceOf(holder), 103.95e6);
        assertEq(vaultB.rwaExposure(), 100e18);

        // B's fee accrues to B's shares, which A owns, so it flows up to A's LP.
        assertApproxEqAbs(vaultB.totalAssets(), 501.05e6, 1);
        assertApproxEqAbs(vaultA.totalAssets(), 1001.05e6, 2);
        assertGt(vaultA.convertToAssets(vaultA.balanceOf(lp)), 1000e6);
    }

    /// @notice Yield at a leaf propagates up every hop to the root LP.
    function test_stack_leafYieldReachesRootLp() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.setCaps(address(vaultB), type(uint256).max, WAD);
        vaultA.allocate(address(vaultB), 1000e6);
        vaultB.allocate(address(vaultC), 1000e6);
        vaultC.allocate(address(morpho), 1000e6);
        vm.stopPrank();

        morpho.accrue(100e6);

        // Each hop rounds down by at most one wei, in the vault's favour.
        assertEq(vaultC.totalAssets(), 1100e6);
        assertApproxEqAbs(vaultB.totalAssets(), 1100e6, 1);
        assertApproxEqAbs(vaultA.totalAssets(), 1100e6, 2);
        assertApproxEqAbs(vaultA.convertToAssets(vaultA.balanceOf(lp)), 1100e6, 3);
    }

    /// @notice A withdrawal at the root unwinds the chain hop by hop.
    function test_stack_rootWithdrawalUnwindsTheChain() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.setCaps(address(vaultB), type(uint256).max, WAD);
        vaultA.allocate(address(vaultB), 1000e6);
        vaultB.setLiquidityTarget(address(vaultC));
        vaultB.allocate(address(vaultC), 1000e6);
        vaultC.setLiquidityTarget(address(morpho));
        vaultC.allocate(address(morpho), 1000e6);
        vaultA.setLiquidityTarget(address(vaultB));
        vm.stopPrank();

        vm.prank(lp);
        vaultA.withdraw(400e6, lp, lp);

        assertEq(base.balanceOf(lp), 400e6);
        assertEq(vaultA.totalAssets(), 600e6);
        assertEq(vaultC.allocation(address(morpho)), 600e6, "pulled all the way from the leaf");
    }

    /// @notice Relative caps bound what any one vault routes into any one target.
    function test_stack_relativeCapsBoundEachHop() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vm.expectRevert();
        vaultA.allocate(address(vaultB), 600e6); // over A's 50% cap on B

        vaultA.allocate(address(vaultB), 500e6);
        vm.stopPrank();

        assertEq(vaultA.allocation(address(vaultB)), 500e6);
    }

    /// @notice A -> B is funded, so B naming A closes a loop. setCaps walks its own graph
    /// through the new edge, the walk recurses until it dies, and the whole call reverts.
    function test_stack_cycleRejectedAtSetCaps() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);

        vm.expectRevert();
        vaultB.setCaps(address(vaultA), type(uint256).max, WAD);
        vm.stopPrank();

        assertFalse(vaultB.isTarget(address(vaultA)), "edge never landed");
        assertEq(vaultA.totalAssets(), 1000e6, "A untouched");
        assertEq(vaultB.totalAssets(), 500e6, "B untouched");
    }

    /// @notice The percentages are irrelevant to the recursion. A 0/0 cap is rejected just the
    /// same, because totalAllocated() previews every registered target regardless of balance.
    function test_stack_cycleRejectedEvenAtZeroCap() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);

        vm.expectRevert();
        vaultB.setCaps(address(vaultA), 0, 0);
        vm.stopPrank();

        assertFalse(vaultB.isTarget(address(vaultA)));
    }

    /// @notice Longer funded loops are caught the same way: A -> B -> C, then C naming A.
    function test_stack_longCycleRejectedWhenFunded() public {
        _deposit(vaultA, lp, 1000e6);
        _deposit(vaultB, lp, 1000e6);
        _deposit(vaultC, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultB.allocate(address(vaultC), 500e6);

        vm.expectRevert();
        vaultC.setCaps(address(vaultA), type(uint256).max, WAD);
        vm.stopPrank();

        assertFalse(vaultC.isTarget(address(vaultA)));
    }

    /// @notice The virtual share removes the `supply == 0` branch from every conversion, so an
    /// empty loop still traverses and is rejected. Without it, this would land while empty and
    /// only brick on the first deposit.
    function test_stack_emptyCycleRejected() public {
        vm.startPrank(owner);
        vaultB.setCaps(address(vaultC), type(uint256).max, WAD);

        vm.expectRevert();
        vaultC.setCaps(address(vaultA), type(uint256).max, WAD);
        vm.stopPrank();

        assertFalse(vaultC.isTarget(address(vaultA)), "empty loop never landed");

        _deposit(vaultA, lp, 1000e6);
        assertEq(vaultA.totalAssets(), 1000e6);
    }

    /// @notice The check must not reject an honest diamond: A -> B -> M and A -> C -> M is not
    /// a cycle, even though M is reachable from A by two paths.
    function test_stack_diamondIsNotACycle() public {
        vm.startPrank(owner);
        vaultB.setCaps(address(morpho), type(uint256).max, WAD);
        vaultC.setCaps(address(morpho), type(uint256).max, WAD);
        vm.stopPrank();

        _deposit(vaultA, lp, 1000e6);
        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultA.allocate(address(vaultC), 300e6);
        vaultB.allocate(address(morpho), 500e6);
        vaultC.allocate(address(morpho), 300e6);
        vm.stopPrank();

        assertEq(vaultA.totalAssets(), 1000e6);
    }

    function test_stack_selfTargetRejected() public {
        vm.expectRevert(Allocator.SelfTarget.selector);
        vm.prank(owner);
        vaultA.setCaps(address(vaultA), type(uint256).max, WAD);
    }

    /// @notice Each vault's RWA risk stays its own: B taking on RWA does not raise A's exposure.
    function test_stack_rwaRiskStaysIsolatedPerVault() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultB.setLiquidityTarget(address(morpho));
        vaultB.allocate(address(morpho), 500e6);
        vm.stopPrank();

        _redeemRwa(vaultB, rwaB, 100e18);

        assertEq(vaultB.rwaExposure(), 100e18);
        assertEq(vaultA.rwaExposure(), 0, "A holds shares of B, not B's RWA");
        assertEq(address(vaultA.rwa()), address(rwaA));
    }

    /// @notice Each vault settles through its own redeemer, so onboarding B's asset never
    /// touches A or C.
    function test_stack_eachVaultSettlesThroughItsOwnRedeemer() public {
        _deposit(vaultA, lp, 1000e6);

        vm.startPrank(owner);
        vaultA.allocate(address(vaultB), 500e6);
        vaultB.setLiquidityTarget(address(morpho));
        vaultB.allocate(address(morpho), 500e6);
        vm.stopPrank();

        _redeemRwa(vaultB, rwaB, 100e18);

        address redeemerB = vaultB.redeemer();
        assertTrue(redeemerB != vaultA.redeemer() && redeemerB != vaultC.redeemer());

        vm.prank(owner);
        vaultB.externalRedeem(abi.encodeCall(MockRedeemer.pull, (100e18)), 0);
        assertEq(vaultB.rwaInRedemption(), 100e18);
        assertEq(rwaB.balanceOf(redeemerB), 100e18);

        skip(3 days);
        feed.set(PRICE);

        vm.prank(owner);
        vaultB.finalizeExternalRedeem(100e18, abi.encodeCall(MockRedeemer.settle, (105e6)), 0);

        assertEq(vaultB.rwaExposure(), 0);
        assertApproxEqAbs(vaultB.totalAssets(), 501.05e6, 1);
        assertApproxEqAbs(vaultA.totalAssets(), 1001.05e6, 2);
    }
}
