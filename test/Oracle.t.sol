// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "../src/Oracle.sol";
import {MockPriceFeed} from "./mocks/Mocks.sol";

contract OracleTest is Test {
    address owner = makeAddr("owner");

    MockPriceFeed feed;
    Oracle oracle;

    function setUp() public {
        feed = new MockPriceFeed(8, 1.05e8);
        oracle = new Oracle(owner, address(feed), 1 days);
    }

    function test_price_normalizesFeedDecimalsToWad() public view {
        assertEq(oracle.price(), 1.05e18);
    }

    function test_price_normalizesAnAlreadyWadFeed() public {
        MockPriceFeed wadFeed = new MockPriceFeed(18, 1.05e18);
        Oracle wadOracle = new Oracle(owner, address(wadFeed), 1 days);
        assertEq(wadOracle.price(), 1.05e18);
    }

    function test_price_revertsOnStaleAnswer() public {
        skip(1 days + 1);
        vm.expectRevert(Oracle.StalePrice.selector);
        oracle.price();
    }

    function test_price_revertsOnNonPositiveAnswer() public {
        feed.set(0);
        vm.expectRevert(Oracle.InvalidRoundData.selector);
        oracle.price();

        feed.set(-1);
        vm.expectRevert(Oracle.InvalidRoundData.selector);
        oracle.price();
    }

    function test_price_revertsOnUnsetRound() public {
        feed.setUpdatedAt(0);
        vm.expectRevert(Oracle.InvalidRoundData.selector);
        oracle.price();
    }

    function test_setMaxAge_onlyOwner() public {
        vm.expectRevert("UNAUTHORIZED");
        oracle.setMaxAge(2 days);

        vm.prank(owner);
        oracle.setMaxAge(2 days);
        assertEq(oracle.maxAge(), 2 days);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(Oracle.ZeroAddress.selector);
        new Oracle(address(0), address(feed), 1 days);

        vm.expectRevert(Oracle.ZeroAddress.selector);
        new Oracle(owner, address(0), 1 days);
    }

    function testFuzz_price_isMonotonicInTheFeed(uint256 answer) public {
        answer = bound(answer, 1, 1e24);
        feed.set(int256(answer));
        assertEq(oracle.price(), answer * 1e10);
    }
}
