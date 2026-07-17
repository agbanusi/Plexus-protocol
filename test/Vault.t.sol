// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Vault} from "../src/Vault.sol";
import {Allocator} from "../src/Allocator.sol";
import {Oracle} from "../src/Oracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockERC20, MockYieldVault, MockPriceFeed, MockRedeemer} from "./mocks/Mocks.sol";

contract VaultTest is Test {
    uint256 constant WAD = 1e18;
    // 1 RWA is worth 1.05 base. Feed reports 8 decimals, base has 6, RWA has 18.
    int256 constant PRICE = 1.05e8;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address holder = makeAddr("holder");

    MockERC20 base;
    MockERC20 rwa;
    MockPriceFeed feed;
    Oracle oracle;
    Vault vault;
    MockYieldVault yieldVault;
    MockRedeemer redeemer;

    function setUp() public {
        base = new MockERC20("Base", "USDX", 6);
        rwa = new MockERC20("Real World Asset", "RWA", 18);
        feed = new MockPriceFeed(8, PRICE);
        oracle = new Oracle(owner, address(feed), 1 days);

        vault = new Vault(owner, base, rwa, IOracle(address(oracle)), "Plexus RWA", "pRWA");
        yieldVault = new MockYieldVault(base);
        redeemer = new MockRedeemer(base, rwa);

        vm.startPrank(owner);
        vault.setCaps(address(yieldVault), type(uint256).max, WAD);
        vault.setLiquidityTarget(address(yieldVault));
        vault.setRedeemer(address(redeemer));
        vault.setParams(0.01e18, 1_000_000e6);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 assets) internal {
        base.mint(who, assets);
        vm.startPrank(who);
        base.approve(address(vault), assets);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    /* ---------------------------- accounting ---------------------------- */

    function test_rwaValue_scalesAcrossDecimals() public view {
        // 1e18 RWA at 1.05 base/RWA, base has 6 decimals.
        assertEq(vault.rwaValue(1e18), 1.05e6);
        assertEq(vault.rwaValue(0.5e18), 0.525e6);
        assertEq(vault.rwaValue(0), 0);
    }

    function test_previewRedeemRwa_appliesFee() public view {
        // 1.05e6 less the 1% fee.
        assertEq(vault.previewRedeemRwa(1e18), 1.0395e6);
    }

    /* ---------------------------- allocation ---------------------------- */

    function test_deposit_allocatesImmediately() public {
        _deposit(lp, 1000e6);

        assertEq(base.balanceOf(address(vault)), 0, "nothing left idle");
        assertEq(vault.allocation(address(yieldVault)), 1000e6);
        assertEq(vault.totalAllocated(), 1000e6);
        assertEq(vault.totalAssets(), 1000e6);
        assertEq(vault.balanceOf(lp), 1000e6);
    }

    function test_withdraw_deallocatesToCoverPayout() public {
        _deposit(lp, 1000e6);

        vm.prank(lp);
        vault.withdraw(400e6, lp, lp);

        assertEq(base.balanceOf(lp), 400e6);
        assertEq(vault.allocation(address(yieldVault)), 600e6);
    }

    function test_deposit_withoutLiquidityTarget_staysIdle() public {
        vm.prank(owner);
        vault.setLiquidityTarget(address(0));

        _deposit(lp, 1000e6);

        assertEq(base.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalAssets(), 1000e6);
    }

    function test_yieldInTarget_accruesToLps() public {
        _deposit(lp, 1000e6);
        yieldVault.accrue(100e6);

        assertEq(vault.totalAssets(), 1100e6);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), 1100e6, 1);
    }

    function test_allocate_revertsOverAbsoluteCap() public {
        _deposit(lp, 1000e6);

        vm.startPrank(owner);
        vault.deallocate(address(yieldVault), 1000e6);
        vault.setCaps(address(yieldVault), 500e6, WAD);

        vm.expectRevert(Allocator.AbsoluteCapExceeded.selector);
        vault.allocate(address(yieldVault), 600e6);
        vm.stopPrank();
    }

    function test_allocate_revertsOverRelativeCap() public {
        _deposit(lp, 1000e6);

        vm.startPrank(owner);
        vault.deallocate(address(yieldVault), 1000e6);
        vault.setCaps(address(yieldVault), type(uint256).max, 0.5e18);

        vm.expectRevert(Allocator.RelativeCapExceeded.selector);
        vault.allocate(address(yieldVault), 600e6);

        vault.allocate(address(yieldVault), 500e6);
        vm.stopPrank();

        assertEq(vault.allocation(address(yieldVault)), 500e6);
    }

    function test_allocate_onlyAllocator() public {
        _deposit(lp, 1000e6);

        vm.expectRevert(Allocator.NotAllocator.selector);
        vm.prank(lp);
        vault.allocate(address(yieldVault), 1);

        vm.prank(owner);
        vault.setAllocator(lp, true);

        vm.prank(owner);
        vault.deallocate(address(yieldVault), 100e6);

        vm.prank(lp);
        vault.allocate(address(yieldVault), 100e6);
        assertEq(vault.allocation(address(yieldVault)), 1000e6);
    }

    function test_setCaps_revertsOnAssetMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockYieldVault wrongVault = new MockYieldVault(other);

        vm.expectRevert(Allocator.AssetMismatch.selector);
        vm.prank(owner);
        vault.setCaps(address(wrongVault), type(uint256).max, WAD);
    }

    function test_removeTarget_revertsWhileFunded() public {
        _deposit(lp, 1000e6);

        vm.expectRevert(Allocator.TargetNotEmpty.selector);
        vm.prank(owner);
        vault.removeTarget(address(yieldVault));

        vm.startPrank(owner);
        vault.deallocate(address(yieldVault), 1000e6);
        vault.removeTarget(address(yieldVault));
        vm.stopPrank();

        assertFalse(vault.isTarget(address(yieldVault)));
        assertEq(vault.liquidityTarget(), address(0), "liquidity target cleared with the target");
    }

    /* --------------------------- redeemRwa --------------------------- */

    function test_redeemRwa_paysOutFromAllocatedLiquidity() public {
        _deposit(lp, 1000e6);

        rwa.mint(holder, 100e18);
        vm.startPrank(holder);
        rwa.approve(address(vault), 100e18);
        uint256 baseOut = vault.redeemRwa(100e18, 0);
        vm.stopPrank();

        // 100 RWA * 1.05 = 105 base, less the 1% fee.
        assertEq(baseOut, 103.95e6);
        assertEq(base.balanceOf(holder), 103.95e6);
        assertEq(rwa.balanceOf(address(vault)), 100e18);
        // The vault kept the 1.05 base fee: it holds 105 of RWA value against 103.95 paid out.
        assertEq(vault.totalAssets(), 1001.05e6);
    }

    function test_redeemRwa_revertsOnSlippage() public {
        _deposit(lp, 1000e6);
        rwa.mint(holder, 100e18);

        vm.startPrank(holder);
        rwa.approve(address(vault), 100e18);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        vault.redeemRwa(100e18, 104e6);
        vm.stopPrank();
    }

    function test_redeemRwa_revertsOverRwaCap() public {
        _deposit(lp, 1000e6);
        vm.prank(owner);
        vault.setParams(0.01e18, 50e6);

        rwa.mint(holder, 100e18);
        vm.startPrank(holder);
        rwa.approve(address(vault), 100e18);
        vm.expectRevert(Vault.RwaCapExceeded.selector);
        vault.redeemRwa(100e18, 0);
        vm.stopPrank();
    }

    function test_redeemRwa_revertsOnZero() public {
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.redeemRwa(0, 0);
    }

    function test_redeemRwa_revertsWhenLiquidityShort() public {
        _deposit(lp, 10e6);
        rwa.mint(holder, 100e18);

        vm.startPrank(holder);
        rwa.approve(address(vault), 100e18);
        vm.expectRevert();
        vault.redeemRwa(100e18, 0);
        vm.stopPrank();
    }

    /* ------------------------ external redemption ------------------------ */

    function test_externalRedeem_thenFinalize() public {
        _deposit(lp, 1000e6);

        rwa.mint(holder, 100e18);
        vm.startPrank(holder);
        rwa.approve(address(vault), 100e18);
        vault.redeemRwa(100e18, 0);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();

        vm.prank(owner);
        vault.externalRedeem(abi.encodeCall(MockRedeemer.pull, (100e18)), 0);

        assertEq(rwa.balanceOf(address(vault)), 0, "RWA handed to the redeemer");
        assertEq(vault.rwaInRedemption(), 100e18, "still on the books");
        assertEq(vault.rwaExposure(), 100e18);
        assertEq(vault.totalAssets(), assetsBefore, "mid-settlement RWA is still marked");

        // Days later the issuer wires the stables back.
        skip(3 days);
        feed.set(PRICE);

        vm.prank(owner);
        vault.finalizeExternalRedeem(100e18, abi.encodeCall(MockRedeemer.settle, (105e6)), 0);

        assertEq(vault.rwaInRedemption(), 0);
        assertEq(vault.rwaExposure(), 0);
        assertEq(vault.allocation(address(yieldVault)), 1001.05e6, "proceeds put back to work");
        assertEq(vault.totalAssets(), 1001.05e6);
    }

    function test_externalRedeem_bubblesRevert() public {
        vm.expectRevert(bytes("redeemer failed"));
        vm.prank(owner);
        vault.externalRedeem(abi.encodeCall(MockRedeemer.boom, ()), 0);
    }

    function test_externalRedeem_revertsWithoutRedeemer() public {
        vm.startPrank(owner);
        vault.setRedeemer(address(0));

        vm.expectRevert(Vault.NoRedeemer.selector);
        vault.externalRedeem(abi.encodeCall(MockRedeemer.pull, (1)), 0);

        vm.expectRevert(Vault.NoRedeemer.selector);
        vault.finalizeExternalRedeem(1, abi.encodeCall(MockRedeemer.settle, (1)), 0);
        vm.stopPrank();
    }

    function test_externalRedeem_onlyOwner() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(lp);
        vault.externalRedeem(abi.encodeCall(MockRedeemer.pull, (1)), 0);
    }

    /* ------------------------------ admin ------------------------------ */

    function test_setParams_rejectsExcessiveFee() public {
        vm.expectRevert(Vault.FeeTooHigh.selector);
        vm.prank(owner);
        vault.setParams(0.11e18, 0);
    }

    function test_setLiquidityTarget_mustBeTarget() public {
        MockYieldVault other = new MockYieldVault(base);

        vm.expectRevert(Allocator.NotTarget.selector);
        vm.prank(owner);
        vault.setLiquidityTarget(address(other));
    }

    /* ------------------------------ fuzz ------------------------------ */

    function testFuzz_depositWithdraw_roundTrips(uint256 assets) public {
        assets = bound(assets, 1e6, 1_000_000e6);
        _deposit(lp, assets);

        assertEq(vault.totalAssets(), assets);

        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.redeem(shares, lp, lp);

        assertEq(base.balanceOf(lp), assets);
        assertEq(vault.totalAssets(), 0);
    }

    function testFuzz_redeemRwa_neverPaysMoreThanRwaIsWorth(uint256 rwaAmount) public {
        rwaAmount = bound(rwaAmount, 1e15, 1000e18);
        _deposit(lp, 1_000_000e6);

        rwa.mint(holder, rwaAmount);
        vm.startPrank(holder);
        rwa.approve(address(vault), rwaAmount);
        uint256 baseOut = vault.redeemRwa(rwaAmount, 0);
        vm.stopPrank();

        assertLe(baseOut, vault.rwaValue(rwaAmount), "payout never exceeds the RWA taken in");
        assertGe(vault.totalAssets(), 1_000_000e6, "LPs never lose on a redemption");
    }
}
